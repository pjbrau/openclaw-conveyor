#!/usr/bin/env bash
# conveyor-preflight.sh — lightweight 60s dispatcher.
#
# Runs conveyor-next-action.sh (pure shell, ~5s, no LLM).
# - merge:        executes router-conveyor.sh merge directly (no LLM)
# - open-pr:      checks out orphaned branch, opens PR + Copilot review (no LLM)
# - wait:         exits quietly
# - new-slice /
#   fix-review:   bumps the LLM cron job's nextRunAtMs by a backoff delay so
#                 OpenClaw fires the full agent session; backoff grows with
#                 consecutiveErrors to avoid hammering when rate-limited:
#                   0 errors → +5 s
#                   1 error  → +60 s
#                   2 errors → +120 s
#                   3+ errors→ +300 s
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)/openclaw-router-proxy}"
JOBS_STATE="${JOBS_STATE:-$HOME/.openclaw/cron/jobs-state.json}"
CONVEYOR_JOB_ID="06801882-7703-44b5-a5f4-866749123947"
LOCK_FILE="/tmp/conveyor-preflight.lock"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/../state}"
STREAK_MARKER="$STATE_DIR/error-streak-alerted"
STREAK_THRESHOLD="${STREAK_THRESHOLD:-5}"
DISCORD_CHANNEL="${CONVEYOR_NOTIFY_CHANNEL:-1495795961069305897}"

# Same shape as router-proxy-dispatch.sh: the message is passed as a single argv
# entry, never interpolated into a shell command line.
_notify() {
  openclaw message send --channel discord --target "$DISCORD_CHANNEL" \
    --silent --message "[pjbrau-openclaw-router-proxy] $*" 2>/dev/null || true
}

# Alert on a sustained LLM-job failure streak.
#
# The backoff below caps at 300s and then retries forever in silence. On 2026-08-05
# that ran ~7 hours overnight (consecutiveErrors 17 → 29, 20:35 → 03:30) with no
# notification of any kind — the only trace was a counter in the journal. Every other
# conveyor in the fleet reports when it gets stuck; this one, the unattended one
# burning a paid API, did not.
#
# One-shot per streak, so a wedged job cannot spam the channel — the marker also
# carries the running peak so the recovery message can report how bad it got.
_check_error_streak() {
  local errors prev peak
  errors="$(python3 - "$JOBS_STATE" "$CONVEYOR_JOB_ID" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(int(d['jobs'].get(sys.argv[2], {}).get('state', {}).get('consecutiveErrors', 0)))
except Exception:
    print(0)   # never let a state-file hiccup abort the tick
PY
)"
  mkdir -p "$STATE_DIR"
  prev=0
  if [[ -f "$STREAK_MARKER" ]]; then
    prev="$(cat "$STREAK_MARKER" 2>/dev/null || echo 0)"
  fi

  if [[ "$errors" -ge "$STREAK_THRESHOLD" ]]; then
    if [[ "$prev" -eq 0 ]]; then
      _notify "⚠️ conveyor LLM job has failed $errors times in a row — backoff pinned at 5 min, no work is landing. Check \`fannyclaw status\` and the agent logs."
      echo "error-streak alert sent (errors=$errors)"
    fi
    if [[ "$errors" -gt "$prev" ]]; then
      echo "$errors" > "$STREAK_MARKER"
    fi
  elif [[ "$errors" -eq 0 && "$prev" -ne 0 ]]; then
    peak="$prev"
    rm -f "$STREAK_MARKER"
    _notify "✅ conveyor LLM job recovered — streak peaked at $peak consecutive errors."
    echo "error-streak cleared (peaked at $peak)"
  fi
}

# Prevent overlapping runs
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "preflight already running, skipping"; exit 0; }

cd "$REPO_ROOT"

action_json="$("$SCRIPT_DIR/conveyor-next-action.sh" 2>&1)"
action="$(echo "$action_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('action',''))")"

echo "$(date -Iseconds) action=$action"

# Before dispatching: every tick, whatever the action. Checking only inside the
# new-slice branch would mean a streak that ends while the conveyor is merging or
# idle goes unreported until the next slice.
_check_error_streak

case "$action" in
  wait)
    # Nothing to do
    exit 0
    ;;

  merge)
    pr="$(echo "$action_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['pr'])")"
    echo "Merging PR #$pr"
    exec bash "$SCRIPT_DIR/router-conveyor.sh" merge "$pr"
    ;;

  open-pr)
    branch="$(echo "$action_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch'])")"
    title="$(echo "$action_json"  | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])")"
    echo "Opening PR for orphaned branch: $branch"
    # Force-reset local branch to the remote state (avoids stale local divergence)
    git -C "$REPO_ROOT" fetch origin "$branch"
    git -C "$REPO_ROOT" checkout -B "$branch" "origin/$branch"
    result="$(bash "$SCRIPT_DIR/open-pr-with-review.sh" "$title")"
    pr_num="$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['pr'])")"
    bash "$SCRIPT_DIR/router-conveyor.sh" record-started "$pr_num"
    echo "Opened PR #$pr_num for $branch"
    ;;


  feature|brainstorm)
    # Feature or brainstorm action — wake the LLM cron job to handle
    echo "Starting LLM agent for $action"
    python3 - "$JOBS_STATE" "$CONVEYOR_JOB_ID" <<'PY'
import json, sys, time, os, tempfile, shutil

state_path, job_id = sys.argv[1], sys.argv[2]
now_ms = int(time.time() * 1000)

with open(state_path) as f:
    state = json.load(f)

job = state['jobs'].get(job_id, {})
job_state = job.get('state', {})

# Immediate trigger for feature/brainstorm
job_state['nextRunAtMs'] = now_ms + 1_000  # 1 second from now

job['state'] = job_state
state['jobs'][job_id] = job

# Write atomically
tmp = state_path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
shutil.move(tmp, state_path)
print(f"Triggered LLM cron job for feature/brainstorm")
PY
    ;;

  new-slice|fix-review)
    # Wake the LLM cron job after a backoff delay that grows with consecutive errors
    python3 - "$JOBS_STATE" "$CONVEYOR_JOB_ID" <<'PY'
import json, sys, time, os, tempfile, shutil

state_path, job_id = sys.argv[1], sys.argv[2]
now_ms = int(time.time() * 1000)

with open(state_path) as f:
    state = json.load(f)

job = state['jobs'].get(job_id, {})
job_state = job.get('state', {})

errors = job_state.get('consecutiveErrors', 0)
if errors == 0:
    delay_ms = 5_000
elif errors == 1:
    delay_ms = 60_000
elif errors == 2:
    delay_ms = 120_000
else:
    delay_ms = 300_000

# Only bump if the next run is further away than our desired delay window.
# This prevents the 60s preflight tick from immediately re-bumping a longer
# backoff that was just set.
current_next = job_state.get('nextRunAtMs', 0)
if current_next - now_ms > delay_ms:
    job_state['nextRunAtMs'] = now_ms + delay_ms
    job['state'] = job_state
    state['jobs'][job_id] = job

    # Write atomically
    tmp = state_path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(state, f, indent=2)
    shutil.move(tmp, state_path)
    print(f"Bumped nextRunAtMs to now+{delay_ms}ms (errors={errors}, was {current_next - now_ms}ms away)")
else:
    print(f"LLM cron already within backoff window ({current_next - now_ms}ms ≤ {delay_ms}ms), no bump")
PY
    ;;

  *)
    echo "Unknown action: $action"
    exit 1
    ;;
esac
