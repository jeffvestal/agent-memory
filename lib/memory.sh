#!/usr/bin/env bash
# memory.sh — remember, recall, forget

# es.sh and fallback.sh must be sourced before this file

# Generate a memory ID
_mem_id() {
  echo "mem-$(date +%s)-$(openssl rand -hex 4)"
}

# Store a memory
# Usage: mem_remember <type> <content> [--title "title"] [--tags t1,t2] [--scope shared] [--category cat]
#                     [--immutable] [--no-consolidate] [--dry-run]
#   Fact-like types (see consolidate.sh) are checked against similar memories on write: an older fact
#   the new one replaces is marked superseded, a duplicate is merged. --dry-run shows the judge's
#   verdicts without writing anything. --immutable keeps a memory out of consolidation for good.
mem_remember() {
  local type="${1:-}" content="${2:-}"
  # A missing type shifts every argument left (content lands in type, a flag in content). That
  # wrote 4 junk docs in 2026, so refuse anything that doesn't look like a one-word type.
  if [[ -z "$type" || -z "$content" || "$type" == -* || "$content" == --* \
        || ${#type} -gt 40 || "$type" =~ [[:space:]] ]]; then
    echo "Usage: bridge remember <type> <content> [--title T] [--tags t1,t2] [--scope S] [--category C]" >&2
    echo "  <type> is one word (decision, lesson, reference, handoff, ...); got type='${type:0:40}'" >&2
    return 2
  fi
  shift 2

  local title="" tags="[]" scope="${BRIDGE_AGENT_ID}-only" category=""
  local immutable=false consolidate=1 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --tags) tags="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --category) category="$2"; shift 2 ;;
      --immutable) immutable=true; shift ;;
      --no-consolidate) consolidate=0; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) shift ;;
    esac
  done

  local do_consolidate=0
  if [[ "$consolidate" == "1" && "$immutable" == "false" ]] && declare -F consolidate_eligible > /dev/null \
     && consolidate_eligible "$type"; then
    do_consolidate=1
  fi

  if [[ "$dry_run" == "1" ]]; then
    if [[ "$do_consolidate" == "0" ]]; then
      echo "dry-run: type '$type' is not consolidated (BRIDGE_CONSOLIDATE_TYPES), nothing to check"
    elif ! es_online; then
      echo "dry-run: ES offline" >&2; return 1
    else
      echo "dry-run [$type]: ${title:-${content:0:60}}"
      mem_consolidate "(new)" "$type" "$title" "$content" --dry-run
    fi
    return 0
  fi

  local mem_id
  mem_id="$(_mem_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg mid "$mem_id" \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg type "$type" \
    --arg category "$category" \
    --arg title "$title" \
    --arg content "$content" \
    --argjson tags "$tags" \
    --arg source "bridge-cli" \
    --arg created "$now" \
    --arg updated "$now" \
    --arg scope "$scope" \
    --argjson immutable "$immutable" \
    '{
      memory_id: $mid,
      agent: $agent,
      type: $type,
      category: $category,
      title: $title,
      title_semantic: $title,
      content: $content,
      content_semantic: $content,
      tags: $tags,
      source: $source,
      created_at: $created,
      updated_at: $updated,
      access_scope: $scope,
      status: "active"
    } + (if $immutable then {immutable: true} else {} end)')"

  if es_online; then
    local result
    result="$(es_index "$IDX_MEMORY" "$mem_id" "$doc")"
    if echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      echo "Remembered [$type]: ${title:-${content:0:60}}... [${mem_id}]"
      [[ "$do_consolidate" == "1" ]] && mem_consolidate "$mem_id" "$type" "$title" "$content"
    else
      fallback_queue "$IDX_MEMORY" "$mem_id" "$doc"
      echo "ES error — queued to fallback [${mem_id}]" >&2
    fi
  else
    fallback_queue "$IDX_MEMORY" "$mem_id" "$doc"
    echo "Offline — queued memory [${mem_id}]"
  fi
}

