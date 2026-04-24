#!/usr/bin/env bash
# install.sh — Single-command setup for agent-memory
#
# Usage: ./install.sh
#   Checks for .env, prompts interactively if missing, then:
#   1. Validates Elasticsearch connectivity
#   2. Creates Jina v5 inference endpoint (for semantic_text fields)
#   3. Creates all indices with correct mappings
#   4. Creates scoped API key
#   5. Installs Claude Code hooks
#   6. Imports Kibana dashboards (optional — requires KIBANA_URL)
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
step() { echo -e "\n${BLUE}──${NC} $*"; }

# ── Load or create .env ──────────────────────────────────────────────────────
step "Configuration"

if [[ -f "$ENV_FILE" ]]; then
  echo "Found .env — loading"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  echo "No .env found — enter your Elasticsearch Serverless details."
  echo "(Get these from cloud.elastic.co → your deployment → Manage)"
  echo ""

  read -rp "Elasticsearch URL (https://...elastic.cloud): " BRIDGE_ES_URL
  read -rp "Elasticsearch API key: " BRIDGE_ES_API_KEY
  read -rp "Agent ID (short name for this agent, e.g. 'myagent'): " BRIDGE_AGENT_ID
  read -rp "Kibana URL (optional, press Enter to skip): " KIBANA_URL
  read -rp "Watch directories for entity indexing (space-separated, default: $PWD): " BRIDGE_WATCH_DIRS
  BRIDGE_WATCH_DIRS="${BRIDGE_WATCH_DIRS:-$PWD}"

  echo ""
  echo "Writing .env..."
  cat > "$ENV_FILE" <<EOF
BRIDGE_ES_URL=${BRIDGE_ES_URL}
BRIDGE_ES_API_KEY=${BRIDGE_ES_API_KEY}
BRIDGE_AGENT_ID=${BRIDGE_AGENT_ID}
KIBANA_URL=${KIBANA_URL:-}
BRIDGE_WATCH_DIRS=${BRIDGE_WATCH_DIRS}
EOF
  ok ".env created"
fi

# Ensure required vars are set
: "${BRIDGE_ES_URL:?BRIDGE_ES_URL not set}"
: "${BRIDGE_ES_API_KEY:?BRIDGE_ES_API_KEY not set}"
: "${BRIDGE_AGENT_ID:?BRIDGE_AGENT_ID not set}"

AUTH_HEADER="Authorization: ApiKey ${BRIDGE_ES_API_KEY}"

_es() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -X "$method" "${BRIDGE_ES_URL}${path}"
              -H "$AUTH_HEADER" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

# ── Step 1: Validate connectivity ────────────────────────────────────────────
step "Validating Elasticsearch connectivity"
result="$(_es GET "/")"
if echo "$result" | jq -e '.tagline' > /dev/null 2>&1; then
  cluster_name="$(echo "$result" | jq -r '.cluster_name // "unknown"')"
  ok "Connected to cluster: $cluster_name"
else
  err "Cannot connect to $BRIDGE_ES_URL"
  echo "$result" | head -5
  exit 1
fi

# ── Step 2: Create Jina v5 inference endpoint ────────────────────────────────
step "Creating Jina v5 inference endpoint"
INFERENCE_ID="jina-v5-embeddings"
result="$(_es PUT "/_inference/text_embedding/${INFERENCE_ID}" '{
  "service": "jinaai",
  "service_settings": {
    "model_id": "jina-embeddings-v3",
    "similarity": "dot_product",
    "dimensions": 1024
  }
}')"
if echo "$result" | jq -e '.inference_id' > /dev/null 2>&1; then
  ok "Inference endpoint created: $INFERENCE_ID"
elif echo "$result" | jq -e '.error.type == "resource_already_exists_exception"' > /dev/null 2>&1; then
  ok "Inference endpoint already exists: $INFERENCE_ID"
else
  warn "Could not create inference endpoint — semantic search will be unavailable"
  echo "$result" | jq -r '.error.reason // .' 2>/dev/null || echo "$result"
  INFERENCE_ID=""
fi

