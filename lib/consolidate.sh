#!/usr/bin/env bash
# consolidate.sh — write-time memory consolidation (supersede / merge)
#
# When `bridge remember` stores a fact-like memory, the closest active memories from the same
# agent are retrieved (hybrid: BM25 + semantic, fused) and an LLM judge labels each one against
# the new memory. The judge is an Elastic Inference Service completion endpoint, so the whole
# loop runs inside Elasticsearch: no extra credentials, still just curl + jq.
#
#   supersedes  new memory explicitly replaces the old fact  → old: status=superseded, superseded_by=new
#   absorbs     same fact, the new one is fuller              → old: status=merged,     merged_into=new
#   duplicate   same fact, the new one adds nothing           → new: status=merged,     merged_into=old
#   distinct    anything else, and the default when unsure    → no change
#
# Nothing is deleted. Recall hides non-active memories unless --all. Every judgment (including
# "distinct") is logged to $IDX_CONSOLIDATION so the judge's calls can be reviewed.
#
# es.sh and memory.sh must be sourced before this file.

: "${IDX_CONSOLIDATION:=memory-consolidation-log}"
: "${BRIDGE_CONSOLIDATE:=1}"                       # 0 turns write-time consolidation off
: "${BRIDGE_CONSOLIDATE_INFERENCE_ID:=.anthropic-claude-5.5-sonnet-completion}"
# Fact-like types only. Episodic types (handoff, session, summary, observation) are events, not
# facts: two handoffs are never duplicates of each other, so they are never judged.
: "${BRIDGE_CONSOLIDATE_TYPES:=decision lesson reference feedback project user preference fact}"
: "${BRIDGE_CONSOLIDATE_CANDIDATES:=5}"
# A single write that wants to retire more than this many memories is suspicious: apply none.
: "${BRIDGE_CONSOLIDATE_MAX_ACTIONS:=3}"

consolidate_eligible() {
  [[ "$BRIDGE_CONSOLIDATE" != "0" ]] && [[ " $BRIDGE_CONSOLIDATE_TYPES " == *" $1 "* ]]
}

_consolidate_now_ms() { echo $(( ${EPOCHREALTIME/./} / 1000 )); }

# Closest active, mutable, fact-like memories of this agent, as a JSON array.
# Usage: _consolidate_candidates <self_id> <query_text>
_consolidate_candidates() {
  local self_id="$1" text="$2"
  local types_in
  types_in="$(tr ' ' '\n' <<< "$BRIDGE_CONSOLIDATE_TYPES" | grep -E '^[a-z_-]+$' | sed 's/.*/"&"/' | paste -sd, -)"
  local n="${BRIDGE_CONSOLIDATE_CANDIDATES//[^0-9]/}"; n="${n:-5}"
  local where="agent == ?agent AND (status IS NULL OR status == \"active\") AND (immutable IS NULL OR immutable == false) AND type IN (${types_in}) AND memory_id != ?self"
  local q
  q="$(cat <<ESQL
FROM ${IDX_MEMORY} METADATA _id, _score, _index
| FORK (
    WHERE ${where} AND (MATCH(content, ?q) OR MATCH(title, ?q))
    | SORT _score DESC | LIMIT 10
) (
    WHERE ${where} AND MATCH(content_semantic, ?q)
    | SORT _score DESC | LIMIT 10
)
| FUSE
| SORT _score DESC | LIMIT ${n}
| EVAL snippet = SUBSTRING(content, 1, 700), created = DATE_FORMAT("yyyy-MM-dd", created_at)
| KEEP _id, type, title, snippet, source, created
ESQL
)"
  local params result
  params="$(jq -nc --arg a "$BRIDGE_AGENT_ID" --arg s "$self_id" --arg q "${text:0:2000}" '[{agent: $a}, {self: $s}, {q: $q}]')"
  result="$(es_esql "$q" "$params")"
  if ! jq -e '.values' <<< "$result" > /dev/null 2>&1; then
    echo "candidate query failed: $(jq -r '.error.reason // .error.type // "no response"' <<< "$result" 2>/dev/null)" >&2
    return 1
  fi
  jq -c '[.values[] | {id: .[0], type: .[1], title: (.[2] // ""), content: (.[3] // ""), source: (.[4] // ""), created: (.[5] // "")}]' <<< "$result"
}

