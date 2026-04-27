#!/usr/bin/env bash
# graph.sh — Semantic entity indexing, search, and knowledge graph
#
# Combines entity file indexing (index-file, index-all) with hybrid graph
# search, relationship traversal, blocker detection, diffs, and handoffs.
#
# Config (set in .env):
#   BRIDGE_WATCH_DIRS        — space-separated dirs to index (default: $PWD)
#   BRIDGE_ENTITY_TYPES      — subdirectory→type mapping (optional)
#                              e.g. "docs:doc,notes:note,projects:project"
#   BRIDGE_SYNTHESIS_AGENT   — Agent Builder agent ID for handoff synthesis (optional)
#   BRIDGE_INGEST_ALERT_TAGS — alert tags to watch for health checks (default: ingest-failure)

# FUSE weight syntax confirmed on this cluster: {"weights": {"0": 0.3, "1": 0.7}}
# METADATA _id, _score, _index required for FUSE

BRIDGE_WATCH_DIRS="${BRIDGE_WATCH_DIRS:-$PWD}"
BRIDGE_INGEST_ALERT_TAGS="${BRIDGE_INGEST_ALERT_TAGS:-ingest-failure}"

# ── Entity indexing helpers ──────────────────────────────────────────────────

_slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

_entity_id() {
  local type="$1" slug="$2"
  echo "${BRIDGE_AGENT_ID}-${type}-${slug}"
}

# Infer entity type from parent directory name or configurable mapping
_infer_type() {
  local dir_name="$1"
  # Check BRIDGE_ENTITY_TYPES mapping: "subdir:type,subdir2:type2"
  if [[ -n "${BRIDGE_ENTITY_TYPES:-}" ]]; then
    local mapping
    IFS=',' read -ra mapping <<< "$BRIDGE_ENTITY_TYPES"
    for pair in "${mapping[@]}"; do
      local k="${pair%%:*}" v="${pair##*:}"
      [[ "$dir_name" == "$k" ]] && echo "$v" && return
    done
  fi
  # Default: use directory name as type, or "note" for root-level files
  [[ -n "$dir_name" ]] && echo "$dir_name" || echo "note"
}

# ── Index a single file ──────────────────────────────────────────────────────

entity_index_file() {
  local filepath="${1:-}"
  [[ -z "$filepath" ]] && { echo "Usage: bridge entity index-file <path>" >&2; return 1; }
  [[ -f "$filepath" ]] || { echo "File not found: $filepath" >&2; return 1; }

  # Only index markdown files
  [[ "$filepath" == *.md ]] || return 0

  local content
  content="$(cat "$filepath")"
  local filename
  filename="$(basename "$filepath" .md)"
  local dir_name
  dir_name="$(basename "$(dirname "$filepath")")"
  local type
  type="$(_infer_type "$dir_name")"
  local slug
  slug="$(_slugify "$filename")"
  local eid
  eid="$(_entity_id "$type" "$slug")"

  # Extract frontmatter fields if present
  local title="$filename" status="" priority="" initiative="" tags="[]"
  if [[ "$content" =~ ^--- ]]; then
    local fm_title fm_status fm_priority fm_initiative fm_tags
    fm_title="$(echo "$content" | sed -n 's/^title: *//p' | head -1)"
    fm_status="$(echo "$content" | sed -n 's/^status: *//p' | head -1)"
    fm_priority="$(echo "$content" | sed -n 's/^priority: *//p' | head -1)"
    fm_initiative="$(echo "$content" | sed -n 's/^initiative: *//p' | head -1)"
    fm_tags="$(echo "$content" | sed -n 's/^tags: *//p' | head -1)"
    [[ -n "$fm_title" ]] && title="$fm_title"
    [[ -n "$fm_status" ]] && status="$fm_status"
    [[ -n "$fm_priority" ]] && priority="$fm_priority"
    [[ -n "$fm_initiative" ]] && initiative="$fm_initiative"
    # Strip frontmatter from content
    content="$(echo "$content" | sed '1,/^---$/d' | sed '1,/^---$/d')"
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg eid "$eid" \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg type "$type" \
    --arg title "$title" \
    --arg content "$content" \
    --arg status "$status" \
    --arg priority "$priority" \
    --arg initiative "$initiative" \
    --arg filepath "$filepath" \
    --arg now "$now" \
    '{
      entity_id: $eid,
      agent: $agent,
      entity_type: $type,
      title: $title,
      title_semantic: $title,
      content: $content,
      content_semantic: $content,
      status: $status,
      priority: $priority,
      initiative: $initiative,
      source_path: $filepath,
      updated_at: $now
    }')"

  local result
  result="$(es_index "$IDX_ENTITIES" "$eid" "$doc" 2>/dev/null)"
  if echo "$result" | jq -e '.result == "created" or .result == "updated"' > /dev/null 2>&1; then
    local action
    action="$(echo "$result" | jq -r '.result')"
    echo "[entity] $action: $eid"
  else
    echo "[entity] failed: $eid" >&2
    echo "$result" >&2
    return 1
  fi
}