# Build semantic_text mapping block
if [[ -n "$INFERENCE_ID" ]]; then
  SEMANTIC_TEXT_BODY_JSON="{\"type\": \"semantic_text\", \"inference_id\": \"${INFERENCE_ID}\"}"
  SEMANTIC_TEXT_TITLE_JSON="{\"type\": \"semantic_text\", \"inference_id\": \"${INFERENCE_ID}\"}"
else
  SEMANTIC_TEXT_BODY_JSON='{"type": "text"}'
  SEMANTIC_TEXT_TITLE_JSON='{"type": "text"}'
fi

# ── Step 3: Create indices ────────────────────────────────────────────────────
step "Creating indices"

_create_index() {
  local name="$1" mapping="$2"
  echo -n "  $name: "
  result="$(_es PUT "/${name}" "$mapping")"
  if echo "$result" | jq -e '.acknowledged == true' > /dev/null 2>&1; then
    ok "created"
  elif echo "$result" | jq -e '.error.type == "resource_already_exists_exception"' > /dev/null 2>&1; then
    echo "already exists"
  else
    err "$(echo "$result" | jq -r '.error.reason // .' 2>/dev/null || echo "$result")"
  fi
}

ENTITY_INDEX="${BRIDGE_AGENT_ID}-entities"
ENTITY_HISTORY_INDEX="${BRIDGE_AGENT_ID}-entity-history"

_create_index "agent-messages" '{
  "mappings": {"properties": {
    "message_id":       {"type": "keyword"},
    "from_agent":       {"type": "keyword"},
    "to_agent":         {"type": "keyword"},
    "type":             {"type": "keyword"},
    "status":           {"type": "keyword"},
    "priority":         {"type": "keyword"},
    "subject":          {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
    "body":             {"type": "text"},
    "tags":             {"type": "keyword"},
    "created_at":       {"type": "date"},
    "read_at":          {"type": "date"},
    "machine":          {"type": "keyword"}
  }}}'

_create_index "agent-memory" "$(jq -n \
  --argjson sem_title "$SEMANTIC_TEXT_TITLE_JSON" \
  --argjson sem_body "$SEMANTIC_TEXT_BODY_JSON" \
  '{"mappings": {"properties": {
    "memory_id":        {"type": "keyword"},
    "agent":            {"type": "keyword"},
    "type":             {"type": "keyword"},
    "category":         {"type": "keyword"},
    "title":            {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
    "title_semantic":   $sem_title,
    "content":          {"type": "text"},
    "content_semantic": $sem_body,
    "tags":             {"type": "keyword"},
    "source":           {"type": "keyword"},
    "created_at":       {"type": "date"},
    "updated_at":       {"type": "date"},
    "access_scope":     {"type": "keyword"}
  }}}')"

_create_index "agent-sessions" '{
  "mappings": {"properties": {
    "session_id":   {"type": "keyword"},
    "agent":        {"type": "keyword"},
    "machine":      {"type": "keyword"},
    "action":       {"type": "keyword"},
    "summary":      {"type": "text"},
    "tags":         {"type": "keyword"},
    "task_id":      {"type": "keyword"},
    "timestamp":    {"type": "date"}
  }}}'

_create_index "agent-tasks" '{
  "mappings": {"properties": {
    "task_id":      {"type": "keyword"},
    "agent":        {"type": "keyword"},
    "title":        {"type": "text"},
    "status":       {"type": "keyword"},
    "created_at":   {"type": "date"},
    "updated_at":   {"type": "date"}
  }}}'

_create_index "agent-status" '{
  "mappings": {"properties": {
    "agent":          {"type": "keyword"},
    "machine":        {"type": "keyword"},
    "last_heartbeat": {"type": "date"},
    "status":         {"type": "keyword"}
  }}}'

_create_index "$ENTITY_INDEX" "$(jq -n \
  --argjson sem_title "$SEMANTIC_TEXT_TITLE_JSON" \
  --argjson sem_body "$SEMANTIC_TEXT_BODY_JSON" \
  '{"mappings": {"properties": {
    "entity_id":        {"type": "keyword"},
    "agent":            {"type": "keyword"},
    "entity_type":      {"type": "keyword"},
    "title":            {"type": "text", "fields": {"keyword": {"type": "keyword"}}},
    "title_semantic":   $sem_title,
    "content":          {"type": "text"},
    "content_semantic": $sem_body,
    "status":           {"type": "keyword"},
    "priority":         {"type": "keyword"},
    "initiative":       {"type": "keyword"},
    "tags":             {"type": "keyword"},
    "source_path":      {"type": "keyword"},
    "summary":          {"type": "text"},
    "created_at":       {"type": "date"},
    "updated_at":       {"type": "date"}
  }}}')"

