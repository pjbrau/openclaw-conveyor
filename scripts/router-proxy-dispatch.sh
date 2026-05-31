#!/usr/bin/env bash
# router-proxy-dispatch.sh — script-based dispatcher for pjbrau/openclaw-router-proxy.
#
# Simple actions (merge, wait, nothing-to-do, open-pr) execute inline.
# LLM actions (new-slice, fix-review) fire openclaw agent async.
#
# Differences from the generic Python conveyor-dispatch.sh:
#   - Uses conveyor-next-action.sh (router-proxy-specific oracle with state)
#   - Merge goes through router-conveyor.sh (records state)
#   - record-started must be called after every opened PR
#   - Build/test is Go (go build ./... && go test ./...), not make/pip

set -euo pipefail

REPO=pjbrau/openclaw-router-proxy
PROJECT_DIR=/home/petter-brautaset/projects/openclaw-router-proxy
SCRIPTS=/home/petter-brautaset/projects/openclaw-conveyor/scripts
REPO_SLUG=pjbrau-openclaw-router-proxy
LOCK_FILE=/home/petter-brautaset/.openclaw/locks/conveyor-${REPO_SLUG}.lock
LOG_TAG="[router-proxy-dispatch]"
DISCORD_CHANNEL="${CONVEYOR_NOTIFY_CHANNEL:-1495795961069305897}"

# ── Helpers ───────────────────────────────────────────────────────────────────
_notify() {
  openclaw message send --channel discord --target "$DISCORD_CHANNEL" \
    --silent --message "[$REPO_SLUG] $*" 2>/dev/null || true
}

_fire_agent() {
  local model="$1" timeout="$2" prompt="$3"
  openclaw agent \
    --agent conveyor \
    --model "$model" \
    --message "$prompt" \
    --timeout "$timeout" &
  local pid=$!
  date +%s > "$LOCK_FILE"
  disown "$pid"
  echo "$LOG_TAG agent fired (pid=$pid model=$model timeout=${timeout}s)"
}

# ── Guard: timestamp-based lock (survives isolated sessions) ─────────────────
MAX_AGENT_AGE=1800
if [[ -f "$LOCK_FILE" ]]; then
  lock_ts=$(cat "$LOCK_FILE")
  age=$(( $(date +%s) - lock_ts ))
  if [[ $age -lt $MAX_AGENT_AGE ]]; then
    echo "$LOG_TAG agent lock is ${age}s old (max ${MAX_AGENT_AGE}s) — skipping this tick"
    exit 0
  fi
  echo "$LOG_TAG stale lock (${age}s) — clearing"
  rm -f "$LOCK_FILE"
fi

cd "$PROJECT_DIR"

# ── Run oracle ────────────────────────────────────────────────────────────────
action_json="$(bash "$SCRIPTS/conveyor-next-action.sh")"
action="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["action"])' "$action_json")"

echo "$LOG_TAG action=$action"

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$action" in

  wait|nothing-to-do)
    reason="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("reason",""))' "$action_json")"
    echo "$LOG_TAG nothing to do: $reason"
    exit 0
    ;;

  merge)
    pr="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pr"])' "$action_json")"
    echo "$LOG_TAG merging PR #$pr"
    bash "$SCRIPTS/router-conveyor.sh" merge "$pr"
    _notify "merged PR #$pr"
    ;;

  merge-validated)
    pr="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["pr"])' "$action_json")"
    echo "$LOG_TAG merging PR #$pr (local-validated — CI infra failure bypassed with --admin)"
    bash "$SCRIPTS/router-conveyor.sh" merge "$pr" --admin
    _notify "merged PR #$pr (local-validated, CI infra bypassed)"
    ;;

  open-pr)
    branch="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["branch"])' "$action_json")"
    title="$(python3  -c 'import json,sys; print(json.loads(sys.argv[1])["title"])'  "$action_json")"
    echo "$LOG_TAG opening PR for orphan branch $branch"
    git fetch origin "$branch"
    git checkout -B "$branch" "origin/$branch"
    pr_url="$(bash "$SCRIPTS/open-pr-with-review.sh" "$title" "")"
    pr_num="$(gh pr list --repo "$REPO" --head "$branch" --state open --json number -q '.[0].number')"
    bash "$SCRIPTS/router-conveyor.sh" record-started "$pr_num"
    _notify "opened PR #$pr_num for $branch"
    ;;

  fix-review)
    pr="$(python3    -c 'import json,sys; print(json.loads(sys.argv[1])["pr"])'     "$action_json")"
    branch="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("headRefName","?"))' "$action_json")"
    echo "$LOG_TAG fix-review PR #$pr — firing agent"
    _notify "fix-review fired for PR #$pr ($branch)"
    _fire_agent "fannyclaw/auto" 900 "$(cat <<PROMPT
