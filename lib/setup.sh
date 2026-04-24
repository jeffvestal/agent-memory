#!/usr/bin/env bash
# setup.sh — bridge setup subcommand dispatcher

SETUP_DIR="${BRIDGE_DIR}/setup"

setup_dispatch() {
  local subcmd="${1:-help}"
  shift || true
  case "$subcmd" in
    export)  bash "$SETUP_DIR/export-live-state.sh" "$@" ;;
    install) bash "$SETUP_DIR/install.sh" "$@" ;;
    help|-h|--help)
      cat <<'EOF'
bridge setup — KK setup & cluster management

  bridge setup export
    Capture live cluster state (tools, agents, workflows) to setup/definitions/
    Read-only. Run to baseline the repo before bridge setup install.

  bridge setup install
    Full idempotent install: indices → keys → tools → agents → workflows
    Safe to re-run. Each phase skips already-existing objects.
EOF
      ;;
    *) echo "Unknown setup subcommand: $subcmd. Try: bridge setup help" >&2; return 1 ;;
  esac
}