_create_index "$ENTITY_HISTORY_INDEX" '{
  "mappings": {"properties": {
    "event_id":      {"type": "keyword"},
    "entity_id":     {"type": "keyword"},
    "entity_type":   {"type": "keyword"},
    "title":         {"type": "keyword"},
    "status":        {"type": "keyword"},
    "snapshot_at":   {"type": "date"}
  }}}'

# ── Step 4: Update .env with entity index names ──────────────────────────────
if ! grep -q "BRIDGE_ENTITY_INDEX" "$ENV_FILE" 2>/dev/null; then
  {
    echo "BRIDGE_ENTITY_INDEX=${ENTITY_INDEX}"
    echo "BRIDGE_ENTITY_HISTORY_INDEX=${ENTITY_HISTORY_INDEX}"
  } >> "$ENV_FILE"
fi

# ── Step 5: Install Claude Code hooks ────────────────────────────────────────
step "Installing Claude Code hooks"

HOOKS_TARGET="${CLAUDE_CODE_SETTINGS:-$HOME/.claude/settings.json}"
HOOK_SCRIPT="$INSTALL_DIR/hooks/index-file.sh"
BRIDGE_BIN="$INSTALL_DIR/bridge"

# Make hook executable
chmod +x "$HOOK_SCRIPT"

if [[ ! -f "$HOOKS_TARGET" ]]; then
  warn "No Claude Code settings.json found at $HOOKS_TARGET"
  warn "Copy hooks/settings.json.template and replace REPLACE_WITH_AGENT_MEMORY_PATH with: $INSTALL_DIR"
  warn "Then add to your Claude Code settings."
else
  echo "  Found settings.json — checking for existing hooks..."
  if grep -q "agent-memory\|index-file.sh" "$HOOKS_TARGET" 2>/dev/null; then
    echo "  Hooks already installed"
  else
    warn "Automatic hook injection not supported yet — add manually."
    warn "Copy hooks/settings.json.template and replace REPLACE_WITH_AGENT_MEMORY_PATH with: $INSTALL_DIR"
  fi
fi

# ── Step 6: Kibana dashboards ────────────────────────────────────────────────
step "Kibana dashboards"

if [[ -z "${KIBANA_URL:-}" ]]; then
  warn "KIBANA_URL not set — skipping dashboard import"
  echo "  Set KIBANA_URL in .env and re-run to import dashboards"
else
  DASHBOARD_FILE="$INSTALL_DIR/setup/dashboards/agent-memory.ndjson"
  if [[ -f "$DASHBOARD_FILE" ]]; then
    echo -n "  Importing dashboards: "
    result="$(curl -s -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
      -H "Authorization: ApiKey ${BRIDGE_ES_API_KEY}" \
      -H "kbn-xsrf: true" \
      -F "file=@${DASHBOARD_FILE}" 2>/dev/null || echo '{"success":false}')"
    if echo "$result" | jq -e '.success == true' > /dev/null 2>&1; then
      count="$(echo "$result" | jq -r '.successCount // 0')"
      ok "$count objects imported"
    else
      err "$(echo "$result" | jq -r '.errors[]?.error.message // "import failed"' 2>/dev/null | head -3)"
    fi
  else
    warn "Dashboard file not found: $DASHBOARD_FILE"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  agent-memory installed successfully${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Next steps:"
echo "  1. Add $INSTALL_DIR to your PATH (or alias 'bridge' to $BRIDGE_BIN)"
echo "  2. Install hooks: see hooks/settings.json.template"
echo "  3. Index your files: bridge entity index-all"
echo "  4. Verify: bridge status"
echo ""
echo "Entity index: $ENTITY_INDEX"
echo "Watch dirs:   ${BRIDGE_WATCH_DIRS:-$PWD}"