# ── Bulk index all files in BRIDGE_WATCH_DIRS ────────────────────────────────

entity_index_all() {
  local quiet=false
  [[ "${1:-}" == "--quiet" ]] && quiet=true

  if ! es_online; then
    $quiet || echo "Offline — skipping entity index"
    return
  fi

  local indexed=0 failed=0

  for watch_dir in $BRIDGE_WATCH_DIRS; do
    [[ -d "$watch_dir" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      if entity_index_file "$f" 2>/dev/null; then
        indexed=$((indexed + 1))
      else
        failed=$((failed + 1))
      fi
    done < <(find "$watch_dir" -name "*.md" -not -path "*/.git/*" -print0)
  done

  $quiet || echo "Entity index: $indexed indexed, $failed failed"
}

# ── Entity health check ───────────────────────────────────────────────────────

entity_health() {
  local count_result
  count_result="$(es_request GET "/${IDX_ENTITIES}/_count" "" 2>/dev/null)"
  local count
  count="$(echo "$count_result" | jq -r '.count // 0')"
  echo "Entities: $count"
  echo "Index: $IDX_ENTITIES"
  echo "Watch dirs: $BRIDGE_WATCH_DIRS"
}

# ── graph-search ──────────────────────────────────────────────────────────────
# ES|QL FORK/FUSE hybrid: 0.3 lexical + 0.7 semantic
# Usage: graph_search "query" [--types T1,T2] [--days 180] [--all-time] [--limit 10]
graph_search() {
  local query="$1"
  shift

  # Default 180-day recency window; use --all-time to disable
  local types="" days="180" all_time=0 limit=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --types)    types="$2";    shift 2 ;;
      --days)     days="$2";     shift 2 ;;
      --all-time) all_time=1;    shift ;;
      --limit)    limit="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "ES offline — cannot graph-search" >&2
    return 1
  fi

  # Escape query for safe ESQL interpolation
  local safe_query="${query//\\/\\\\}"
  safe_query="${safe_query//\"/\\\"}"

  # Build type filter clause
  local type_filter=""
  if [[ -n "$types" ]]; then
    local type_list
    type_list="$(echo "$types" | sed 's/,/","/g')"
    type_filter="| WHERE entity_type IN (\"${type_list}\")"
  fi

  # Build date filter clause
  local date_filter=""
  if [[ $all_time -eq 0 ]]; then
    date_filter="| WHERE updated_at >= NOW() - ${days} days"
  fi

  local esql_query
  esql_query="$(cat <<ESQL
FROM ${IDX_ENTITIES} METADATA _id, _score, _index
| FORK (
    WHERE MATCH(title, "${safe_query}") OR MATCH(content, "${safe_query}")
    ${type_filter}
    ${date_filter}
    | SORT _score DESC | LIMIT 20
) (
    WHERE MATCH(title_semantic, "${safe_query}") OR MATCH(content_semantic, "${safe_query}")
    ${type_filter}
    ${date_filter}
    | SORT _score DESC | LIMIT 20
)
| FUSE LINEAR WITH {"weights": {"0": 0.3, "1": 0.7}}
| SORT _score DESC | LIMIT ${limit}
| KEEP _id, entity_id, entity_type, title, status, priority, updated_at
ESQL
)"

  local result
  result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_query")}")"

  if echo "$result" | jq -e '.error' > /dev/null 2>&1; then
    echo "ES|QL error: $(echo "$result" | jq -r '.error.reason // .error.type')" >&2
    return 1
  fi

  echo "$result" | jq -r '
    .values[] |
    "[\(.[2])] \(.[3]) | status: \(.[4]) | priority: \(.[5]) | updated: \(.[6][:10]) | id: \(.[1])"
  '
}


