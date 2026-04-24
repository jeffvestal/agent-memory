#!/usr/bin/env bash
# Claude Code PostToolUse hook — index written/edited markdown files
#
# Reads JSON from stdin (Claude Code hook payload), extracts file_path,
# filters to *.md only, then calls `bridge entity index-file`.
#
# Wire in .claude/settings.json:
#   "PostToolUse": [{
#     "matcher": "Write|Edit|MultiEdit",
#     "hooks": [{"type": "command", "command": "/path/to/agent-memory/hooks/index-file.sh"}]
#   }]

set -euo pipefail

BRIDGE_BIN="${BRIDGE_BIN:-$(cd "$(dirname "$0")/.." && pwd)/bridge}"

# Read hook payload from stdin
payload="$(cat)"

# Extract file path from tool input
file_path="$(echo "$payload" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"

# Only index markdown files
[[ -z "$file_path" ]] && exit 0
[[ "$file_path" != *.md ]] && exit 0
[[ -f "$file_path" ]] || exit 0

exec "$BRIDGE_BIN" entity index-file "$file_path" --quiet 2>/dev/null || true
