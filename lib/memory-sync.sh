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

# Memory wall: true if a project dir belongs to a space this agent must never sync.
# Reads $BRIDGE_DIR/config/memory-scope.json when present (no file = no exclusions):
#   {"exclude": {"path_prefixes": ["~/repos/personal-projects/"], "git_remotes": ["jeffvestal/nat"]}}
# A git remote matches on the exact owner/repo (".git" suffix ignored).
_memory_scope_excluded() {
  local dir="$1" scope_file="$BRIDGE_DIR/config/memory-scope.json"
  [[ -f "$scope_file" ]] || return 1
  local top remote prefix pat
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")"
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    prefix="${prefix/#\~/$HOME}"
    [[ "$top/" == "${prefix%/}/"* ]] && return 0
  done < <(jq -r '.exclude.path_prefixes[]?' "$scope_file" 2>/dev/null)
  remote="$(git -C "$top" remote get-url origin 2>/dev/null || true)"
  remote="${remote%.git}"
  [[ -z "$remote" ]] && return 1
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    [[ "$remote" == *"/$pat" || "$remote" == *":$pat" ]] && return 0
  done < <(jq -r '.exclude.git_remotes[]?' "$scope_file" 2>/dev/null)
  return 1
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

  if _memory_scope_excluded "$(pwd)"; then
    $quiet || echo "Skipping memory sync — $(pwd) is outside this agent's memory scope (config/memory-scope.json)"
    return
  fi

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
      # type may be top-level or nested under metadata: (current Claude memory format)
      type="$(echo "$content" | sed -n 's/^ *type: *//p' | head -1 || true)"
      description="$(echo "$content" | sed -n 's/^description: *//p' | head -1 | sed 's/^"//; s/"$//' || true)"
      # strip only the frontmatter block; keep any later --- in the body
      content="$(echo "$content" | awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {fm=0; next} !fm')"
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