⚠️ Automated fix-review for ${REPO}. One action, then stop.

Project dir: ${PROJECT_DIR}
Scripts:     ${SCRIPTS}

Oracle result:
${action_json}

Check out the branch. Apply the minimal fix from threads[].
Then verify:
  cd ${PROJECT_DIR}
  go build ./...
  go test ./...
Fix failures until both pass. Then:
  git add -A && git commit -m "fix: address review" && git push
Do NOT open a new PR. Stop.
PROMPT
)"
    ;;

  new-slice)
    branch="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["suggested_branch"])' "$action_json")"
    pkg="$(python3    -c 'import json,sys; print(json.loads(sys.argv[1])["package"])'          "$action_json")"
    echo "$LOG_TAG new-slice for $pkg — firing agent"
    _notify "new-slice fired for $pkg ($branch)"
    _fire_agent "fannyclaw/auto" 1200 "$(cat <<PROMPT
⚠️ Automated test-coverage task for ${REPO}. One action, then stop.

Project dir: ${PROJECT_DIR}
Scripts:     ${SCRIPTS}

Oracle result:
${action_json}

The JSON includes uncovered_fns:[{fn,file,pct},...] — use this list directly.
Do NOT run coverage tools or read source files to discover what to test.
Pick 2-4 functions with lowest pct (prioritise 0%). Read only those function bodies.
Write one focused test file for the named package.

bash ${SCRIPTS}/start-slice.sh ${branch}
<write tests>
go test ./...
git add -A && git commit -m "test: coverage for ${pkg}" && git push
*** NEVER use gh pr create directly ***
bash ${SCRIPTS}/open-pr-with-review.sh "test: coverage for ${pkg}" ""
pr_num=\$(gh pr list --repo ${REPO} --head ${branch} --state open --json number -q '.[0].number')
bash ${SCRIPTS}/router-conveyor.sh record-started "\$pr_num"
Stop.
PROMPT
)"
    ;;

  feature|brainstorm)
    issue="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("issue","?"))' "$action_json")"
    branch="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("suggested_branch","?"))' "$action_json")"
    echo "$LOG_TAG $action #$issue ($branch) — firing agent"
    _notify "$action fired for issue #$issue ($branch)"
    _fire_agent "fannyclaw/auto" 1800 "$(cat <<PROMPT
⚠️ Automated ${action} task for ${REPO}. One action, then stop.

Project dir: ${PROJECT_DIR}
Scripts:     ${SCRIPTS}

Oracle result:
${action_json}

Read the issue body above. Implement minimally to satisfy the acceptance criteria.
Grep before reading files; only read what you need to touch.

bash ${SCRIPTS}/start-slice.sh ${branch}
<implement>
go build ./...
go test ./...
git add -A && git commit -m "feat: <title from issue>" && git push
*** NEVER use gh pr create directly ***
bash ${SCRIPTS}/open-pr-with-review.sh "feat: <title>" "Closes #${issue}"
pr_num=\$(gh pr list --repo ${REPO} --head ${branch} --state open --json number -q '.[0].number')
bash ${SCRIPTS}/router-conveyor.sh record-started "\$pr_num"
Stop.
PROMPT
)"
    ;;

  *)
    echo "$LOG_TAG unknown action '$action' — firing fallback agent" >&2
    _notify "unknown action '$action' — fallback agent fired"
    _fire_agent "fannyclaw/auto" 1800 "$(cat <<PROMPT
⚠️ Automated task for ${REPO}. One action, then stop.

Project dir: ${PROJECT_DIR}
Scripts:     ${SCRIPTS}

Oracle result (unrecognised action — use judgment):
${action_json}
PROMPT
)"
    ;;
esac
