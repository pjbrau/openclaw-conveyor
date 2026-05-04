#!/usr/bin/env bash
# conveyor-next-action.sh — single call that tells the conveyor exactly what to do.
#
# Output: one JSON object with an "action" field:
#   {"action":"merge",       "pr":N, "title":"...", "url":"..."}
#   {"action":"fix-review",  "pr":N, "title":"...", "url":"...", "threads":[...]}
#   {"action":"wait",        "pr":N, "title":"...", "url":"...", "reason":"..."}
#   {"action":"new-slice",   "package":"internal/providers", "coverage":55.6,
#                             "full_package":"github.com/...", "suggested_branch":"test/..."}
#   {"action":"nothing-to-do","reason":"all packages at 100% coverage"}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. Check for open PRs ───────────────────────────────────────────────────
open_prs_file="$(mktemp)"
"$SCRIPT_DIR/router-conveyor.sh" scan | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(json.dumps(data.get('openPrs', [])))
" >"$open_prs_file"

open_count=$(python3 -c "import json,sys; print(len(json.load(open('$open_prs_file'))))")

if [[ "$open_count" -eq 0 ]]; then
  rm -f "$open_prs_file"
  # ── 2. No open PRs — find next coverage target ─────────────────────────
  gaps_file="$(mktemp)"
  "$SCRIPT_DIR/coverage-gaps.sh" >"$gaps_file"
  python3 - "$gaps_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    gaps = json.load(f)
targets = [p for p in gaps if p['coverage'] < 100.0]
if not targets:
    print(json.dumps({"action": "nothing-to-do", "reason": "all packages at 100% coverage"}))
    sys.exit(0)
target = targets[0]
pkg = target['package']
branch = 'test/' + pkg.replace('/', '-') + '-coverage'
print(json.dumps({
    "action":           "new-slice",
    "package":          pkg,
    "full_package":     target['full_package'],
    "coverage":         target['coverage'],
    "suggested_branch": branch
}))
PY
  rm -f "$gaps_file"
  exit 0
fi

# ── 3. Classify each open PR and return the highest-priority action ─────────
classify_dir="$(mktemp -d)"
python3 -c "
import json, sys
with open('$open_prs_file') as f:
    prs = json.load(f)
print(json.dumps([p['number'] for p in prs]))
" | python3 -c "
import json, sys, subprocess, os
numbers = json.load(sys.stdin)
script = os.path.join('$SCRIPT_DIR', 'router-conveyor.sh')
results = []
for n in numbers:
    r = subprocess.run([script, 'classify', str(n)], capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        results.append(json.loads(r.stdout.strip()))

# Priority: merge_ready > actionable_review > waiting_for_summary
for state in ('merge_ready', 'actionable_review', 'waiting_for_summary'):
    for r in results:
        if r.get('state') == state:
            if state == 'merge_ready':
                print(json.dumps({
                    'action': 'merge',
                    'pr':     r['pr'],
                    'title':  r['title'],
                    'url':    r['url']
                }))
            elif state == 'actionable_review':
                print(json.dumps({
                    'action':  'fix-review',
                    'pr':      r['pr'],
                    'title':   r['title'],
                    'url':     r['url'],
                    'threads': r.get('activeThreads', [])
                }))
            else:
                print(json.dumps({
                    'action': 'wait',
                    'pr':     r['pr'],
                    'title':  r['title'],
                    'url':    r['url'],
                    'reason': 'waiting for Copilot review summary'
                }))
            sys.exit(0)

# All PRs still waiting
prs_list = [r.get('pr') for r in results]
print(json.dumps({'action': 'wait', 'reason': 'all open PRs waiting for Copilot review', 'prs': prs_list}))
"

rm -f "$open_prs_file"
rm -rf "$classify_dir"
