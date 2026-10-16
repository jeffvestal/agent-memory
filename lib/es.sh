#!/usr/bin/env bash
# es.sh — curl wrapper for Elasticsearch API

# Check if ES is reachable (2s timeout)
es_check() {
  curl -s -o /dev/null -w "%{http_code}" \
    --max-time 2 \
    -H "Authorization: ApiKey $BRIDGE_ES_API_KEY" \
    "$BRIDGE_ES_URL" 2>/dev/null
}

# Returns 0 if online, 1 if offline or auth fails.
# Auth failures are reported separately so a rotated key isn't mistaken for an outage.
es_online() {
  local code
  code="$(es_check)"
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    echo "ES auth failed (HTTP $code) — BRIDGE_ES_API_KEY may be expired or rotated" >&2
    return 1
  fi
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

# Log which memories a recall returned, so "what memory is actually used" is measurable.
# Fire-and-forget: never slows or fails the recall itself. Disable with BRIDGE_RECALL_LOG=0.
# Usage: recall_log <channel> <query> <hits_json: [{"id":..,"index":..}, ...] in rank order>
recall_log() {
  [[ "${BRIDGE_RECALL_LOG:-1}" == "0" ]] && return 0
  local doc
  doc="$(jq -nc --arg ch "$1" --arg q "$2" --argjson hits "${3:-[]}" \
    --arg agent "${BRIDGE_AGENT_ID:-}" --arg m "${BRIDGE_MACHINE:-$(hostname -s)}" \
    --arg sid "${CLAUDE_SESSION_ID:-}" '
    { "@timestamp": (now | todate), channel: $ch, query: $q, agent: $agent, machine: $m,
      session_id: $sid, n_hits: ($hits | length), hit_ids: [$hits[].id],
      hits: ($hits | to_entries | map(.value + {rank: (.key + 1)})) }' 2>/dev/null)" || return 0
  ( curl -s -m 3 -o /dev/null -X POST "${BRIDGE_ES_URL}/${IDX_RECALL:-memory-recall-events}/_doc" \
      -H "Authorization: ApiKey $BRIDGE_ES_API_KEY" -H "Content-Type: application/json" \
      -d "$doc" >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}
