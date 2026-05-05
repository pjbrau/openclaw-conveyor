#!/usr/bin/env bash
# conveyor-preflight.sh — lightweight 60s dispatcher.
#
# Runs conveyor-next-action.sh (pure shell, ~5s, no LLM).
# - merge:        executes router-conveyor.sh merge directly (no LLM)
# - wait:         exits quietly
# - new-slice /
#   fix-review:   bumps the LLM cron job's nextRunAtMs to now+5s so OpenClaw
#                 fires the full agent session immediately
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

  new-slice|fix-review)
    # Wake the LLM cron job in 5 seconds
    python3 - "$JOBS_STATE" "$CONVEYOR_JOB_ID" <<'PY'
import json, sys, time, os, tempfile, shutil

state_path, job_id = sys.argv[1], sys.argv[2]
now_ms = int(time.time() * 1000)

with open(state_path) as f:
    state = json.load(f)

job = state['jobs'].get(job_id, {})
job_state = job.get('state', {})

# Only bump if not already firing very soon
current_next = job_state.get('nextRunAtMs', 0)
if current_next - now_ms > 10000:
    job_state['nextRunAtMs'] = now_ms + 5000
    job['state'] = job_state
    state['jobs'][job_id] = job

    # Write atomically
    tmp = state_path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(state, f, indent=2)
    shutil.move(tmp, state_path)
    print(f"Bumped nextRunAtMs to now+5s (was {current_next - now_ms}ms away)")
else:
    print(f"LLM cron already firing in {current_next - now_ms}ms, no bump needed")
PY
    ;;

  *)
    echo "Unknown action: $action"
    exit 1
    ;;
esac