# ── graph-related ─────────────────────────────────────────────────────────────
# Usage: graph_related <entity_id> [--depth 1|2] [--rel-type TYPE] [--limit 20]
graph_related() {
  local start_id="$1"
  shift

  local depth=1 rel_type="" limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --depth)    depth="$2";    shift 2 ;;
      --rel-type) rel_type="$2"; shift 2 ;;
      --limit)    limit="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "ES offline" >&2
    return 1
  fi

  local start
  start="$(es_request GET "/${IDX_ENTITIES}/_doc/${start_id}")"
  if ! echo "$start" | jq -e '.found' > /dev/null 2>&1; then
    echo "Entity not found: ${start_id}" >&2
    return 1
  fi

  local title
  title="$(echo "$start" | jq -r '._source.title')"
  echo "Entity: ${start_id} — ${title}"
  echo "──────────────────────────────────────"

  local -A visited
  visited["$start_id"]=1

  local -A seen_edges
  _graph_traverse "$start_id" "$depth" "$rel_type" visited seen_edges

  local count=0
  for edge_key in "${!seen_edges[@]}"; do
    [[ $count -ge $limit ]] && break
    echo "${seen_edges[$edge_key]}"
    (( count++ ))
  done | sort -t'|' -k2 -rn | head -"$limit"
}

# Internal: traverse relationships up to N hops
_graph_traverse() {
  local entity_id="$1" remaining_depth="$2" rel_type_filter="$3"
  local -n _visited=$4
  local -n _edges=$5

  [[ $remaining_depth -le 0 ]] && return

  local rel_filter="{}"
  if [[ -n "$rel_type_filter" ]]; then
    rel_filter="{\"term\": {\"relationships.rel_type\": \"${rel_type_filter}\"}}"
  else
    rel_filter="{\"match_all\": {}}"
  fi

  local search_body
  search_body="$(jq -n \
    --arg eid "$entity_id" \
    --argjson rel_filter "$rel_filter" \
    '{
      "query": {"ids": {"values": [$eid]}},
      "_source": ["title", "entity_type", "status", "updated_at"],
      "inner_hits": {
        "rels": {
          "path": "relationships",
          "query": $rel_filter,
          "size": 10,
          "sort": [{"relationships.weight": "desc"}]
        }
      },
      "size": 1
    }')"

  local result
  result="$(es_request POST "/${IDX_ENTITIES}/_search" "$search_body")"

  local related_ids
  related_ids="$(echo "$result" | jq -r '
    .hits.hits[]?.inner_hits?.rels?.hits?.hits[]?._source |
    "\(.to_id)|\(.weight)|\(.rel_type)|\(.rel_description // "")"
  ' 2>/dev/null)"

  # Reverse query — find entities that point TO entity_id
  local reverse_body
  reverse_body="$(jq -n \
    --arg eid "$entity_id" \
    '{
      "query": {
        "nested": {
          "path": "relationships",
          "query": {"term": {"relationships.to_id": $eid}},
          "inner_hits": {
            "name": "reverse_rels",
            "size": 10,
            "sort": [{"relationships.weight": "desc"}]
          }
        }
      },
      "_source": ["entity_id", "title", "entity_type", "status", "updated_at", "relationships"],
      "size": 20
    }')"
  local reverse_result
  reverse_result="$(es_request POST "/${IDX_ENTITIES}/_search" "$reverse_body" 2>/dev/null)"

  # Process forward edges
  if [[ -n "$related_ids" ]]; then
    while IFS='|' read -r to_id weight rel_type rel_desc; do
      [[ -z "$to_id" ]] && continue
      [[ -v "_visited[$to_id]" ]] && continue
      _visited["$to_id"]=1

      local entity_doc
      entity_doc="$(es_request GET "/${IDX_ENTITIES}/_doc/${to_id}" 2>/dev/null)"
      local found
      found="$(echo "$entity_doc" | jq -r '.found // "false"')"

      if [[ "$found" == "true" ]]; then
        local e_title e_type e_status e_updated
        e_title="$(echo "$entity_doc" | jq -r '._source.title')"
        e_type="$(echo "$entity_doc" | jq -r '._source.entity_type')"
        e_status="$(echo "$entity_doc" | jq -r '._source.status // ""')"
        e_updated="$(echo "$entity_doc" | jq -r '._source.updated_at // "" | .[:10]')"
        local edge_line="  [${e_type}] ${e_title} (-> ${rel_type})|${weight}| status: ${e_status} | updated: ${e_updated} | id: ${to_id}"
        _edges["$to_id"]="$edge_line"
      else
        local edge_line="  [unknown] ${to_id} (-> ${rel_type})|${weight}| not indexed"
        _edges["$to_id"]="$edge_line"
      fi

      if [[ $remaining_depth -gt 1 ]]; then
        _graph_traverse "$to_id" $(( remaining_depth - 1 )) "$rel_type_filter" _visited _edges
      fi
    done <<< "$related_ids"
  fi

  # Process reverse edges
  local reverse_hits
  reverse_hits="$(echo "$reverse_result" | jq -c '.hits.hits[]._source // empty' 2>/dev/null)"
  if [[ -n "$reverse_hits" ]]; then
    while IFS= read -r src_doc; do
      local from_id from_title from_type from_status from_updated
      from_id="$(echo "$src_doc" | jq -r '.entity_id')"
      from_title="$(echo "$src_doc" | jq -r '.title')"
      from_type="$(echo "$src_doc" | jq -r '.entity_type')"
      from_status="$(echo "$src_doc" | jq -r '.status // ""')"
      from_updated="$(echo "$src_doc" | jq -r '.updated_at // "" | .[:10]')"

      [[ -z "$from_id" || "$from_id" == "null" ]] && continue
      [[ -v "_visited[$from_id]" ]] && continue
      _visited["$from_id"]=1

      local rev_rel_type
      rev_rel_type="$(echo "$src_doc" | jq -r \
        --arg eid "$entity_id" \
        '[.relationships[]? | select(.to_id == $eid) | .rel_type] | first // "references"')"

      local edge_line="  [${from_type}] ${from_title} (<- ${rev_rel_type})|0.5| status: ${from_status} | updated: ${from_updated} | id: ${from_id}"
      _edges["$from_id"]="$edge_line"

      if [[ $remaining_depth -gt 1 ]]; then
        _graph_traverse "$from_id" $(( remaining_depth - 1 )) "$rel_type_filter" _visited _edges
      fi
    done <<< "$reverse_hits"
  fi
}


