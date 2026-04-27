#!/usr/bin/env bash
# memory.sh — remember, recall, forget

# es.sh and fallback.sh must be sourced before this file

# Generate a memory ID
_mem_id() {
  echo "mem-$(date +%s)-$(openssl rand -hex 4)"
}

# Store a memory
# Usage: mem_remember <type> <content> [--title "title"] [--tags t1,t2] [--scope shared] [--category cat]
mem_remember() {
  local type="$1" content="$2"
  shift 2

  local title="" tags="[]" scope="${BRIDGE_AGENT_ID}-only" category=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --tags) tags="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --category) category="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

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
      access_scope: $scope
    }')"

  if es_online; then
    local result
    result="$(es_index "$IDX_MEMORY" "$mem_id" "$doc")"
    if echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      echo "Remembered [$type]: ${title:-${content:0:60}}... [${mem_id}]"
    else
      fallback_queue "$IDX_MEMORY" "$mem_id" "$doc"
      echo "ES error — queued to fallback [${mem_id}]"
    fi
  else
    fallback_queue "$IDX_MEMORY" "$mem_id" "$doc"
    echo "Offline — queued memory [${mem_id}]"
  fi
}

# Search memories
# Usage: mem_recall <query> [--type X] [--category X] [--limit 5] [--semantic|--keyword|--hybrid]
mem_recall() {
  local query="$1"
  shift

  local type_filter="" category_filter="" limit=5 mode="hybrid"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type) type_filter="$2"; shift 2 ;;
      --category) category_filter="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --semantic) mode="semantic"; shift ;;
      --keyword) mode="keyword"; shift ;;
      --hybrid) mode="hybrid"; shift ;;
      *) shift ;;
    esac
  done

  local safe_query="${query//\\/\\\\}"
  safe_query="${safe_query//\"/\\\"}"

  local type_clause="" category_clause=""
  [[ -n "$type_filter" ]]     && type_clause="| WHERE type == \"${type_filter}\""
  [[ -n "$category_filter" ]] && category_clause="| WHERE category == \"${category_filter}\""

  if ! es_online; then
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
      local esql_query
      esql_query="$(cat <<ESQL
FROM ${IDX_MEMORY} METADATA _id, _score, _index
| FORK (
    WHERE (access_scope == "shared" OR access_scope == "${BRIDGE_AGENT_ID}-only" OR agent == "${BRIDGE_AGENT_ID}") AND (content:"${safe_query}" OR title:"${safe_query}" OR tags:"${safe_query}")
    ${type_clause}
    ${category_clause}
    | SORT _score DESC | LIMIT 50
) (
    WHERE (access_scope == "shared" OR access_scope == "${BRIDGE_AGENT_ID}-only" OR agent == "${BRIDGE_AGENT_ID}") AND content_semantic:"${safe_query}"
    ${type_clause}
    ${category_clause}
    | SORT _score DESC | LIMIT 50
)
| FUSE
| EVAL final_score = _score * DECAY(created_at, NOW(), "${BRIDGE_MEMORY_DECAY_WINDOW}")
| EVAL display = COALESCE(title, SUBSTRING(content, 1, 80))
| SORT final_score DESC | LIMIT ${limit}
| KEEP memory_id, type, display, access_scope, agent
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
    if [[ "$count" == "0" ]]; then
      echo "No memories found for: $query"
      return
    fi
    # KEEP order: memory_id[0], type[1], display[2], access_scope[3], agent[4]
    echo "$result" | jq -r '.values[] | "[\(.[1])] \(.[2]) (scope: \(.[3]), agent: \(.[4])) [\(.[0])]"'
  else
    result="$(es_search "$IDX_MEMORY" "$search_body")"
    count="$(echo "$result" | jq '.hits.total.value // 0')"
    if [[ "$count" == "0" ]]; then
      echo "No memories found for: $query"
      return
    fi
    echo "$result" | jq -r '.hits.hits[]._source | "[\(.type)] \(.title // .content[:80]) (scope: \(.access_scope), agent: \(.agent)) [\(.memory_id)]"'
  fi
}

# Mark a memory as superseded
# Usage: mem_forget <memory_id> [--superseded-by new_id]
mem_forget() {
  local mem_id="$1"
  shift

  local superseded_by=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --superseded-by) superseded_by="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local update_body="{\"type\": \"superseded\", \"updated_at\": \"$now\""
  if [[ -n "$superseded_by" ]]; then
    update_body+=", \"supersedes\": \"$superseded_by\""
  fi
  update_body+="}"

  local result
  result="$(es_update "$IDX_MEMORY" "$mem_id" "$update_body")"
  if echo "$result" | jq -e '.result == "updated"' > /dev/null 2>&1; then
    echo "Forgot [$mem_id]"
  else
    echo "Failed to forget [$mem_id]" >&2
  fi
}
