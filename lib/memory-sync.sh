#!/usr/bin/env bash
# memory-sync.sh — Sync local auto-memory files to ES
# Idempotent: uses deterministic IDs from filenames, so re-runs just update.
# Tracks file hashes to skip unchanged files for speed.
#
# Configure: BRIDGE_MEMORY_PATH=/path/to/memory/dir in .env
# Default: ~/.claude/projects/<cwd-as-path>/memory

SYNC_STATE_DIR="$BRIDGE_DIR/.sync-state"

# Resolve the memory directory for this agent
_memory_dirs() {
  if [[ -n "${BRIDGE_MEMORY_PATH:-}" ]]; then
    echo "$BRIDGE_MEMORY_PATH"
    return
  fi
  # Derive from current project path (Claude Code convention)
  local cwd_slug
  cwd_slug="$(pwd | tr '/' '-')"
  echo "$HOME/.claude/projects/${cwd_slug}/memory"
}

# Hash a file for change detection
_file_hash() {
  md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Deterministic memory ID from filename
_sync_mem_id() {
  local filename="$1"
  echo "mem-migrate-$(echo "$filename" | md5 -q 2>/dev/null || echo "$filename" | md5sum | cut -d' ' -f1)"
}

# Sync all auto-memory files to ES
# Usage: memory_sync [--force] [--quiet]
memory_sync() {
  local force=false quiet=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true; shift ;;
      --quiet) quiet=true; shift ;;
      *) shift ;;
    esac
  done

  local scope="${BRIDGE_AGENT_ID}-only"
  local synced=0 skipped=0 failed=0

  mkdir -p "$SYNC_STATE_DIR"
  local hash_file="$SYNC_STATE_DIR/${BRIDGE_AGENT_ID}-hashes"
  touch "$hash_file"

  local mem_dir
  mem_dir="$(_memory_dirs)"

  if [[ ! -d "$mem_dir" ]]; then
    $quiet || echo "No memory directory found at $mem_dir — set BRIDGE_MEMORY_PATH in .env"
    return
  fi

  if ! es_online; then
    $quiet || echo "Offline — skipping memory sync"
    return
  fi

  for f in "$mem_dir"/*.md; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "MEMORY.md" ]] && continue

    local filename
    filename="$(basename "$f" .md)"
    local current_hash
    current_hash="$(_file_hash "$f")"

    if ! $force; then
      local stored_hash
      stored_hash="$(grep "^${filename}:" "$hash_file" 2>/dev/null | cut -d: -f2 || true)"
      if [[ "$current_hash" == "$stored_hash" ]]; then
        skipped=$((skipped + 1))
        continue
      fi
    fi

    local content
    content="$(cat "$f")"

    local title="" type="observation" description=""
    if [[ "$content" =~ ^--- ]]; then
      title="$(echo "$content" | sed -n 's/^name: *//p' | head -1 || true)"
      type="$(echo "$content" | sed -n 's/^type: *//p' | head -1 || true)"
      description="$(echo "$content" | sed -n 's/^description: *//p' | head -1 || true)"
      content="$(echo "$content" | sed '1,/^---$/d' | sed '1,/^---$/d')"
    fi

    [[ -z "$title" ]] && title="$filename"
    case "$type" in
      user|feedback|project|reference) ;;
      *) type="observation" ;;
    esac

    local mem_id
    mem_id="$(_sync_mem_id "$filename")"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local doc
    doc="$(jq -n \
      --arg mid "$mem_id" \
      --arg agent "$BRIDGE_AGENT_ID" \
      --arg type "$type" \
      --arg title "$title" \
      --arg content "$content" \
      --arg desc "$description" \
      --arg scope "$scope" \
      --arg source "auto-memory" \
      --arg now "$now" \
      '{
        memory_id: $mid,
        agent: $agent,
        type: $type,
        category: "",
        title: $title,
        title_semantic: $title,
        content: $content,
        content_semantic: $content,
        tags: ["auto-memory"],
        source: $source,
        created_at: $now,
        updated_at: $now,
        access_scope: $scope
      }')"

    local result
    result="$(es_index "$IDX_MEMORY" "$mem_id" "$doc" 2>/dev/null)"
    if echo "$result" | jq -e '.result == "created" or .result == "updated"' > /dev/null 2>&1; then
      synced=$((synced + 1))
      if grep -q "^${filename}:" "$hash_file" 2>/dev/null; then
        sed -i '' "s/^${filename}:.*/${filename}:${current_hash}/" "$hash_file"
      else
        echo "${filename}:${current_hash}" >> "$hash_file"
      fi
    else
      failed=$((failed + 1))
      $quiet || echo "Failed: $filename" >&2
    fi
  done

  if $quiet; then
    [[ $synced -gt 0 ]] && echo "memory-sync: $synced synced" || true
  else
    echo "Memory sync: $synced synced, $skipped unchanged, $failed failed"
  fi
}