# ── check-blockers ────────────────────────────────────────────────────────────
# Usage: check_blockers [--stale-days 3]
check_blockers() {
  local stale_days=3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stale-days) stale_days="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "ES offline" >&2
    return 1
  fi

  local esql_query
  esql_query="$(cat <<ESQL
FROM ${IDX_ENTITIES} METADATA _id
| WHERE status IN ("blocked", "waiting")
| WHERE updated_at < NOW() - ${stale_days} days
| SORT updated_at ASC
| KEEP entity_id, entity_type, title, status, priority, updated_at, initiative
ESQL
)"

  local result
  result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_query")}")"

  if echo "$result" | jq -e '.error' > /dev/null 2>&1; then
    echo "ES|QL error: $(echo "$result" | jq -r '.error.reason // .error.type')" >&2
    return 1
  fi

  local count
  count="$(echo "$result" | jq '.values | length')"

  if [[ "$count" == "0" ]]; then
    echo "No blocked/waiting items stale > ${stale_days} days"
    return
  fi

  echo "${count} stale blocked/waiting items (no update in ${stale_days}+ days):"
  echo ""
  echo "$result" | jq -r '
    .values[] |
    "  [\(.[1])] \(.[2]) | status: \(.[3]) | priority: \(.[4]) | last update: \(.[5][:10]) | initiative: \(.[6] // "—")"
  '
}


# ── semantic-diff ─────────────────────────────────────────────────────────────
# Compare entity state across two date ranges
# Usage: semantic_diff <from-date> <to-date>  e.g. semantic_diff 2026-01-01 2026-04-01
semantic_diff() {
  local from_date="$1" to_date="$2"

  if [[ -z "$from_date" || -z "$to_date" ]]; then
    echo "Usage: bridge graph semantic-diff <from-date> <to-date>" >&2
    return 1
  fi

  if ! es_online; then
    echo "ES offline" >&2
    return 1
  fi

  echo "Semantic diff: ${from_date} -> ${to_date}"
  echo "══════════════════════════════════════════"

  # Status/priority breakdown in window
  local esql_a
  esql_a="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE updated_at >= "${from_date}T00:00:00Z" AND updated_at < "${to_date}T00:00:00Z"
| STATS count = COUNT(*) BY status, priority, category
| SORT count DESC
ESQL
)"

  echo ""
  echo "Status/Priority breakdown (updated in window):"
  es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_a")}" | \
    jq -r '.values[] | "  \(.[0]) | \(.[1]) | \(.[2]) — \(.[3]) entities"'

  # New in period
  local esql_new
  esql_new="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE created_at >= "${from_date}T00:00:00Z" AND created_at < "${to_date}T00:00:00Z"
| SORT created_at ASC
| KEEP entity_id, entity_type, title, status, priority, created_at
ESQL
)"

  echo ""
  echo "Created in window:"
  local new_result
  new_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_new")}")"
  local new_count
  new_count="$(echo "$new_result" | jq '.values | length')"
  if [[ "$new_count" == "0" ]]; then
    echo "  (none)"
  else
    echo "$new_result" | jq -r '.values[] | "  [\(.[1])] \(.[2]) — \(.[3]) | created: \(.[5][:10])"'
  fi

  # Completed in period
  local esql_done
  esql_done="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE status == "done" AND updated_at >= "${from_date}T00:00:00Z" AND updated_at < "${to_date}T00:00:00Z"
