#!/usr/bin/env bash
# sessions.sh — log session actions, query history

# es.sh and fallback.sh must be sourced before this file

# Generate a session log ID
_session_id() {
  echo "sess-$(date +%s)-$(openssl rand -hex 4)"
}

# Log a session action
# Usage: session_log <action> <summary> [--tags t1,t2] [--files f1,f2]
session_log() {
  local action="$1" summary="$2"
  shift 2

  local tags="[]" files="[]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags) tags="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      --files) files="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      *) shift ;;
    esac
  done

  local sess_id
  sess_id="$(_session_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg sid "$sess_id" \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg machine "$BRIDGE_MACHINE" \
    --arg action "$action" \
    --arg summary "$summary" \
    --argjson files "$files" \
    --argjson tags "$tags" \
    --arg ts "$now" \
    '{
      session_id: $sid,
      agent: $agent,
      machine: $machine,
      action: $action,
      summary: $summary,
      summary_semantic: $summary,
      files_touched: $files,
      tags: $tags,
      timestamp: $ts
    }')"

  if es_online; then
    local result
    result="$(es_index "$IDX_SESSIONS" "$sess_id" "$doc")"
    if echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      echo "Logged [$action]: ${summary:0:60}"
    else
      fallback_queue "$IDX_SESSIONS" "$sess_id" "$doc"
      echo "ES error — queued session log"
    fi
  else
    fallback_queue "$IDX_SESSIONS" "$sess_id" "$doc"
    echo "Offline — queued session log [$action]"
  fi
}

# Query session history
# Usage: session_history [--agent X] [--last 7d] [--limit 20]
session_history() {
  local agent_filter="" last="7d" limit=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent) agent_filter="$2"; shift 2 ;;
      --last) last="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "Offline — cannot query session history"
    return 1
  fi

  local must_clauses="[{\"range\": {\"timestamp\": {\"gte\": \"now-${last}\"}}}]"
  if [[ -n "$agent_filter" ]]; then
    must_clauses="$(echo "$must_clauses" | jq --arg a "$agent_filter" '. + [{"term": {"agent": $a}}]')"
  fi

  local query
  query="{\"query\": {\"bool\": {\"must\": $must_clauses}}, \"sort\": [{\"timestamp\": \"desc\"}], \"size\": $limit}"

  local result
  result="$(es_search "$IDX_SESSIONS" "$query")"
  local count
  count="$(echo "$result" | jq '.hits.total.value // 0')"

  if [[ "$count" == "0" ]]; then
    echo "No session history in last $last."
    return
  fi

  echo "$result" | jq -r '.hits.hits[]._source | "\(.timestamp | split("T")[0]) \(.timestamp | split("T")[1][:5]) [\(.agent)@\(.machine)] \(.action): \(.summary[:80])"'
}
