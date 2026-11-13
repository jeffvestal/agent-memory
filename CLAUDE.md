# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

`agent-memory` is an Elasticsearch-backed persistent memory and inter-agent communication system for Claude Code agents. The `bridge` CLI provides agents with semantic memory storage, message passing, task tracking, session history, file entity indexing, and Elastic Workflows/Agent Builder integration.

## Configuration

Create a `.env` file (see `.env.example`) with:
- `BRIDGE_ES_URL` — Elasticsearch Serverless endpoint (required)
- `BRIDGE_ES_API_KEY` — Scoped API key (required)
- `BRIDGE_AGENT_ID` — Short agent name, e.g. `myagent` (required)
- `KIBANA_URL` — Required for Workflows and Agent Builder commands
- `BRIDGE_WATCH_DIRS` — Space-separated dirs to index as entities (default: `$PWD`)
- `BRIDGE_MEMORY_PATH` — Path to auto-memory dir (default: `~/.claude/projects/<cwd-slug>/memory`)

## Key Commands

```bash
# Setup and connectivity
./install.sh          # Interactive cluster setup (creates indices, Jina inference endpoint, installs hooks)
./bridge status       # Check ES connectivity and index stats

# Offline sync
./bridge sync         # Flush queued offline writes to ES

# Memory
bridge remember <type> <content> [--title T] [--tags t1,t2] [--scope shared] [--category C] [--immutable] [--no-consolidate] [--dry-run]
bridge recall <query> [--type X] [--limit N] [--semantic|--keyword|--hybrid] [--json] [--all]  # --json: [{memory_id,type,title,access_scope,agent,score,status}]
bridge forget <memory_id> [--superseded-by ID | --purge] [--reason R]
bridge sync-memories [--force]   # Sync ~/.claude/projects/.../memory/*.md to ES

# Messages
bridge send <to> <type> <body> [--subject S] [--priority P]
bridge check [--unread] [--limit N]
bridge reply <message_id> <body>
bridge ack <message_id>

# Tasks
bridge task start <title> [--priority P]
bridge task update <task_id> [--status S] [--note N]
bridge task done <task_id> [--outcome O]
bridge task fail <task_id> [--reason R]
bridge task list [--status S]
bridge task current

# Sessions
bridge log <action> <summary> [--tags t1,t2] [--files f1,f2]
bridge history [--last 7d] [--limit N]

# Entities (markdown file indexing)
bridge entity index-file <path>
bridge entity index-all [--quiet]
bridge entity search <query> [limit]
bridge entity health

# Workflows / Agent Builder
bridge workflow list|deploy|run|status|enable|disable|delete
bridge agent converse <agent_id> <input>
```

## Architecture

All logic lives in `lib/*.sh` modules sourced by the `bridge` CLI. There is no build step — it's pure bash.

```
bridge (CLI entrypoint)
  └── lib/
       ├── config.sh       — loads .env, sets defaults, validates required vars
       ├── es.sh           — curl wrapper: es_request/index/search/update/bulk/get/count
       ├── fallback.sh     — offline queue to fallback/{agent}/outbox/, sync via es_bulk
       ├── memory.sh       — remember/recall/forget → agent-memory index (status lifecycle)
       ├── consolidate.sh  — write-time supersede/merge judge (EIS completion) → memory-consolidation-log
       ├── messages.sh     — send/check/reply/ack → agent-messages index
       ├── tasks.sh        — task lifecycle + heartbeat → agent-tasks / agent-status indices
       ├── sessions.sh     — log/history → agent-sessions index
       ├── memory-sync.sh  — syncs .md files from auto-memory path to ES
       ├── workflow.sh     — Elastic Workflows REST API
       ├── agent.sh        — Agent Builder converse API
       └── setup.sh        — dispatches install subcommands
hooks/
  └── index-file.sh       — PostToolUse hook; calls bridge entity index-file on Write/Edit
setup/
  ├── install.sh          — idempotent cluster setup (indices, mappings, inference)
  └── dashboards/         — Kibana dashboard exports
.sync-state/              — local state: last-heartbeat, current-task, hash files
fallback/                 — offline queue; synced files go to .synced/
```

### Elasticsearch Indices