| SORT updated_at DESC
| KEEP entity_id, entity_type, title, updated_at
ESQL
)"

  echo ""
  echo "Completed in window:"
  local done_result
  done_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_done")}")"
  local done_count
  done_count="$(echo "$done_result" | jq '.values | length')"
  if [[ "$done_count" == "0" ]]; then
    echo "  (none)"
  else
    echo "$done_result" | jq -r '.values[] | "  [\(.[1])] \(.[2]) | completed: \(.[3][:10])"'
  fi

  # Active blockers in period
  local esql_blocked
  esql_blocked="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE status IN ("blocked", "waiting") AND updated_at >= "${from_date}T00:00:00Z"
| KEEP entity_id, entity_type, title, status, updated_at
| SORT updated_at DESC
ESQL
)"

  echo ""
  echo "Currently blocked/waiting:"
  local blocked_result
  blocked_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_blocked")}")"
  local blocked_count
  blocked_count="$(echo "$blocked_result" | jq '.values | length')"
  if [[ "$blocked_count" == "0" ]]; then
    echo "  (none)"
  else
    echo "$blocked_result" | jq -r '.values[] | "  [\(.[1])] \(.[2]) — \(.[3]) | updated: \(.[4][:10])"'
  fi

  # Stale: active/blocked entities NOT updated in the window
  local esql_stale
  esql_stale="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE updated_at < "${from_date}T00:00:00Z"
| WHERE status IN ("active", "blocked", "waiting", "explore")
| SORT updated_at ASC
| KEEP entity_id, entity_type, title, status, priority, updated_at
| LIMIT 10
ESQL
)"

  echo ""
  echo "Stale (active/blocked, no update since ${from_date}):"
  local stale_result
  stale_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_stale")}")"
  local stale_count
  stale_count="$(echo "$stale_result" | jq '.values | length')"
  if [[ "$stale_count" == "0" ]]; then
    echo "  (none)"
  else
    echo "$stale_result" | jq -r '.values[] | "  [\(.[1])] \(.[2]) — \(.[3])/\(.[4]) | last: \(.[5][:10])"'
  fi

  # Most-changed: entities with highest snapshot count in window (from history index)
  local history_count
  history_count="$(es_request GET "/${IDX_ENTITY_HISTORY}/_count" '{}' 2>/dev/null | jq '.count // 0' 2>/dev/null || echo 0)"

  if [[ "$history_count" -gt 0 ]]; then
    local esql_hotspot
    esql_hotspot="$(cat <<ESQL
FROM ${IDX_ENTITY_HISTORY}
| WHERE snapshot_at >= "${from_date}T00:00:00Z" AND snapshot_at <= "${to_date}T23:59:59Z"
| STATS changes = COUNT(*) BY entity_id, entity_type, title
| SORT changes DESC
| LIMIT 10
ESQL
)"

    echo ""
    echo "Most active in window (by snapshot count):"
    local hotspot_result
    hotspot_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_hotspot")}")"
    local hot_count
    hot_count="$(echo "$hotspot_result" | jq '.values | length')"
    if [[ "$hot_count" == "0" ]]; then
      echo "  (no history snapshots in window yet)"
    else
      echo "$hotspot_result" | jq -r '.values[] | "  \(.[0])x  [\(.[1])] \(.[2])"'
    fi
  fi
}


# ── gen-handoff ───────────────────────────────────────────────────────────────
# Usage: gen_handoff [--hours 8] [--synthesize]
#   --synthesize  pipe ES data through BRIDGE_SYNTHESIS_AGENT for a narrative summary;
#                 requires KIBANA_URL and BRIDGE_SYNTHESIS_AGENT in .env
gen_handoff() {
  local hours=8 synthesize=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hours)      hours="$2"; shift 2 ;;
      --synthesize) synthesize=1; shift ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "ES offline — cannot generate handoff context" >&2
    return 1
  fi

  # Entities updated in the last N hours
  # Use summary (200-char) instead of full content where available (~10x payload reduction)
  local esql_recent
  esql_recent="$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE updated_at >= NOW() - ${hours} hours
