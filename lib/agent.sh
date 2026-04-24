#!/usr/bin/env bash
# agent.sh — Agent Builder Converse API wrapper
#
# connector_id is NOT stored per-agent in Agent Builder API — pass it per call.
# Usage: bridge agent converse <agent_id> <input> [--connector CONNECTOR_ID] [--session SESSION_ID]

agent_converse() {
  local agent_id="${1:-}"
  local input="${2:-}"

  if [[ -z "$agent_id" || -z "$input" ]]; then
    echo "Usage: bridge agent converse <agent_id> <input> [--connector CONNECTOR_ID] [--session SESSION_ID]" >&2
    return 1
  fi
  shift 2

  local connector_id="" session_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --connector) connector_id="$2"; shift 2 ;;
      --session)   session_id="$2";   shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "${KIBANA_URL:-}" ]]; then
    echo "ERROR: KIBANA_URL not set — add to $BRIDGE_DIR/.env" >&2
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg agent_id "$agent_id" \
    --arg input "$input" \
    --arg connector_id "$connector_id" \
    --arg session_id "$session_id" \
    '{agent_id: $agent_id, input: $input}
     | if $connector_id != "" then . + {connector_id: $connector_id} else . end
     | if $session_id != "" then . + {session_id: $session_id} else . end')

  curl -s -X POST "${KIBANA_URL}/api/agent_builder/converse" \
    -H "Authorization: ApiKey ${BRIDGE_ES_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

agent_dispatch() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    converse) agent_converse "$@" ;;
    help|-h|--help)
      cat <<'EOF'
bridge agent converse <agent_id> <input> [--connector CONNECTOR_ID] [--session SESSION_ID]

  Call an Agent Builder agent via the Converse API.
  connector_id is passed per call (not stored on agent — API limitation).

  Pass any Agent Builder agent_id and connector_id. See your Kibana Agent Builder for available agents.

  Example:
    bridge agent converse my-synthesis-agent \
      "Summarize what changed in the last 8 hours" \
      --connector Google-Gemini-2-5-Flash
EOF
      ;;
    *) echo "Unknown agent subcommand: $subcmd" >&2; agent_dispatch help >&2; return 1 ;;
  esac
}
