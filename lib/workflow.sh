#!/opt/homebrew/bin/bash
# workflow.sh — Elastic Workflows API wrapper
#
# Manages KK automation workflows running serverlessly on Kibana.
# Workflows run on Kibana even when the laptop is off.
#
# All requests use KIBANA_URL + BRIDGE_ES_API_KEY from .env.
# Required headers: kbn-xsrf: true, x-elastic-internal-origin: Kibana

# ── Helpers ──────────────────────────────────────────────────────────────────

_wf_curl() {
  local method="$1" path="$2"
  shift 2
  if [[ -z "${KIBANA_URL:-}" ]]; then
    echo "ERROR: KIBANA_URL not set — add to $BRIDGE_DIR/.env" >&2
    return 1
  fi
  curl -s -X "$method" "${KIBANA_URL}${path}" \
    -H "Authorization: ApiKey ${BRIDGE_ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "x-elastic-internal-origin: Kibana" \
    -H "Content-Type: application/json" \
    "$@"
}

# Find workflow ID by exact name (returns empty string if not found)
_wf_id_by_name() {
  local name="$1"
  _wf_curl GET "/api/workflows" 2>/dev/null \
    | jq -r --arg name "$name" '.results[] | select(.name == $name) | .id' \
    | head -1
}

# Resolve arg: if starts with "workflow-" treat as ID, else look up by name
_wf_resolve() {
  local arg="$1"
  if [[ "$arg" == workflow-* ]]; then
    echo "$arg"
  else
    local id
    id="$(_wf_id_by_name "$arg")"
    if [[ -z "$id" ]]; then
      echo "ERROR: no workflow found with name '$arg'" >&2
      return 1
    fi
    echo "$id"
  fi
}

# ── Commands ─────────────────────────────────────────────────────────────────

workflow_list() {
  local result
  result="$(_wf_curl GET "/api/workflows")"
  local count
  count="$(echo "$result" | jq '.total // (.results | length)')"
  echo "Workflows ($count):"
  echo "$result" | jq -r '.results[] | "  \(.id)  \(.name)  [\(if .enabled then "enabled" else "disabled" end)]  valid:\(.valid)  updated: \(.lastUpdatedAt[:10])"'
}

workflow_deploy() {
  local yaml_file="${1:-}"
  if [[ -z "$yaml_file" || ! -f "$yaml_file" ]]; then
    echo "Usage: bridge workflow deploy <yaml_file>" >&2
    return 1
  fi

  local yaml_content
  yaml_content="$(cat "$yaml_file")"
  local name
  name="$(grep '^name:' "$yaml_file" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d "'\"")"

  # Check if workflow already exists; update if so
  local existing_id
  existing_id="$(_wf_id_by_name "$name" 2>/dev/null)"

  local payload
  payload="$(jq -n --arg yaml "$yaml_content" '{"workflows": [{"yaml": $yaml}]}')"

  local result
  if [[ -n "$existing_id" ]]; then
    # Update: POST with id in payload (PUT /api/workflows/{id} returns 404)
    local update_payload
    update_payload="$(jq -n --arg id "$existing_id" --arg yaml "$yaml_content" '{"workflows": [{"id": $id, "yaml": $yaml}]}')"
    result="$(_wf_curl POST "/api/workflows" -d "$update_payload")"
    local updated_id
    updated_id="$(echo "$result" | jq -r '.created[0].id // empty')"
    if [[ -z "$updated_id" ]]; then
      echo "ERROR updating $yaml_file:" >&2
      echo "$result" | jq . >&2
      return 1
    fi
    echo "Updated: $existing_id ($name)"
  else
    result="$(_wf_curl POST "/api/workflows" -d "$payload")"
    local new_id
    new_id="$(echo "$result" | jq -r '.created[0].id // empty')"
    if [[ -z "$new_id" ]]; then
      echo "ERROR deploying $yaml_file:" >&2
      echo "$result" | jq . >&2
      return 1
    fi
    echo "Deployed: $new_id ($name)"
  fi
}