| SORT updated_at DESC
| EVAL display_summary = COALESCE(summary, SUBSTRING(content, 0, 400))
| KEEP entity_id, entity_type, title, status, priority, initiative, updated_at, display_summary
ESQL
)"

  local recent_result
  recent_result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_recent")}")"

  # Active sessions from agent-sessions in same window
  local sessions_result
  sessions_result="$(es_request POST "/_query" \
    "{\"query\": \"FROM ${IDX_SESSIONS}\n| WHERE timestamp >= NOW() - ${hours} hours\n| SORT timestamp DESC\n| KEEP session_id, action, summary, files_touched, timestamp\n| LIMIT 20\"}")"

  # Active blockers
  local blockers_result
  blockers_result="$(es_request POST "/_query" \
    "{\"query\": \"FROM ${IDX_ENTITIES}\n| WHERE status IN (\\\"blocked\\\", \\\"waiting\\\")\n| EVAL display_summary = COALESCE(summary, SUBSTRING(content, 0, 400))\n| KEEP entity_id, title, status, initiative, updated_at, display_summary\n| SORT updated_at DESC\"}")"

  local handoff_json
  handoff_json="$(jq -n \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson hours "$hours" \
    --argjson recent "$recent_result" \
    --argjson sessions "$sessions_result" \
    --argjson blockers "$blockers_result" \
    '{
      generated_at: $generated_at,
      window_hours: $hours,
      entities_updated: ($recent.values // []),
      entity_columns: ($recent.columns // []),
      sessions: ($sessions.values // []),
      session_columns: ($sessions.columns // []),
      active_blockers: ($blockers.values // []),
      blocker_columns: ($blockers.columns // [])
    }')"

  if [[ "$synthesize" -eq 1 ]]; then
    local synthesis_agent="${BRIDGE_SYNTHESIS_AGENT:-}"
    if [[ -z "$synthesis_agent" ]]; then
      echo "BRIDGE_SYNTHESIS_AGENT not set — outputting raw JSON" >&2
      echo "$handoff_json"
      return
    fi
    local synthesis_input="Generate a concise handoff summary from this ES data (window: ${hours}h): ${handoff_json}"
    agent_converse "$synthesis_agent" "$synthesis_input"
  else
    echo "$handoff_json"
  fi
}


# ── graph-health ──────────────────────────────────────────────────────────────
# Generic operational health check for the entity knowledge graph
# Usage: graph_health
graph_health() {
  if ! es_online; then
    echo "ES offline — cannot run health check" >&2
    return 1
  fi

  echo "=== Knowledge Graph Health ==="
  echo ""

  # Entity count
  local entity_count_result
  entity_count_result="$(es_request GET "/${IDX_ENTITIES}/_count")"
  local entity_count
  entity_count="$(echo "$entity_count_result" | jq -r '.count // "?"')"
  echo "Entities:  ${entity_count}"

  # History snapshots in last 24h
  local history_count_result
  history_count_result="$(es_request POST "/${IDX_ENTITY_HISTORY}/_count" \
    '{"query": {"range": {"snapshot_at": {"gte": "now-24h"}}}}')"
  local history_count
  history_count="$(echo "$history_count_result" | jq -r '.count // "?"')"
  echo "Snapshots (24h): ${history_count}"

  # Entities with summary field (enrichment coverage)
  local summary_result
  summary_result="$(es_request POST "/${IDX_ENTITIES}/_count" \
    '{"query": {"exists": {"field": "summary"}}}')"
  local summary_count
  summary_count="$(echo "$summary_result" | jq -r '.count // "0"')"
  echo "With summary:    ${summary_count} / ${entity_count}"

  echo ""
  echo "── Ingest alerts ──"
  # Unread alerts tagged with BRIDGE_INGEST_ALERT_TAGS
  local alerts_result
  alerts_result="$(es_request POST "/${IDX_MESSAGES}/_search" \
    "$(jq -n --arg tag "$BRIDGE_INGEST_ALERT_TAGS" \
      '{"query": {"bool": {"must": [{"term": {"status": "unread"}}, {"term": {"tags": $tag}}]}}, "size": 10, "_source": ["subject", "machine", "created_at", "body"]}')")"
  local alert_count
  alert_count="$(echo "$alerts_result" | jq -r '.hits.total.value // 0')"

  if [[ "$alert_count" -eq 0 ]]; then
    echo "No open ingest alerts"
  else
    echo "${alert_count} unread alert(s) [tag: ${BRIDGE_INGEST_ALERT_TAGS}]:"
    echo "$alerts_result" | jq -r '
      .hits.hits[]._source |
      "  [" + .machine + "] " + .created_at[:16] + " — " + .subject
    '
  fi

  echo ""
  # Summary status line
  if [[ "$alert_count" -eq 0 ]]; then
    echo "Health OK — ${entity_count} entities, no open alerts"
  else
    echo "${alert_count} alert(s) need attention"
  fi
}


# ── Dispatch ──────────────────────────────────────────────────────────────────

entity_dispatch() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    index-file)  entity_index_file "$@" ;;
    index-all)   entity_index_all "$@" ;;
    search)      entity_search "$@" ;;
    health)      entity_health "$@" ;;
    help|-h|--help)
      cat <<'EOF'