| Index | Purpose |
|---|---|
| `agent-memory` | Persistent memories (semantic + keyword hybrid) |
| `memory-consolidation-log` | One doc per consolidation judgment: candidates, verdicts, actions, model, latency |
| `agent-messages` | Inter-agent message queue |
| `agent-tasks` | Task lifecycle tracking |
| `agent-sessions` | Session/action history |
| `agent-status` | Agent heartbeats |
| `{agent}-entities` | Indexed markdown file entities |
| `{agent}-entity-history` | Entity change history |

### Key Patterns

**Offline resilience**: Every write goes through `fallback.sh`. When ES is unreachable, docs queue as JSON files in `fallback/{agent}/outbox/`. `bridge sync` or automatic post-write sync uploads them via bulk API and moves successes to `.synced/`.

**Hybrid search**: Memory and entity searches use Reciprocal Rank Fusion (RRF) combining Jina v5 `semantic_text` fields with BM25 on title/content/tags. `--semantic`, `--keyword`, or `--hybrid` flags select the mode.

**Deterministic IDs**: Entity IDs use `{agent}-{type}-{slug}` format; memory-sync IDs use `mem-migrate-{md5hash}`. This ensures re-indexing is idempotent.

**Auto-memory sync**: `bridge sync-memories` reads `~/.claude/projects/<cwd-slug>/memory/*.md`, hashes each file, and only re-indexes changed files. `--force` bypasses the hash check. It refuses to run in a project excluded by `$BRIDGE_DIR/config/memory-scope.json` (`exclude.path_prefixes`, `exclude.git_remotes` as exact `owner/repo`); that's how one agent's hooks stay out of another agent's space. No config file means no exclusions.

**Memory lifecycle**: `status` is `active` (or absent on docs older than the field) → `superseded` (with `superseded_by`) | `merged` (with `merged_into`) | `retired`. Recall returns active only; `--all` adds the history. Nothing but `forget --purge` deletes, and `--purge` follows `superseded_by`/`merged_into` back through every older version so a forgotten fact can't resurface from a stale copy. `memory-sync` writes with `doc_as_upsert` so a file edit never wipes a status.

**Write-time consolidation** (`lib/consolidate.sh`): `remember` of a fact-like type (`BRIDGE_CONSOLIDATE_TYPES`, default `decision lesson reference feedback project user preference fact`; episodic types like `handoff` are skipped) pulls the 5 closest active, non-immutable memories of the same agent (ES|QL FORK/FUSE: BM25 + `content_semantic`), then asks an EIS completion endpoint (`BRIDGE_CONSOLIDATE_INFERENCE_ID`, default `.anthropic-claude-5.5-sonnet-completion` per the KK rule that memory LLM work is never below Sonnet 4.6, ~5 s) to label each `supersedes | absorbs | duplicate | distinct`. The prompt is deliberately conservative: retiring a true memory is worse than keeping a stale one, so "considering X" or a refinement stays `distinct`. A write that would retire more than `BRIDGE_CONSOLIDATE_MAX_ACTIONS` (3) memories applies none. Every judgment, `distinct` included, goes to `memory-consolidation-log` for review. `--dry-run` prints the verdicts and writes nothing; `--immutable` keeps a memory out of it for good; `BRIDGE_CONSOLIDATE=0` turns it off. A memory written in the last ~1 s may not be searchable yet, so back-to-back writes can miss each other.

**Task state machine**: `created → in_progress → completed | failed | suspended`. Each transition logs a session event and updates `.sync-state/current-task`.

**Hook integration**: `hooks/index-file.sh` fires on every Claude Code Write/Edit/MultiEdit and calls `bridge entity index-file` on any `.md` file touched.

## Dependencies

- bash 4.0+, curl, jq, md5/md5sum
- Elasticsearch Serverless (Jina v5 inference endpoint created by `install.sh`)
- Kibana (optional — only for `workflow` and `agent` commands)

## Claude Code Hook Setup

Add to Claude Code `settings.json` after running `install.sh`:
```json
{
  "PostToolUse": [{
    "matcher": "Write|Edit|MultiEdit",
    "hooks": [{"type": "command", "command": "/path/to/agent-memory/hooks/index-file.sh"}]
  }]
}
```

## CLAUDE.md Template

`CLAUDE.md.template` contains boilerplate for adding agent-memory instructions to a project's own CLAUDE.md. Copy and customize it when integrating this system into another repo.
