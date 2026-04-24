#!/usr/bin/env bash
# config.sh — Load .env, set defaults, validate environment

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env if it exists — only sets vars not already in environment
if [[ -f "$BRIDGE_DIR/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    # Parse KEY=VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local_key="${BASH_REMATCH[1]}"
      local_val="${BASH_REMATCH[2]}"
      # Only set if not already exported in environment
      if [[ -z "${!local_key+x}" ]]; then
        export "$local_key"="$local_val"
      fi
    fi
  done < "$BRIDGE_DIR/.env"
fi

# Required vars
: "${BRIDGE_ES_URL:?BRIDGE_ES_URL not set — add to $BRIDGE_DIR/.env}"
: "${BRIDGE_ES_API_KEY:?BRIDGE_ES_API_KEY not set — add to $BRIDGE_DIR/.env}"
: "${BRIDGE_AGENT_ID:?BRIDGE_AGENT_ID not set — add to $BRIDGE_DIR/.env}"

# Defaults
BRIDGE_MACHINE="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
BRIDGE_TIMEOUT="${BRIDGE_TIMEOUT:-5}"
BRIDGE_FALLBACK_DIR="$BRIDGE_DIR/fallback"

# Index names
IDX_MESSAGES="agent-messages"
IDX_MEMORY="agent-memory"
IDX_SESSIONS="agent-sessions"
IDX_TASKS="agent-tasks"
IDX_STATUS="agent-status"
IDX_ENTITIES="${BRIDGE_ENTITY_INDEX:-${BRIDGE_AGENT_ID}-entities}"
IDX_ENTITY_HISTORY="${BRIDGE_ENTITY_HISTORY_INDEX:-${BRIDGE_AGENT_ID}-entity-history}"

# Heartbeat config
BRIDGE_HEARTBEAT_INTERVAL="${BRIDGE_HEARTBEAT_INTERVAL:-60}"
BRIDGE_HEARTBEAT_FILE="$BRIDGE_DIR/.sync-state/last-heartbeat"
BRIDGE_CURRENT_TASK_FILE="$BRIDGE_DIR/.sync-state/current-task"
mkdir -p "$BRIDGE_DIR/.sync-state"