bridge entity <subcommand>

  index-file <path>       Index a single markdown file
  index-all [--quiet]     Bulk index all files in BRIDGE_WATCH_DIRS
  search <query> [limit]  Keyword search across indexed entities
  health                  Show entity count and index info

Config (.env):
  BRIDGE_WATCH_DIRS   Space-separated directories to watch (default: $PWD)
  BRIDGE_ENTITY_TYPES Subdir->type mapping: "docs:doc,notes:note,projects:project"
EOF
      ;;
    *) echo "Unknown entity subcommand: $subcmd" >&2; entity_dispatch help >&2; return 1 ;;
  esac
}

# Fallback keyword search (no hybrid — use graph search for hybrid)
entity_search() {
  local query="${1:-}"
  local limit="${2:-10}"
  [[ -z "$query" ]] && { echo "Usage: bridge entity search <query> [limit]" >&2; return 1; }

  local result
  result="$(es_request POST "/${IDX_ENTITIES}/_search" \
    "$(jq -n \
      --arg q "$query" \
      --argjson size "$limit" \
      '{
        "query": {
          "multi_match": {
            "query": $q,
            "fields": ["title^2", "content"]
          }
        },
        "size": $size,
        "_source": ["entity_id", "entity_type", "title", "status", "priority", "initiative", "updated_at", "source_path"]
      }')" 2>/dev/null)"

  if echo "$result" | jq -e '.hits.hits | length > 0' > /dev/null 2>&1; then
    echo "$result" | jq -r '.hits.hits[]._source | "[\(.entity_type)] \(.title) — status: \(.status // "—") | priority: \(.priority // "—")"'
  else
    echo "No entities found for: $query"
  fi
}

# ── graph-reconcile ───────────────────────────────────────────────────────────
# Delete ES entities whose source files no longer exist.
# Reads BRIDGE_ENTITY_ROOT and BRIDGE_ENTITY_TYPE_MAP to discover expected entities.
# Gated: skips if last reconcile was < 1 hour ago. Use --force to override.
# Usage: graph_reconcile [--force]
graph_reconcile() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=1; shift ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "ES offline — skipping reconcile" >&2
    return 1
  fi

  local sync_state_dir="$BRIDGE_DIR/.sync-state"
  local stamp_file="$sync_state_dir/last-reconcile"
  mkdir -p "$sync_state_dir"

  # Staleness gate: skip if last reconcile < 1 hour ago
  if [[ $force -eq 0 && -f "$stamp_file" ]]; then
    local last_run
    last_run="$(cat "$stamp_file")"
    local now_epoch
    now_epoch="$(date +%s)"
    local age=$(( now_epoch - last_run ))
    if [[ $age -lt 3600 ]]; then
      echo "Reconcile skipped — last run was ${age}s ago (< 1 hour). Use --force to override."
      return 0
    fi
  fi

  # Parse BRIDGE_ENTITY_TYPE_MAP ("dir:type,dir:type,...")
  # Dirs are resolved relative to BRIDGE_ENTITY_ROOT if set
  local root="${BRIDGE_ENTITY_ROOT:-}"
  local -A type_map

  if [[ -z "${BRIDGE_ENTITY_TYPE_MAP:-}" ]]; then
    echo "BRIDGE_ENTITY_TYPE_MAP not set — nothing to reconcile" >&2
    return 0
  fi

  IFS=',' read -ra pairs <<< "$BRIDGE_ENTITY_TYPE_MAP"
  for pair in "${pairs[@]}"; do
    local dir="${pair%%:*}" etype="${pair##*:}"
    [[ -n "$root" ]] && dir="${root}/${dir}"
    type_map["$dir"]="$etype"
  done

  # Collect all expected entity_ids from source files
  local -A expected
  local skip_files=("_index.md" ".gitkeep")
  local skip_dirs=("archive")

  for dir in "${!type_map[@]}"; do
    local etype="${type_map[$dir]}"
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
      local fname
      fname="$(basename "$f")"
      local skip=0
      for sf in "${skip_files[@]}"; do [[ "$fname" == "$sf" ]] && skip=1 && break; done
      for sd in "${skip_dirs[@]}"; do [[ "$f" == *"/$sd/"* ]] && skip=1 && break; done
      [[ $skip -eq 1 ]] && continue
      local stem="${fname%.md}"
      local slug
      slug="$(echo "$stem" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g')"
      expected["${BRIDGE_AGENT_ID}-${etype}-${slug}"]="$f"
    done < <(find "$dir" -maxdepth 2 -name "*.md" -print0 2>/dev/null)
  done

  echo "Expected entities: ${#expected[@]}"

  # Paginated fetch via search_after — handles >1000 entities without silent misses
  local orphans=0 checked=0
  local search_after_val="" page=0

  while true; do
    local page_body
    if [[ -z "$search_after_val" ]]; then
      page_body='{"query": {"match_all": {}}, "_source": ["entity_id", "source_file"], "sort": [{"entity_id": "asc"}], "size": 200}'
    else
      page_body="$(jq -n \
        --argjson sa "$search_after_val" \
        '{"query": {"match_all": {}}, "_source": ["entity_id", "source_file"], "sort": [{"entity_id": "asc"}], "size": 200, "search_after": $sa}')"
    fi

    local page_result
    page_result="$(es_request POST "/${IDX_ENTITIES}/_search" "$page_body")"
    local page_hits
    page_hits="$(echo "$page_result" | jq -c '.hits.hits // []')"
    local hit_count
    hit_count="$(echo "$page_hits" | jq 'length')"

    [[ "$hit_count" -eq 0 ]] && break
    (( page++ )) || true

    while IFS= read -r line; do
      local eid src_file
      eid="$(echo "$line" | jq -r '.entity_id')"
      src_file="$(echo "$line" | jq -r '.source_file')"
      (( checked++ )) || true

      if [[ ! -v "expected[$eid]" ]]; then
        echo "  Orphan: $eid (was: $src_file)"
        local del_result
        del_result="$(es_request DELETE "/${IDX_ENTITIES}/_doc/${eid}")"
        if echo "$del_result" | jq -e '.result == "deleted"' > /dev/null 2>&1; then
          echo "    -> deleted"
          (( orphans++ )) || true
        else
          echo "    -> delete failed: $(echo "$del_result" | jq -r '.error.reason // "unknown"')"
        fi
      fi
    done < <(echo "$page_result" | jq -c '.hits.hits[]._source')

    search_after_val="$(echo "$page_result" | jq -c '.hits.hits[-1].sort')"
    [[ "$hit_count" -lt 200 ]] && break
  done

  echo "Checked: ${checked} (${page} page(s)) | Orphans removed: ${orphans}"
  date +%s > "$stamp_file"
}


