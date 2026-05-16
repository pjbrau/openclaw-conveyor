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

# Prevent overlapping runs
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "preflight already running, skipping"; exit 0; }

cd "$REPO_ROOT"

action_json="$("$SCRIPT_DIR/conveyor-next-action.sh" 2>&1)"
action="$(echo "$action_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('action',''))")"

echo "$(date -Iseconds) action=$action"

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
