#!/usr/bin/env bash
# es.sh — curl wrapper for Elasticsearch API

# Check if ES is reachable (2s timeout)
es_check() {
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 2 \
    -H "Authorization: ApiKey $BRIDGE_ES_API_KEY" \
    "$BRIDGE_ES_URL" 2>/dev/null
}

# Returns 0 if online, 1 if offline
es_online() {
  local code
  code="$(es_check)"
  [[ "$code" == "200" ]]
}

# Check if Kibana is reachable (2s timeout)
kibana_online() {
  if [[ -z "${KIBANA_URL:-}" ]]; then
    return 1
  fi
  local code
  code="$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 2 \
    -H "Authorization: ApiKey $BRIDGE_ES_API_KEY" \
    "${KIBANA_URL}/api/status" 2>/dev/null)"
  [[ "$code" == "200" ]]
}

# Generic ES request
# Usage: es_request METHOD /path [body]
es_request() {
  local method="$1" path="$2" body="${3:-}"
  local url="${BRIDGE_ES_URL}${path}"
  local args=(
    -s -X "$method"
    -H "Authorization: ApiKey $BRIDGE_ES_API_KEY"
    -H "Content-Type: application/json"
    --max-time "$BRIDGE_TIMEOUT"
  )
  if [[ -n "$body" ]]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}" "$url" 2>/dev/null
}

# Index a document
# Usage: es_index <index> <doc_id> <json_body>
es_index() {
  local index="$1" doc_id="$2" body="$3"
  es_request PUT "/${index}/_doc/${doc_id}" "$body"
}

# Search an index
# Usage: es_search <index> <query_json>
es_search() {
  local index="$1" query="$2"
  es_request POST "/${index}/_search" "$query"
}

# Get a document by ID
# Usage: es_get <index> <doc_id>
es_get() {
  local index="$1" doc_id="$2"
  es_request GET "/${index}/_doc/${doc_id}" ""
}

# Update a document (partial)
# Usage: es_update <index> <doc_id> <partial_json>
es_update() {
  local index="$1" doc_id="$2" body="$3"
  es_request POST "/${index}/_update/${doc_id}" "{\"doc\": $body}"
}

# Bulk API
# Usage: es_bulk <ndjson_body>
es_bulk() {
  local body="$1"
  es_request POST "/_bulk" "$body"
}

# Get index stats
# Usage: es_count <index>
es_count() {
  local index="$1"
  local result
  result="$(es_request POST "/${index}/_count" '{"query":{"match_all":{}}}')"
  echo "$result" | jq -r '.count // 0'
}
