#!/usr/bin/env bash
# messages.sh — send, check, reply, ack

# es.sh and fallback.sh must be sourced before this file

# Generate a message ID
_msg_id() {
  echo "msg-$(date +%s)-$(openssl rand -hex 4)"
}

# Send a message to another agent
# Usage: msg_send <to_agent> <type> <body> [--subject "subj"] [--priority normal] [--tags t1,t2]
msg_send() {
  local to="$1" type="$2" body="$3"
  shift 3

  local subject="" priority="normal" tags="[]"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --subject) subject="$2"; shift 2 ;;
      --priority) priority="$2"; shift 2 ;;
      --tags) tags="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      *) shift ;;
    esac
  done

  local msg_id
  msg_id="$(_msg_id)"
  local thread_id="$msg_id"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg mid "$msg_id" \
    --arg from "$BRIDGE_AGENT_ID" \
    --arg to "$to" \
    --arg type "$type" \
    --arg priority "$priority" \
    --arg subject "$subject" \
    --arg body "$body" \
    --arg thread "$thread_id" \
    --argjson tags "$tags" \
    --arg created "$now" \
    --arg machine "$BRIDGE_MACHINE" \
    '{
      message_id: $mid,
      from_agent: $from,
      to_agent: $to,
      type: $type,
      status: "unread",
      priority: $priority,
      subject: $subject,
      subject_semantic: $subject,
      body: $body,
      body_semantic: $body,
      thread_id: $thread,
      tags: $tags,
      created_at: $created,
      machine: $machine
    }')"

  if es_online; then
    local result
    result="$(es_index "$IDX_MESSAGES" "$msg_id" "$doc")"
    if echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      echo "Sent $type to $to [${msg_id}]"
    else
      echo "ES error — queuing to fallback" >&2
      fallback_queue "$IDX_MESSAGES" "$msg_id" "$doc"
    fi
  else
    fallback_queue "$IDX_MESSAGES" "$msg_id" "$doc"
    echo "Offline — queued $type to $to [${msg_id}]"
  fi
}

# Check inbox
# Usage: msg_check [--unread] [--type X] [--limit 10]
msg_check() {
  local unread_only=false type_filter="" limit=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --unread) unread_only=true; shift ;;
      --type) type_filter="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local must_clauses
  must_clauses="[{\"term\": {\"to_agent\": \"$BRIDGE_AGENT_ID\"}}"
  if $unread_only; then
    must_clauses+=",{\"term\": {\"status\": \"unread\"}}"
  fi
  if [[ -n "$type_filter" ]]; then
    must_clauses+=",{\"term\": {\"type\": \"$type_filter\"}}"
  fi
  must_clauses+="]"

  local query
  query="{\"query\": {\"bool\": {\"must\": $must_clauses}}, \"sort\": [{\"created_at\": \"desc\"}], \"size\": $limit}"

  if ! es_online; then
    echo "Offline — showing fallback inbox"
    fallback_check_inbox
    return
  fi

  local result
  result="$(es_search "$IDX_MESSAGES" "$query")"
  local count
  count="$(echo "$result" | jq '.hits.total.value // 0')"

  if [[ "$count" == "0" ]]; then
    echo "No messages."
    return
  fi

  echo "$result" | jq -r '.hits.hits[]._source | "\(if (.created_at | type) == "string" then (.created_at | split("T")[0]) else "unknown-date" end) [\(.type)] from \(.from_agent): \(.subject // .body[:80]) [\(.message_id)] \(if .status == "unread" then "●" else "" end)"'
}

# Reply to a message
# Usage: msg_reply <message_id> <body>
msg_reply() {
  local orig_id="$1" body="$2"

  # Get original message to find thread and sender
  local orig
  orig="$(es_request GET "/${IDX_MESSAGES}/_doc/${orig_id}" | jq '._source')"
  local to thread_id
  to="$(echo "$orig" | jq -r '.from_agent')"
  thread_id="$(echo "$orig" | jq -r '.thread_id')"

  local msg_id
  msg_id="$(_msg_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg mid "$msg_id" \
    --arg from "$BRIDGE_AGENT_ID" \
    --arg to "$to" \
    --arg body "$body" \
    --arg reply_to "$orig_id" \
    --arg thread "$thread_id" \
    --arg created "$now" \
    --arg machine "$BRIDGE_MACHINE" \
    '{
      message_id: $mid,
      from_agent: $from,
      to_agent: $to,
      type: "response",
      status: "unread",
      priority: "normal",
      body: $body,
      body_semantic: $body,
      in_reply_to: $reply_to,
      thread_id: $thread,
      created_at: $created,
      machine: $machine
    }')"

  if es_online; then
    es_index "$IDX_MESSAGES" "$msg_id" "$doc" > /dev/null
    echo "Replied to $to [${msg_id}]"
  else
    fallback_queue "$IDX_MESSAGES" "$msg_id" "$doc"
    echo "Offline — reply queued [${msg_id}]"
  fi
}

# Acknowledge (mark as read)
# Usage: msg_ack <message_id>
msg_ack() {
  local msg_id="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local result
  result="$(es_update "$IDX_MESSAGES" "$msg_id" "{\"status\": \"read\", \"read_at\": \"$now\"}")"
  if echo "$result" | jq -e '.result == "updated"' > /dev/null 2>&1; then
    echo "Acknowledged [$msg_id]"
  else
    echo "Failed to ack [$msg_id]" >&2
  fi
}
