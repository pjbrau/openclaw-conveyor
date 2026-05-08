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

  # ── 1.5. Check for remote branches pushed but never opened as a PR ──────
  # Happens when the agent pushes a branch then fails before running
  # open-pr-with-review.sh.  Preflight handles this action directly (no LLM).
  orphan_json="$(python3 - <<'PY'
import subprocess, json, sys, os

repo_root = subprocess.check_output(
    ['git', 'rev-parse', '--show-toplevel'], text=True).strip()

# Refresh remote refs quietly
subprocess.run(['git', 'fetch', '--prune', 'origin'], capture_output=True, cwd=repo_root)

result = subprocess.run(
    ['git', 'branch', '-r', '--format=%(refname:short)'],
    capture_output=True, text=True, cwd=repo_root)
remote_branches = [
    b.strip() for b in result.stdout.splitlines()
    if b.strip().startswith('origin/test/') and b.strip() != 'origin/test/'
]

for remote_branch in sorted(remote_branches):
    local_name = remote_branch.removeprefix('origin/')

    # Skip if no commits ahead of main (fast-path)
    r = subprocess.run(
        ['git', 'rev-list', '--count', f'origin/main..{remote_branch}'],
        capture_output=True, text=True, cwd=repo_root)
    if int(r.stdout.strip() or '0') == 0:
        continue

    # Skip if branch adds no new test functions vs main.
    # Squash-merges leave the branch "ahead" even after merging; checking for
    # new func Test lines avoids opening duplicate PRs for already-merged content.
    diff_r = subprocess.run(
        ['git', 'diff', 'origin/main', remote_branch, '--', '*.go'],
        capture_output=True, text=True, cwd=repo_root)
    has_new_tests = any(
        line.startswith('+func Test')
        for line in diff_r.stdout.splitlines()
    )
    if not has_new_tests:
        continue

    # Skip if an open PR already exists for this branch
    pr_r = subprocess.run(
        ['gh', 'pr', 'list', '--repo', 'pjbrau/openclaw-router-proxy',
         '--head', local_name, '--state', 'open', '--json', 'number'],
        capture_output=True, text=True)
    if json.loads(pr_r.stdout.strip() or '[]'):
        continue

    # Derive PR title from the latest commit subject
    msg_r = subprocess.run(
        ['git', 'log', '-1', '--format=%s', remote_branch],
        capture_output=True, text=True, cwd=repo_root)
    title = msg_r.stdout.strip() or f'test: coverage slice for {local_name}'

    print(json.dumps({"action": "open-pr", "branch": local_name, "title": title}))
    sys.exit(0)
PY
  )"
  if [[ -n "$orphan_json" ]]; then
    echo "$orphan_json"
    exit 0
  fi

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

# Compute uncovered functions via go test -coverprofile
import subprocess, os, tempfile, re as rego
repo_root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'],
                                     text=True).strip()
cov_file = tempfile.mktemp(suffix='.out')
try:
    subprocess.run(
        ['go', 'test', '-coverprofile', cov_file, target['full_package']],
        capture_output=True, cwd=repo_root
    )
    result = subprocess.run(
        ['go', 'tool', 'cover', '-func', cov_file],
        capture_output=True, text=True, cwd=repo_root
    )
    uncovered = []
    for line in result.stdout.splitlines():
        m = rego.match(r'(\S+)\s+(\S+)\s+([\d.]+)%', line)
        if m and m.group(3) != '100.0' and not line.startswith('total:'):
            file_func = m.group(1).split(':')[-1] + ':' + m.group(2)
            uncovered.append({'fn': m.group(2), 'file': m.group(1).split(':')[0].split('/')[-1], 'pct': float(m.group(3))})
finally:
    if os.path.exists(cov_file):
        os.unlink(cov_file)

print(json.dumps({
    "action":           "new-slice",
    "package":          pkg,
    "full_package":     target['full_package'],
    "coverage":         target['coverage'],
    "suggested_branch": branch,
    "uncovered_fns":    uncovered
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

# Priority: merge_ready > actionable_review > waiting_for_summary > needs_rebase
for state in ('merge_ready', 'actionable_review', 'waiting_for_summary', 'needs_rebase'):
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
                reason = ('PR has a merge conflict — needs rebase'
                          if state == 'needs_rebase'
                          else 'waiting for Copilot review summary')
                print(json.dumps({
                    'action': 'wait',
                    'pr':     r['pr'],
                    'title':  r['title'],
                    'url':    r['url'],
                    'reason': reason
                }))
            sys.exit(0)

# All PRs still waiting
prs_list = [r.get('pr') for r in results]
print(json.dumps({'action': 'wait', 'reason': 'all open PRs waiting for Copilot review', 'prs': prs_list}))
"

rm -f "$open_prs_file"
rm -rf "$classify_dir"