workflow_deploy_all() {
  local workflows_dir="$BRIDGE_DIR/workflows"
  if [[ ! -d "$workflows_dir" ]]; then
    echo "No workflows directory at $workflows_dir" >&2
    return 1
  fi
  local count=0
  for f in "$workflows_dir"/*.yaml "$workflows_dir"/*.yml; do
    [[ -f "$f" ]] || continue
    workflow_deploy "$f"
    (( count++ )) || true
  done
  echo "Done. $count workflow(s) deployed."
}

workflow_run() {
  local name_or_id="${1:-}"
  if [[ -z "$name_or_id" ]]; then
    echo "Usage: bridge workflow run <name_or_id> [--input key=val ...]" >&2
    return 1
  fi
  shift

  local wf_id
  wf_id="$(_wf_resolve "$name_or_id")" || return 1

  # Build input JSON from --input key=val pairs
  # Always inject triggered_at so workflows can use it for timestamps
  local input_json
  input_json="{\"triggered_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --input)
        local kv="$2"; shift 2
        local k="${kv%%=*}"
        local v="${kv#*=}"
        input_json="$(echo "$input_json" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')"
        ;;
      --input-json)
        # Pass raw JSON object to merge into inputs
        input_json="$(echo "$input_json" | jq --argjson extra "$2" '. + $extra')"
        shift 2
        ;;
      *) shift ;;
    esac
  done

  local payload
  payload="$(jq -n --argjson input "$input_json" '{"input": $input}')"

  local result
  result="$(_wf_curl POST "/api/workflows/${wf_id}/run" -d "$payload")"
  local exec_id
  exec_id="$(echo "$result" | jq -r '.id // empty')"
  if [[ -z "$exec_id" ]]; then
    echo "ERROR triggering workflow:" >&2
    echo "$result" | jq . >&2
    return 1
  fi
  echo "Execution started: $exec_id"
  echo "Check status: bridge workflow status $exec_id"
}

workflow_status() {
  local exec_id="${1:-}"
  if [[ -z "$exec_id" ]]; then
    echo "Usage: bridge workflow status <execution_id>" >&2
    return 1
  fi
  local result
  result="$(_wf_curl GET "/api/workflowExecutions/${exec_id}")"
  local status
  status="$(echo "$result" | jq -r '.status // "unknown"')"
  echo "Status: $status"
  echo "$result" | jq '{
    id,
    workflow_id,
    status,
    started_at,
    completed_at,
    duration_ms,
    steps: (.steps // {} | to_entries | map({step: .key, status: .value.status}) )
  }'
}

workflow_delete() {
  local name_or_id="${1:-}"
  if [[ -z "$name_or_id" ]]; then
    echo "Usage: bridge workflow delete <name_or_id>" >&2
    return 1
  fi
  local wf_id
  wf_id="$(_wf_resolve "$name_or_id")" || return 1
  local result status_code
  result="$(_wf_curl DELETE "/api/workflows/${wf_id}")"
  status_code="$(echo "$result" | jq -r '.statusCode // 200')"
  if [[ "$status_code" != "200" && "$status_code" != "204" ]]; then
    echo "ERROR deleting $wf_id (HTTP $status_code):" >&2
    echo "$result" | jq -r '.message // .' >&2
    return 1
  fi
  echo "Deleted: $wf_id"
}

# Update enabled: line in a local YAML file matching the given workflow name (best-effort)
_wf_sync_local_enabled() {
  local name="$1" state="$2"   # state = "true" or "false"
  local f
  for f in "$BRIDGE_DIR/workflows"/*.yaml "$BRIDGE_DIR/workflows"/*.yml; do
    [[ -f "$f" ]] || continue
    local file_name
    file_name="$(grep '^name:' "$f" | head -1 | sed 's/^name:[[:space:]]*//' | tr -d "'\"")"
    if [[ "$file_name" == "$name" ]]; then
      sed -i '' "s/^enabled: .*/enabled: $state/" "$f"
      echo "  Synced local: $f"
      return 0
    fi
  done
  echo "  Note: no local YAML found for '$name' — cluster updated only"
}

# Fetch a single workflow's details from the list endpoint (single GET by ID not supported)
_wf_get() {
  local wf_id="$1"
  _wf_curl GET "/api/workflows" 2>/dev/null \
    | jq -r --arg id "$wf_id" '.results[] | select(.id == $id)'
}

