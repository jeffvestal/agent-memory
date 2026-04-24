#!/usr/bin/env bash
# entities.sh — Semantic entity indexing and search
#
# Indexes markdown files from BRIDGE_WATCH_DIRS into Elasticsearch using
# Jina v5 semantic_text embeddings. Enables hybrid (lexical + semantic) search.
#
# Config (set in .env):
#   BRIDGE_WATCH_DIRS   — space-separated dirs to index (default: $PWD)
#   BRIDGE_ENTITY_TYPES — comma-separated subdirectory→type mapping (optional)
#                         e.g. "docs:doc,notes:note,projects:project"

BRIDGE_WATCH_DIRS="${BRIDGE_WATCH_DIRS:-$PWD}"

# ── Helpers ─────────────────────────────────────────────────────────────────

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

# ── Hybrid search ────────────────────────────────────────────────────────────

entity_search() {
  local query="${1:-}"
  local limit="${2:-10}"
  [[ -z "$query" ]] && { echo "Usage: bridge entity search <query> [limit]" >&2; return 1; }

  local esql_query
  esql_query=$(cat <<ESQL
FROM ${IDX_ENTITIES}
| WHERE agent == "${BRIDGE_AGENT_ID}"
| SORT updated_at DESC
| LIMIT ${limit}
| KEEP entity_id, entity_type, title, status, priority, initiative, updated_at
ESQL
)

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

# ── Health check ─────────────────────────────────────────────────────────────

entity_health() {
  local count_result
  count_result="$(es_request GET "/${IDX_ENTITIES}/_count" "" 2>/dev/null)"
  local count
  count="$(echo "$count_result" | jq -r '.count // 0')"
  echo "Entities: $count"
  echo "Index: $IDX_ENTITIES"
  echo "Watch dirs: $BRIDGE_WATCH_DIRS"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

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
  search <query> [limit]  Hybrid search across indexed entities
  health                  Show entity count and index info

Config (.env):
  BRIDGE_WATCH_DIRS   Space-separated directories to watch (default: $PWD)
  BRIDGE_ENTITY_TYPES Subdir→type mapping: "docs:doc,notes:note,projects:project"
EOF
      ;;
    *) echo "Unknown entity subcommand: $subcmd" >&2; entity_dispatch help >&2; return 1 ;;
  esac
}