# Ask the judge. Prints {"verdicts":[{id,label,reason}]} or returns 1.
# Usage: _consolidate_judge <new_json> <candidates_json>
_consolidate_judge() {
  local new_json="$1" candidates="$2"
  local prompt
  prompt="$(jq -rn --argjson new "$new_json" --argjson c "$candidates" '
"You maintain the long-term memory of an AI chief-of-staff agent that works for one person.
A NEW memory is being saved. Compare it with each EXISTING memory and label the relationship,
from the NEW memory'"'"'s point of view:

- \"supersedes\": NEW explicitly replaces or reverses the fact in EXISTING, about the same subject,
  so EXISTING is no longer true (a decision reversed, a value changed, a tool or process replaced,
  a status that ended).
- \"absorbs\": NEW states the same fact as EXISTING and adds detail; EXISTING is a barer copy.
- \"duplicate\": NEW states the same fact as EXISTING and adds nothing to it.
- \"distinct\": anything else: different facts, related topics, partial overlap, a refinement or
  exception that leaves EXISTING true, a tentative plan or \"considering\" statement, or unsure.

Be conservative. Retiring a memory that is still true does more damage than keeping a stale one.
Use \"supersedes\" only when the replacement is explicit. When in doubt, answer \"distinct\".

Reply with only JSON, no prose and no code fence:
{\"verdicts\":[{\"id\":\"<EXISTING id>\",\"label\":\"supersedes|absorbs|duplicate|distinct\",\"reason\":\"<20 words max>\"}]}
Include every EXISTING id exactly once.

NEW (type: \($new.type)):
\(if $new.title != "" then "Title: \($new.title)\n" else "" end)\($new.content[:2000])

EXISTING:
\($c | map("[\(.id)] (type: \(.type), saved \(.created))\n\(if .title != "" then "Title: \(.title)\n" else "" end)\(.content)") | join("\n\n"))"')"

  local result text
  result="$(BRIDGE_TIMEOUT=30 es_request POST "/_inference/completion/${BRIDGE_CONSOLIDATE_INFERENCE_ID}" \
    "$(jq -nc --arg p "$prompt" '{input: $p}')")"
  text="$(jq -r '.completion[0].result // empty' <<< "$result" 2>/dev/null)"
  if [[ -z "$text" ]]; then
    echo "judge call failed: $(jq -r '.error.reason // .error.type // "no response"' <<< "$result" 2>/dev/null)" >&2
    return 1
  fi
  # Tolerate a code fence or prose around the object: keep from the first { to the last }.
  text="${text#*\{}"; text="{${text%\}*}}"
  # Keep only verdicts about ids we actually offered, with a known label.
  jq -ec --argjson c "$candidates" '
    ($c | map(.id)) as $ids
    | {verdicts: [.verdicts[]?
        | select((.id | IN($ids[])) and (.label | IN("supersedes", "absorbs", "duplicate", "distinct")))
        | {id, label, reason: ((.reason // "") | tostring | .[:200])}]}' <<< "$text" 2>/dev/null || {
    echo "judge returned unparseable output: ${text:0:200}" >&2
    return 1
  }
}

# Usage: mem_consolidate <new_id> <type> <title> <content> [--dry-run]
mem_consolidate() {
  local new_id="$1" type="$2" title="$3" content="$4" dry_run=0
  [[ "${5:-}" == "--dry-run" ]] && dry_run=1

  local t0 candidates verdicts err=""
  t0="$(_consolidate_now_ms)"
  candidates="$(_consolidate_candidates "$new_id" "${title:+$title. }$content" 2>&1)" || {
    echo "  ↳ consolidation skipped: $candidates" >&2
    return 0
  }
  if [[ "$(jq 'length' <<< "$candidates")" == "0" ]]; then
    [[ "$dry_run" == "1" ]] && echo "  dry-run: no similar active memories"
    return 0
  fi

  local new_json
  new_json="$(jq -nc --arg t "$type" --arg ti "$title" --arg c "$content" '{type: $t, title: $ti, content: $c}')"
  verdicts="$(_consolidate_judge "$new_json" "$candidates" 2>&1)" || { err="$verdicts"; verdicts='{"verdicts":[]}'; }

  # Plan: a duplicate means the NEW memory is the redundant one; otherwise retire what it replaces.
  local plan
  plan="$(jq -c '
    (.verdicts | map(select(.label == "duplicate")) | first) as $dup
    | if $dup then [{target: "NEW", action: "merged", link: $dup.id, reason: $dup.reason}]
      else [.verdicts[] | select(.label == "supersedes" or .label == "absorbs")
            | {target: .id, action: (if .label == "supersedes" then "superseded" else "merged" end),
               link: "NEW", reason}]
      end' <<< "$verdicts")"
  local n_actions
  n_actions="$(jq 'length' <<< "$plan")"
  if (( n_actions > BRIDGE_CONSOLIDATE_MAX_ACTIONS )); then
    err="judge wanted $n_actions actions (max $BRIDGE_CONSOLIDATE_MAX_ACTIONS); applied none, review the log"
    plan="[]"
  fi

  local latency=$(( $(_consolidate_now_ms) - t0 ))

  if [[ "$dry_run" == "1" ]]; then
    jq -r --argjson c "$candidates" '
      ($c | map({(.id): .}) | add) as $by
      | .verdicts[] | "  dry-run: \(.label | ascii_upcase) [\(.id)] \($by[.id].title // $by[.id].content[:60]) — \(.reason)"' <<< "$verdicts"
    [[ -n "$err" ]] && echo "  dry-run: $err" >&2
    echo "  dry-run: judge ${BRIDGE_CONSOLIDATE_INFERENCE_ID} in ${latency}ms, nothing written"
    return 0
  fi

  # Apply
  local applied="[]" row target action link reason label
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    target="$(jq -r '.target' <<< "$row")"; action="$(jq -r '.action' <<< "$row")"
    link="$(jq -r '.link' <<< "$row")"; reason="$(jq -r '.reason' <<< "$row")"
    [[ "$target" == "NEW" ]] && target="$new_id"
    [[ "$link" == "NEW" ]] && link="$new_id"
    local field="superseded_by"; [[ "$action" == "merged" ]] && field="merged_into"
    if _mem_set_status "$target" "$action" "consolidation: $reason" "$field" "$link"; then
      applied="$(jq -c --arg t "$target" --arg a "$action" '. + [{target: $t, action: $a}]' <<< "$applied")"
      local info
      info="$(jq -r --arg id "$( [[ "$target" == "$new_id" ]] && echo "$link" || echo "$target" )" \
        'map(select(.id == $id)) | first | "\(if .title != "" then .title else .content[:60] end)\(if .source == "auto-memory" then " (file-backed: edit or delete that memory file too)" else "" end)"' <<< "$candidates")"
      if [[ "$target" == "$new_id" ]]; then
        echo "  ↳ duplicate of [$link] $info — this one marked merged ($reason)"
      else
        echo "  ↳ $action [$target] $info ($reason)"
      fi
    else
      err="${err:+$err; }failed to update $target"
    fi
  done < <(jq -c '.[]' <<< "$plan")
  [[ -n "$err" ]] && echo "  ↳ consolidation: $err" >&2

  # Log every judgment, including "distinct", so the judge can be audited.
  local log_doc
  log_doc="$(jq -nc \
    --arg agent "$BRIDGE_AGENT_ID" --arg m "${BRIDGE_MACHINE:-$(hostname -s)}" \
    --arg nid "$new_id" --arg nt "${title:-${content:0:80}}" --arg ty "$type" \
    --argjson c "$candidates" --argjson v "$verdicts" --argjson a "$applied" \
    --arg model "$BRIDGE_CONSOLIDATE_INFERENCE_ID" --argjson ms "$latency" --arg err "$err" '
    {"@timestamp": (now | todate), agent: $agent, machine: $m, new_id: $nid, new_title: $nt, new_type: $ty,
     candidate_ids: ($c | map(.id)), verdicts: $v.verdicts, actions: $a, model: $model,
     latency_ms: $ms, dry_run: false} + (if $err != "" then {error: $err} else {} end)')"
  es_request POST "/${IDX_CONSOLIDATION}/_doc" "$log_doc" > /dev/null 2>&1 || true
  return 0
}
