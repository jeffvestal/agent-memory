#!/usr/bin/env bash
# tasks.sh — task lifecycle tracking and agent heartbeat

# es.sh, fallback.sh, and sessions.sh must be sourced before this file

# Generate a task ID
_task_id() {
  echo "task-$(date +%s)-$(openssl rand -hex 4)"
}

# Log a task status change as a flat doc in agent-sessions
# Usage: _log_task_status_change <task_id> <from_status> <to_status> [note]
_log_task_status_change() {
  local task_id="$1" from_status="$2" to_status="$3" note="${4:-}"
  local sess_id
  sess_id="$(_session_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local summary="status changed from $from_status to $to_status"
  [[ -n "$note" ]] && summary="$summary: $note"

  local doc
  doc="$(jq -n \
    --arg sid "$sess_id" \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg machine "$BRIDGE_MACHINE" \
    --arg action "task-status-change" \
    --arg summary "$summary" \
    --arg task_id "$task_id" \
    --arg ts "$now" \
    '{
      session_id: $sid,
      agent: $agent,
      machine: $machine,
      action: $action,
      summary: $summary,
      summary_semantic: $summary,
      task_id: $task_id,
      files_touched: [],
      tags: ["task-lifecycle"],
      timestamp: $ts
    }')"

  if es_online; then
    local result
    result="$(es_index "$IDX_SESSIONS" "$sess_id" "$doc")"
    if ! echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      fallback_queue "$IDX_SESSIONS" "$sess_id" "$doc"
    fi
  else
    fallback_queue "$IDX_SESSIONS" "$sess_id" "$doc"
  fi
}

# Route task subcommands
task_dispatch() {
  case "${1:-}" in
    start)   shift; task_start "$@" ;;
    update)  shift; task_update "$@" ;;
    done)    shift; task_done "$@" ;;
    fail)    shift; task_fail "$@" ;;
    list)    shift; task_list "$@" ;;
    current) shift; task_current "$@" ;;
    *)       echo "Unknown task command: ${1:-}" >&2; echo "Usage: bridge task {start|update|done|fail|list|current}" >&2; exit 1 ;;
  esac
}

# Start a new task
# Usage: task_start <title> [--description D] [--priority P] [--tags t1,t2] [--parent T]
task_start() {
  local title="$1"
  shift

  local description="" priority="normal" tags="[]" parent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --description) description="$2"; shift 2 ;;
      --priority)    priority="$2"; shift 2 ;;
      --tags)        tags="$(echo "$2" | jq -R 'split(",")' 2>/dev/null || echo "[]")"; shift 2 ;;
      --parent)      parent="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local tid
  tid="$(_task_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local doc
  doc="$(jq -n \
    --arg tid "$tid" \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg machine "$BRIDGE_MACHINE" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg status "created" \
    --arg priority "$priority" \
    --argjson tags "$tags" \
    --arg parent "$parent" \
    --arg ts "$now" \
    '{
      task_id: $tid,
      agent: $agent,
      machine: $machine,
      title: $title,
      title_semantic: $title,
      description: $desc,
      status: $status,
      priority: $priority,
      tags: $tags,
      parent_task_id: $parent,
      created_at: $ts,
      updated_at: $ts
    }')"

  if es_online; then
    local result
    result="$(es_index "$IDX_TASKS" "$tid" "$doc")"
    if echo "$result" | jq -e '.result == "created"' > /dev/null 2>&1; then
      # Write current task to local file
      echo "$tid" > "$BRIDGE_CURRENT_TASK_FILE"
      _log_task_status_change "$tid" "none" "created"
      echo "Task started: ${title:0:60} [$tid]"
    else
      fallback_queue "$IDX_TASKS" "$tid" "$doc"
      echo "$tid" > "$BRIDGE_CURRENT_TASK_FILE"
      echo "ES error — queued task [$tid]"
    fi
  else
    fallback_queue "$IDX_TASKS" "$tid" "$doc"
    echo "$tid" > "$BRIDGE_CURRENT_TASK_FILE"
    echo "Offline — queued task [$tid]"
  fi
}