workflow_enable() {
  local name_or_id="${1:-}"
  if [[ -z "$name_or_id" ]]; then
    echo "Usage: bridge workflow enable <name_or_id>" >&2
    return 1
  fi
  local wf_id
  wf_id="$(_wf_resolve "$name_or_id")" || return 1
  local current yaml name new_yaml payload result updated_id
  current="$(_wf_get "$wf_id")"
  if [[ -z "$current" ]]; then
    echo "ERROR: workflow $wf_id not found in list" >&2
    return 1
  fi
  yaml="$(echo "$current" | jq -r '.yaml')"
  name="$(echo "$current" | jq -r '.name')"
  new_yaml="$(echo "$yaml" | sed 's/^enabled: false/enabled: true/')"
  payload="$(jq -n --arg id "$wf_id" --arg y "$new_yaml" '{"workflows": [{"id": $id, "yaml": $y}]}')"
  result="$(_wf_curl POST "/api/workflows" -d "$payload")"
  updated_id="$(echo "$result" | jq -r '.created[0].id // empty')"
  if [[ -z "$updated_id" ]]; then
    echo "ERROR enabling workflow:" >&2
    echo "$result" | jq . >&2
    return 1
  fi
  echo "Enabled: $wf_id ($name)"
  _wf_sync_local_enabled "$name" "true"
}

workflow_disable() {
  local name_or_id="${1:-}"
  if [[ -z "$name_or_id" ]]; then
    echo "Usage: bridge workflow disable <name_or_id>" >&2
    return 1
  fi
  local wf_id
  wf_id="$(_wf_resolve "$name_or_id")" || return 1
  local current yaml name new_yaml payload result updated_id
  current="$(_wf_get "$wf_id")"
  if [[ -z "$current" ]]; then
    echo "ERROR: workflow $wf_id not found in list" >&2
    return 1
  fi
  yaml="$(echo "$current" | jq -r '.yaml')"
  name="$(echo "$current" | jq -r '.name')"
  new_yaml="$(echo "$yaml" | sed 's/^enabled: true/enabled: false/')"
  payload="$(jq -n --arg id "$wf_id" --arg y "$new_yaml" '{"workflows": [{"id": $id, "yaml": $y}]}')"
  result="$(_wf_curl POST "/api/workflows" -d "$payload")"
  updated_id="$(echo "$result" | jq -r '.created[0].id // empty')"
  if [[ -z "$updated_id" ]]; then
    echo "ERROR disabling workflow:" >&2
    echo "$result" | jq . >&2
    return 1
  fi
  echo "Disabled: $wf_id ($name)"
  _wf_sync_local_enabled "$name" "false"
}

workflow_dispatch() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    list)       workflow_list "$@" ;;
    deploy)     workflow_deploy "$@" ;;
    deploy-all) workflow_deploy_all "$@" ;;
    run)        workflow_run "$@" ;;
    status)     workflow_status "$@" ;;
    delete)     workflow_delete "$@" ;;
    enable)     workflow_enable "$@" ;;
    disable)    workflow_disable "$@" ;;
    help|-h|--help)
      cat <<'EOF'
bridge workflow — Elastic Workflows management

  bridge workflow list
    List all deployed workflows

  bridge workflow deploy <yaml_file>
    Deploy (create or update) a workflow from a YAML file

  bridge workflow deploy-all
    Deploy all YAML files in agent-bridge/workflows/

  bridge workflow run <name_or_id> [--input key=val ...]
    Trigger a workflow run. Always injects triggered_at timestamp.

  bridge workflow status <execution_id>
    Get execution status and step results

  bridge workflow enable <name_or_id>
    Enable a workflow (also syncs local YAML file if found)

  bridge workflow disable <name_or_id>
    Disable a workflow (also syncs local YAML file if found)

  bridge workflow delete <name_or_id>
    Delete a workflow by name or ID

Workflow templates are in agent-memory/setup/workflows/.
  Deploy with: bridge workflow deploy <name>
EOF
      ;;
    *) echo "Unknown workflow subcommand: $subcmd" >&2; workflow_dispatch help >&2; return 1 ;;
  esac
}