# Search memories
# Usage: mem_recall <query> [--type X] [--category X] [--limit 5] [--semantic|--keyword|--hybrid] [--json] [--all]
#   --json  print a JSON array [{memory_id, type, title, access_scope, agent, score, status}] in rank order
#           (score = fused+decayed for hybrid, _score otherwise). Exits 1 when ES is unreachable.
#   --all   include superseded, merged and retired memories (history). Default: active only.
mem_recall() {
  local query="$1"
  shift

  local type_filter="" category_filter="" limit=5 mode="hybrid" json_out=0 include_all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type_filter="$2"; shift 2 ;;
      --category) category_filter="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --semantic) mode="semantic"; shift ;;
      --keyword) mode="keyword"; shift ;;
      --hybrid) mode="hybrid"; shift ;;
      --json) json_out=1; shift ;;
      --all) include_all=1; shift ;;
      *) shift ;;
    esac
  done

  local safe_query="${query//\\/\\\\}"
  safe_query="${safe_query//\"/\\\"}"

  local type_clause="" category_clause="" status_clause=""
  [[ -n "$type_filter" ]]     && type_clause="| WHERE type == \"${type_filter}\""
  [[ -n "$category_filter" ]] && category_clause="| WHERE category == \"${category_filter}\""
  # Docs written before the status field existed have none; they count as active.
  [[ "$include_all" == "0" ]] && status_clause="| WHERE status IS NULL OR status == \"active\""

  if ! es_online; then
    if [[ "$json_out" == "1" ]]; then
      echo "ES offline — recall unavailable" >&2
      return 1
    fi
    echo "Offline — searching fallback memory"
    fallback_search_memory "$query"
    return
  fi

  # Build scope filter: show shared + own agent's memories
  local filter_clauses="[]"
  filter_clauses="$(jq -n \
    --arg agent "$BRIDGE_AGENT_ID" \
    '[
      {"bool": {"should": [
        {"term": {"access_scope": "shared"}},
        {"term": {"access_scope": ($agent + "-only")}},
        {"term": {"agent": $agent}}
      ]}}
    ]')"

  if [[ -n "$type_filter" ]]; then
    filter_clauses="$(echo "$filter_clauses" | jq --arg t "$type_filter" '. + [{"term": {"type": $t}}]')"
  fi
  if [[ -n "$category_filter" ]]; then
    filter_clauses="$(echo "$filter_clauses" | jq --arg c "$category_filter" '. + [{"term": {"category": $c}}]')"
  fi
  if [[ "$include_all" == "0" ]]; then
    filter_clauses="$(echo "$filter_clauses" | jq '. + [{"bool": {"should": [
      {"bool": {"must_not": [{"exists": {"field": "status"}}]}},
      {"term": {"status": "active"}}]}}]')"
  fi

  local search_body
  case "$mode" in
    semantic)
      search_body="$(jq -n \
        --arg q "$query" \
        --argjson filter "$filter_clauses" \
        --argjson limit "$limit" \
        '{
          "retriever": {
            "standard": {
              "query": {
                "bool": {
                  "must": [{"semantic": {"field": "content_semantic", "query": $q}}],
                  "filter": $filter
                }
              }
            }
          },
          "size": $limit
        }')"
      ;;
    keyword)
      search_body="$(jq -n \
        --arg q "$query" \
        --argjson filter "$filter_clauses" \
        --argjson limit "$limit" \
        '{
          "query": {
            "bool": {
              "must": [{"multi_match": {"query": $q, "fields": ["title^2", "content", "tags"]}}],
              "filter": $filter
            }
          },
          "sort": [{"_score": "desc"}, {"updated_at": "desc"}],
          "size": $limit
        }')"
      ;;
    hybrid)
      # DECAY() needs a time_duration (hours/minutes); "45d"/"45 days" parse as
      # keyword/date_period and fail. Convert the window (Nd, Nw, Nh) to hours.
      local decay_window="${BRIDGE_MEMORY_DECAY_WINDOW:-45d}" decay_hours
      case "$decay_window" in
        *d) decay_hours=$(( ${decay_window%d} * 24 )) ;;
        *w) decay_hours=$(( ${decay_window%w} * 168 )) ;;
        *h) decay_hours="${decay_window%h}" ;;
        *)  decay_hours=1080 ;;
      esac
      local esql_query
      esql_query="$(cat <<ESQL