# Update a task
# Usage: task_update <task_id> [--status S] [--note N]
task_update() {
  local task_id="$1"
  shift

  local new_status="" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) new_status="$2"; shift 2 ;;
      --note)   note="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "Offline — cannot update task (requires current state)"
    return 1
  fi

  # Get current doc to know previous status
  local current
  current="$(es_get "$IDX_TASKS" "$task_id")"
  if ! echo "$current" | jq -e '.found == true' > /dev/null 2>&1; then
    echo "Task not found: $task_id" >&2
    return 1
  fi

  local old_status
  old_status="$(echo "$current" | jq -r '._source.status')"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build partial update
  local update_fields
  update_fields="$(jq -n --arg ts "$now" '{updated_at: $ts}')"

  if [[ -n "$new_status" ]]; then
    update_fields="$(echo "$update_fields" | jq --arg s "$new_status" '. + {status: $s}')"
  fi

  local result
  result="$(es_update "$IDX_TASKS" "$task_id" "$update_fields")"

  if echo "$result" | jq -e '.result == "updated" or .result == "noop"' > /dev/null 2>&1; then
    if [[ -n "$new_status" && "$new_status" != "$old_status" ]]; then
      _log_task_status_change "$task_id" "$old_status" "$new_status" "$note"
    fi
    echo "Updated [$task_id]: ${new_status:+status -> $new_status}${note:+ ($note)}"
  else
    echo "Failed to update [$task_id]" >&2
    return 1
  fi
}

# Complete a task
# Usage: task_done <task_id> [--outcome O]
task_done() {
  local task_id="$1"
  shift

  local outcome=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --outcome) outcome="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "Offline — cannot complete task (requires current state)"
    return 1
  fi

  local current
  current="$(es_get "$IDX_TASKS" "$task_id")"
  if ! echo "$current" | jq -e '.found == true' > /dev/null 2>&1; then
    echo "Task not found: $task_id" >&2
    return 1
  fi

  local old_status
  old_status="$(echo "$current" | jq -r '._source.status')"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local update_fields
  update_fields="$(jq -n --arg ts "$now" --arg outcome "$outcome" '{
    status: "completed",
    updated_at: $ts,
    completed_at: $ts,
    outcome: $outcome
  }')"

  local result
  result="$(es_update "$IDX_TASKS" "$task_id" "$update_fields")"

  if echo "$result" | jq -e '.result == "updated" or .result == "noop"' > /dev/null 2>&1; then
    _log_task_status_change "$task_id" "$old_status" "completed" "$outcome"
    # Clear current task if it matches
    if [[ -f "$BRIDGE_CURRENT_TASK_FILE" ]] && [[ "$(cat "$BRIDGE_CURRENT_TASK_FILE")" == "$task_id" ]]; then
      rm -f "$BRIDGE_CURRENT_TASK_FILE"
    fi
    echo "Completed [$task_id]"
  else
    echo "Failed to complete [$task_id]" >&2
    return 1
  fi
}

# Fail a task
# Usage: task_fail <task_id> [--reason R]
task_fail() {
  local task_id="$1"
  shift

  local reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "Offline — cannot fail task (requires current state)"
    return 1
  fi

  local current
  current="$(es_get "$IDX_TASKS" "$task_id")"
  if ! echo "$current" | jq -e '.found == true' > /dev/null 2>&1; then
    echo "Task not found: $task_id" >&2
    return 1
  fi

  local old_status
  old_status="$(echo "$current" | jq -r '._source.status')"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local update_fields
  update_fields="$(jq -n --arg ts "$now" --arg reason "$reason" '{
    status: "failed",
    updated_at: $ts,
    completed_at: $ts,
    outcome: $reason
  }')"

  local result
  result="$(es_update "$IDX_TASKS" "$task_id" "$update_fields")"

  if echo "$result" | jq -e '.result == "updated" or .result == "noop"' > /dev/null 2>&1; then
    _log_task_status_change "$task_id" "$old_status" "failed" "$reason"
    if [[ -f "$BRIDGE_CURRENT_TASK_FILE" ]] && [[ "$(cat "$BRIDGE_CURRENT_TASK_FILE")" == "$task_id" ]]; then
      rm -f "$BRIDGE_CURRENT_TASK_FILE"
    fi
    echo "Failed [$task_id]"
  else
    echo "Failed to update [$task_id]" >&2
    return 1
  fi
}

# List tasks
# Usage: task_list [--agent X] [--status S] [--limit N]
task_list() {
  local agent_filter="" status_filter="" limit=10
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)  agent_filter="$2"; shift 2 ;;
      --status) status_filter="$2"; shift 2 ;;
      --limit)  limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if ! es_online; then
    echo "Offline — cannot query tasks"
    return 1
  fi

  local must_clauses="[]"
  if [[ -n "$agent_filter" ]]; then
    must_clauses="$(echo "$must_clauses" | jq --arg a "$agent_filter" '. + [{"term": {"agent": $a}}]')"
  fi
  if [[ -n "$status_filter" ]]; then
    must_clauses="$(echo "$must_clauses" | jq --arg s "$status_filter" '. + [{"term": {"status": $s}}]')"
  fi

  local query
  if [[ "$must_clauses" == "[]" ]]; then
    query="{\"query\": {\"match_all\": {}}, \"sort\": [{\"updated_at\": \"desc\"}], \"size\": $limit}"
  else
    query="{\"query\": {\"bool\": {\"must\": $must_clauses}}, \"sort\": [{\"updated_at\": \"desc\"}], \"size\": $limit}"
  fi

  local result
  result="$(es_search "$IDX_TASKS" "$query")"
  local count
  count="$(echo "$result" | jq '.hits.total.value // 0')"

  if [[ "$count" == "0" ]]; then
    echo "No tasks found."
    return
  fi

  echo "$result" | jq -r '.hits.hits[]._source | "\(.updated_at | split("T")[0]) [\(.status)] (\(.priority)) \(.title[:60]) [\(.task_id)]"'
}