graph_dispatch() {
  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    search)         graph_search "$@" ;;
    related)        graph_related "$@" ;;
    check-blockers) check_blockers "$@" ;;
    semantic-diff)  semantic_diff "$@" ;;
    gen-handoff)    gen_handoff "$@" ;;
    health)         graph_health "$@" ;;
    reconcile)      graph_reconcile "$@" ;;
    help|-h|--help)
      cat <<'EOF'
bridge graph — Knowledge graph search and analysis

SEARCH
  bridge graph search <query> [--types T1,T2] [--days N] [--all-time] [--limit N]
    Hybrid ES|QL search (0.3 BM25 + 0.7 semantic Jina v5)
    Default: 180-day recency window. Use --all-time for historical queries.

RELATIONSHIPS
  bridge graph related <entity_id> [--depth 1|2] [--rel-type TYPE] [--limit N]
    Traverse relationships (forward + reverse) up to N hops (cycle-safe)

HEALTH
  bridge graph health
    Entity count, snapshot count, summary coverage, open alerts

  bridge graph check-blockers [--stale-days N]
    List blocked/waiting entities with no update in N days

ANALYSIS
  bridge graph semantic-diff <from-date> <to-date>
    Snapshot diff: new/completed/blocked entities between two dates

HANDOFF
  bridge graph gen-handoff [--hours N] [--synthesize]
    Structured JSON context for handoff (uses summary field, ~10x smaller)
    --synthesize: pipe through BRIDGE_SYNTHESIS_AGENT for narrative summary

MAINTENANCE
  bridge graph reconcile [--force]
    Delete ES entities whose source files no longer exist
    Reads BRIDGE_ENTITY_TYPE_MAP for source dir → entity type mapping
    (gated: skips if last run < 1 hour)

Config (.env):
  BRIDGE_SYNTHESIS_AGENT    Agent Builder agent ID for --synthesize
  BRIDGE_INGEST_ALERT_TAGS  Alert tags to monitor (default: ingest-failure)
  BRIDGE_ENTITY_ROOT        Base directory for BRIDGE_ENTITY_TYPE_MAP paths
  BRIDGE_ENTITY_TYPE_MAP    Comma-separated dir:type pairs, e.g. "projects:project,ideas:idea"
EOF
      ;;
    *) echo "Unknown graph subcommand: $subcmd" >&2; graph_dispatch help >&2; return 1 ;;
  esac
}