FROM ${IDX_MEMORY} METADATA _id, _score, _index
| FORK (
    WHERE (access_scope == "shared" OR access_scope == "${BRIDGE_AGENT_ID}-only" OR agent == "${BRIDGE_AGENT_ID}") AND (content:"${safe_query}" OR title:"${safe_query}" OR tags:"${safe_query}")
    ${type_clause}
    ${category_clause}
    ${status_clause}
    | SORT _score DESC | LIMIT 50
) (
    WHERE (access_scope == "shared" OR access_scope == "${BRIDGE_AGENT_ID}-only" OR agent == "${BRIDGE_AGENT_ID}") AND content_semantic:"${safe_query}"
    ${type_clause}
    ${category_clause}
    ${status_clause}
    | SORT _score DESC | LIMIT 50
)
| FUSE
| EVAL final_score = _score * DECAY(created_at, NOW(), ${decay_hours} hours)
| EVAL display = COALESCE(title, SUBSTRING(content, 1, 80))
| SORT final_score DESC | LIMIT ${limit}
| KEEP memory_id, type, display, access_scope, agent, final_score, status
ESQL
)"
      ;;
  esac

  local result count

  if [[ "$mode" == "hybrid" ]]; then
    result="$(es_request POST "/_query" "{\"query\": $(jq -Rs '.' <<< "$esql_query")}")"
    if echo "$result" | jq -e '.error' > /dev/null 2>&1; then
      echo "ES|QL error: $(echo "$result" | jq -r '.error.reason // .error.type')" >&2
      return 1
    fi
    count="$(echo "$result" | jq '.values | length')"
    if [[ "$json_out" == "1" ]]; then
      echo "$result" | jq -c '[.values[] | {memory_id: .[0], type: .[1], title: .[2], access_scope: .[3], agent: .[4], score: .[5], status: (.[6] // "active")}]'
    elif [[ "$count" == "0" ]]; then
      echo "No memories found for: $query"
      return
    else
      # KEEP order: memory_id[0], type[1], display[2], access_scope[3], agent[4], final_score[5], status[6]
      echo "$result" | jq -r '.values[] | "[\(.[1])\(if (.[6] // "active") != "active" then "·" + .[6] else "" end)] \(.[2]) (scope: \(.[3]), agent: \(.[4])) [\(.[0])]"'
    fi
    [[ "$count" == "0" ]] && return
    recall_log "bridge-recall" "$query" "$(echo "$result" | jq -c '[.values[] | {id: .[0], index: "'"$IDX_MEMORY"'", title: .[2]}]')"
  else
    result="$(es_search "$IDX_MEMORY" "$search_body")"
    if echo "$result" | jq -e '.error' > /dev/null 2>&1; then
      echo "ES error: $(echo "$result" | jq -r '.error.reason // .error.type')" >&2
      return 1
    fi
    count="$(echo "$result" | jq '.hits.total.value // 0')"
    if [[ "$json_out" == "1" ]]; then
      echo "$result" | jq -c '[.hits.hits[] | {memory_id: ._source.memory_id, type: ._source.type, title: (._source.title // ._source.content[:80]), access_scope: ._source.access_scope, agent: ._source.agent, score: ._score, status: (._source.status // "active")}]'
    elif [[ "$count" == "0" ]]; then
      echo "No memories found for: $query"
      return
    else
      echo "$result" | jq -r '.hits.hits[]._source | "[\(.type)\(if (.status // "active") != "active" then "·" + .status else "" end)] \(.title // .content[:80]) (scope: \(.access_scope), agent: \(.agent)) [\(.memory_id)]"'
    fi
    [[ "$count" == "0" ]] && return
    recall_log "bridge-recall" "$query" "$(echo "$result" | jq -c '[.hits.hits[]._source | {id: .memory_id, index: "'"$IDX_MEMORY"'", title: (.title // .content[:80])}]')"
  fi
}