# Show current active tasks for this agent
task_current() {
  if ! es_online; then
    # Fall back to local file
    if [[ -f "$BRIDGE_CURRENT_TASK_FILE" ]]; then
      echo "Current task (local): $(cat "$BRIDGE_CURRENT_TASK_FILE")"
    else
      echo "No current task."
    fi
    return
  fi

  local query
  query="{\"query\": {\"bool\": {\"must\": [{\"term\": {\"agent\": \"$BRIDGE_AGENT_ID\"}}, {\"terms\": {\"status\": [\"created\", \"in_progress\"]}}]}}, \"sort\": [{\"updated_at\": \"desc\"}], \"size\": 5}"

  local result
  result="$(es_search "$IDX_TASKS" "$query")"
  local count
  count="$(echo "$result" | jq '.hits.total.value // 0')"

  if [[ "$count" == "0" ]]; then
    echo "No active tasks."
    return
  fi

  echo "$result" | jq -r '.hits.hits[]._source | "\(.updated_at | split("T")[0]) [\(.status)] (\(.priority)) \(.title[:60]) [\(.task_id)]"'
}

# Suspend all active tasks for this agent (used on session stop)
task_suspend_active() {
  if ! es_online; then
    return 0
  fi

  local query
  query="{\"query\": {\"bool\": {\"must\": [{\"term\": {\"agent\": \"$BRIDGE_AGENT_ID\"}}, {\"terms\": {\"status\": [\"created\", \"in_progress\"]}}]}}, \"size\": 10}"

  local result
  result="$(es_search "$IDX_TASKS" "$query")"
  local count
  count="$(echo "$result" | jq '.hits.total.value // 0')"

  if [[ "$count" == "0" ]]; then
    return 0
  fi

  local suspended=0
  echo "$result" | jq -r '.hits.hits[]._source | "\(.task_id) \(.status)"' | while read -r tid old_status; do
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local update_fields
    update_fields="$(jq -n --arg ts "$now" '{status: "suspended", updated_at: $ts}')"
    es_update "$IDX_TASKS" "$tid" "$update_fields" > /dev/null 2>&1
    _log_task_status_change "$tid" "$old_status" "suspended" "session ended"
    echo "Suspended [$tid]"
  done

  # Clear current task file
  rm -f "$BRIDGE_CURRENT_TASK_FILE"
}

# Send agent heartbeat (throttled)
heartbeat_send() {
  local now_epoch
  now_epoch="$(date +%s)"

  # Throttle check
  if [[ -f "$BRIDGE_HEARTBEAT_FILE" ]]; then
    local last
    last="$(cat "$BRIDGE_HEARTBEAT_FILE" 2>/dev/null || echo 0)"
    if (( now_epoch - last < BRIDGE_HEARTBEAT_INTERVAL )); then
      return 0
    fi
  fi

  if ! es_online; then
    # Silently no-op when offline (stale heartbeats are misleading)
    return 0
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Read current task from local file (no ES query needed)
  local current_task_id=""
  if [[ -f "$BRIDGE_CURRENT_TASK_FILE" ]]; then
    current_task_id="$(cat "$BRIDGE_CURRENT_TASK_FILE" 2>/dev/null || echo "")"
  fi

  local doc_id="status-${BRIDGE_AGENT_ID}"
  local doc
  doc="$(jq -n \
    --arg agent "$BRIDGE_AGENT_ID" \
    --arg machine "$BRIDGE_MACHINE" \
    --arg status "active" \
    --arg task "$current_task_id" \
    --arg ts "$now" \
    '{
      agent: $agent,
      machine: $machine,
      status: $status,
      current_task_id: $task,
      last_heartbeat: $ts
    }')"

  es_index "$IDX_STATUS" "$doc_id" "$doc" > /dev/null

  # Update throttle file
  echo "$now_epoch" > "$BRIDGE_HEARTBEAT_FILE"
  echo "Heartbeat sent [$BRIDGE_AGENT_ID @ $BRIDGE_MACHINE]"
}
