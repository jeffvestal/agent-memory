#!/usr/bin/env bash
# fallback.sh — File-based offline mode

# Queue a document for later sync
# Usage: fallback_queue <index> <doc_id> <json_body>
fallback_queue() {
  local index="$1" doc_id="$2" body="$3"
  local agent="$BRIDGE_AGENT_ID"
  local outbox="$BRIDGE_FALLBACK_DIR/$agent/outbox"
  local ts
  ts="$(date +%Y%m%dT%H%M%S)"
  local filename="${ts}-${BRIDGE_MACHINE}-${index}-${doc_id}.json"

  mkdir -p "$outbox"
  jq -n \
    --arg index "$index" \
    --arg id "$doc_id" \
    --argjson doc "$body" \
    '{index: $index, doc_id: $id, doc: $doc}' > "$outbox/$filename"
}

# Check fallback inbox (messages addressed to this agent)
fallback_check_inbox() {
  local inbox="$BRIDGE_FALLBACK_DIR/$BRIDGE_AGENT_ID/inbox"
  if [[ ! -d "$inbox" ]] || [[ -z "$(ls -A "$inbox" 2>/dev/null)" ]]; then
    echo "No offline messages."
    return
  fi

  for f in "$inbox"/*.json; do
    [[ -f "$f" ]] || continue
    jq -r '.doc | "\(.created_at // "unknown") [\(.type // "msg")] from \(.from_agent // "?"): \(.body[:80] // .subject[:80] // "no content")"' "$f"
  done
}

# Search fallback memory (basic grep)
fallback_search_memory() {
  local query="$1"
  local memdir="$BRIDGE_FALLBACK_DIR/memory"
  if [[ ! -d "$memdir" ]] || [[ -z "$(ls -A "$memdir" 2>/dev/null)" ]]; then
    echo "No offline memories."
    return
  fi

  grep -li "$query" "$memdir"/*.json 2>/dev/null | while read -r f; do
    jq -r '.doc | "[\(.type)] \(.title // .content[:80]) [\(.memory_id)]"' "$f"
  done
}

# Sync all queued files to ES
# Usage: fallback_sync
fallback_sync() {
  local total_synced=0 total_failed=0
  local sync_summary=""

  for agent_dir in "$BRIDGE_FALLBACK_DIR"/*/outbox; do
    [[ -d "$agent_dir" ]] || continue

    local synced_dir="$agent_dir/.synced"
    mkdir -p "$synced_dir"

    local files=()
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$agent_dir" -maxdepth 1 -name "*.json" -print0 2>/dev/null | sort -z)

    [[ ${#files[@]} -eq 0 ]] && continue

    # Build bulk request body grouped by index
    local bulk_body="" count=0
    for f in "${files[@]}"; do
      local index doc_id doc
      index="$(jq -r '.index' "$f")"
      doc_id="$(jq -r '.doc_id' "$f")"
      doc="$(jq -c '.doc' "$f")"

      bulk_body+="{\"index\": {\"_index\": \"$index\", \"_id\": \"$doc_id\"}}"$'\n'
      bulk_body+="$doc"$'\n'
      ((count++))
    done

    if [[ $count -eq 0 ]]; then
      continue
    fi

    # Send bulk request
    local result
    result="$(es_bulk "$bulk_body")"
    local has_errors
    has_errors="$(echo "$result" | jq '.errors')"

    if [[ "$has_errors" == "false" ]]; then
      # All succeeded — move all to .synced
      for f in "${files[@]}"; do
        mv "$f" "$synced_dir/"
      done
      total_synced=$((total_synced + count))
    else
      # Partial success — check each item
      local i=0
      for f in "${files[@]}"; do
        local item_error
        item_error="$(echo "$result" | jq ".items[$i].index.error // null")"
        if [[ "$item_error" == "null" ]]; then
          mv "$f" "$synced_dir/"
          ((total_synced++))
        else
          ((total_failed++))
          echo "Failed: $(basename "$f") — $item_error" >&2
        fi
        ((i++))
      done
    fi
  done

  if [[ $total_synced -eq 0 && $total_failed -eq 0 ]]; then
    echo "Nothing to sync."
    return
  fi

  echo "Synced $total_synced documents."
  [[ $total_failed -gt 0 ]] && echo "Failed: $total_failed documents." >&2

  # Git commit the synced files
  if command -v git &>/dev/null && [[ -d "$BRIDGE_FALLBACK_DIR/../.git" ]]; then
    git -C "$BRIDGE_DIR" add fallback/
    git -C "$BRIDGE_DIR" diff --cached --quiet || \
      git -C "$BRIDGE_DIR" commit -m "bridge: sync $total_synced queued documents" --quiet
  fi
}