# Memory lifecycle: status is active (or absent, for docs older than the field) | superseded |
# merged | retired. Only active memories come back from recall unless --all.
# Usage: _mem_set_status <id> <status> <reason> [link_field link_id]
_mem_set_status() {
  local id="$1" status="$2" reason="${3:-}" link_field="${4:-}" link_id="${5:-}"
  local body
  body="$(jq -nc --arg s "$status" --arg r "$reason" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lf "$link_field" --arg li "$link_id" '
    {status: $s, status_at: $now, updated_at: $now}
    + (if $r != "" then {status_reason: $r} else {} end)
    + (if $lf != "" then {($lf): $li} else {} end)')"
  es_update "$IDX_MEMORY" "$id" "$body" | jq -e '.result == "updated" or .result == "noop"' > /dev/null 2>&1
}

# Retire, supersede or purge a memory. Only --purge deletes anything.
# Usage: mem_forget <memory_id> [--superseded-by new_id | --purge] [--reason "why"]
#   (default)           status=retired: hidden from recall, kept for history (recall --all)
#   --superseded-by ID  status=superseded, superseded_by=ID
#   --purge             delete it AND every older version chained to it via superseded_by/merged_into,
#                       so "forget that" can't resurface through an older copy
mem_forget() {
  local mem_id="${1:-}"
  if [[ -z "$mem_id" || "$mem_id" == --* ]]; then
    echo "Usage: bridge forget <memory_id> [--superseded-by ID | --purge] [--reason R]" >&2
    return 2
  fi
  shift

  local superseded_by="" purge=0 reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --superseded-by) superseded_by="$2"; shift 2 ;;
      --purge) purge=1; shift ;;
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! jq -e '.found' <<< "$(es_get "$IDX_MEMORY" "$mem_id")" > /dev/null 2>&1; then
    echo "No memory [$mem_id]" >&2
    return 1
  fi

  if [[ "$purge" == "1" ]]; then
    _mem_purge_chain "$mem_id"
    return
  fi

  if [[ -n "$superseded_by" ]]; then
    if ! jq -e '.found' <<< "$(es_get "$IDX_MEMORY" "$superseded_by")" > /dev/null 2>&1; then
      echo "No memory [$superseded_by] to supersede with" >&2
      return 1
    fi
    _mem_set_status "$mem_id" superseded "${reason:-manual}" superseded_by "$superseded_by" \
      && echo "Superseded [$mem_id] → [$superseded_by]" \
      || { echo "Failed to supersede [$mem_id]" >&2; return 1; }
  else
    _mem_set_status "$mem_id" retired "${reason:-manual}" \
      && echo "Retired [$mem_id] (hidden from recall; --purge deletes it)" \
      || { echo "Failed to retire [$mem_id]" >&2; return 1; }
  fi
}

# Delete a memory and every version that points to it (recursively).
_mem_purge_chain() {
  local root="$1"
  local -a queue=("$root") chain=()
  local -A seen=()
  local id kids
  while (( ${#queue[@]} )); do
    id="${queue[0]}"; queue=("${queue[@]:1}")
    [[ -n "${seen[$id]:-}" ]] && continue
    seen[$id]=1; chain+=("$id")
    kids="$(es_search "$IDX_MEMORY" "$(jq -nc --arg id "$id" \
      '{size: 100, _source: false, query: {bool: {should: [{term: {superseded_by: $id}}, {term: {merged_into: $id}}]}}}')" \
      | jq -r '.hits.hits[]._id' 2>/dev/null)"
    for k in $kids; do queue+=("$k"); done
  done

  local deleted=0 file_backed=()
  for id in "${chain[@]}"; do
    local src
    src="$(es_get "$IDX_MEMORY" "$id" | jq -r '._source.source // empty' 2>/dev/null)"
    if es_delete "$IDX_MEMORY" "$id" | jq -e '.result == "deleted"' > /dev/null 2>&1; then
      deleted=$((deleted + 1))
      [[ "$src" == "auto-memory" ]] && file_backed+=("$id")
    else
      echo "Failed to delete [$id]" >&2
    fi
  done
  echo "Purged [$root] and $((deleted - 1)) older version(s) (cascade_count=$((deleted - 1)))"
  if (( ${#file_backed[@]} )); then
    echo "  file-backed: ${file_backed[*]} — delete the memory file(s) too, or the next sync re-creates them" >&2
  fi
}
