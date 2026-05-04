#!/usr/bin/env bash
set -euo pipefail

REPO="${ROUTER_PROXY_REPO:-pjbrau/openclaw-router-proxy}"
STATE_DIR="${ROUTER_CONVEYOR_STATE_DIR:-.river}"
STATE_FILE="${ROUTER_CONVEYOR_STATE_FILE:-$STATE_DIR/router-conveyor-state.json}"

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required binary: $1" >&2
    exit 1
  }
}

require_bin gh
require_bin python3

mkdir -p "$STATE_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
  cat >"$STATE_FILE" <<'JSON'
{
  "dispatchedFixes": {},
  "lastMergedPr": null,
  "lastStartedPr": null
}
JSON
fi

owner="${REPO%/*}"
name="${REPO#*/}"

pr_snapshot() {
  local pr="$1"
  gh api graphql -f query='query($owner:String!, $name:String!, $number:Int!) { repository(owner:$owner, name:$name) { pullRequest(number:$number) { number title url state headRefName isDraft mergeStateStatus reviews(first:20) { nodes { author { login } body submittedAt state commit { oid } } } reviewThreads(first:100) { nodes { isResolved isOutdated path line comments(first:20) { nodes { author { login } body url createdAt } } } } } } }' \
    -F owner="$owner" -F name="$name" -F number="$pr"
}

list_open_prs() {
  gh pr list --repo "$REPO" --state open --limit 50 --json number,title,headRefName,updatedAt,url,isDraft
}

list_merged_prs() {
  gh pr list --repo "$REPO" --state merged --limit 50 --json number,title,mergedAt,mergeCommit,url
}

classify_pr() {
  local pr="$1"
  local snapshot_file
  snapshot_file="$(mktemp)"
  pr_snapshot "$pr" >"$snapshot_file"
  python3 - "$snapshot_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    payload = json.load(f)
pr = payload["data"]["repository"]["pullRequest"]
reviews = pr.get("reviews", {}).get("nodes", [])
threads = pr.get("reviewThreads", {}).get("nodes", [])
summary_seen = any((r.get("author") or {}).get("login") == "copilot-pull-request-reviewer" for r in reviews)
active_threads = []
for thread in threads:
    if thread.get("isResolved") or thread.get("isOutdated"):
        continue
    comments = thread.get("comments", {}).get("nodes", [])
    bodies = [c.get("body", "") for c in comments if (c.get("author") or {}).get("login") == "copilot-pull-request-reviewer"]
    if bodies:
        active_threads.append({
            "path": thread.get("path"),
            "line": thread.get("line"),
            "body": bodies[-1]
        })
if not summary_seen:
    state = "waiting_for_summary"
elif active_threads:
    state = "actionable_review"
else:
    state = "merge_ready"
print(json.dumps({
    "pr": pr["number"],
    "title": pr["title"],
    "url": pr["url"],
    "headRefName": pr["headRefName"],
    "state": state,
    "activeThreads": active_threads,
    "summarySeen": summary_seen,
    "mergeStateStatus": pr.get("mergeStateStatus")
}))
PY
  rm -f "$snapshot_file"
}

remember_dispatch() {
  local pr="$1"
  local fingerprint="$2"
  python3 - "$STATE_FILE" "$pr" "$fingerprint" <<'PY'
import json, sys
path, pr, fingerprint = sys.argv[1:4]
with open(path) as f:
    data = json.load(f)
data.setdefault("dispatchedFixes", {})[pr] = fingerprint
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

was_dispatched() {
  local pr="$1"
  local fingerprint="$2"
  python3 - "$STATE_FILE" "$pr" "$fingerprint" <<'PY'
import json, sys
path, pr, fingerprint = sys.argv[1:4]
with open(path) as f:
    data = json.load(f)
print("yes" if data.get("dispatchedFixes", {}).get(pr) == fingerprint else "no")
PY
}

record_merged_pr() {
  local pr="$1"
  python3 - "$STATE_FILE" "$pr" <<'PY'
import json, sys
path, pr = sys.argv[1:3]
with open(path) as f:
    data = json.load(f)
data["lastMergedPr"] = int(pr)
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

record_started_pr() {
  local pr="$1"
  python3 - "$STATE_FILE" "$pr" <<'PY'
import json, sys
path, pr = sys.argv[1:3]
with open(path) as f:
    data = json.load(f)
data["lastStartedPr"] = int(pr)
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

merge_pr() {
  local pr="$1"
  gh pr merge "$pr" --repo "$REPO" --squash >/dev/null
  record_merged_pr "$pr"
  gh pr view "$pr" --repo "$REPO" --json state,mergedAt,mergeCommit,url
}

reconcile_state() {
  local open_file merged_file
  open_file="$(mktemp)"
  merged_file="$(mktemp)"
  list_open_prs >"$open_file"
  list_merged_prs >"$merged_file"
  python3 - "$STATE_FILE" "$open_file" "$merged_file" <<'PY'
import json, sys
state_path, open_path, merged_path = sys.argv[1:4]
with open(state_path) as f:
    state = json.load(f)
with open(open_path) as f:
    open_prs = json.load(f)
with open(merged_path) as f:
    merged_prs = json.load(f)
if open_prs:
    state["lastStartedPr"] = max(pr["number"] for pr in open_prs)
if merged_prs:
    state["lastMergedPr"] = max(pr["number"] for pr in merged_prs)
with open(state_path, "w") as f:
    json.dump(state, f, indent=2, sort_keys=True)
    f.write("\n")
print(json.dumps(state, indent=2))
PY
  rm -f "$open_file" "$merged_file"
}

scan() {
  local prs_file
  prs_file="$(mktemp)"
  list_open_prs >"$prs_file"
  python3 - "$prs_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    prs = json.load(f)
print(json.dumps({"openPrs": prs}, indent=2))
PY
  rm -f "$prs_file"
}

case "${1:-}" in
  scan)
    scan
    ;;
  classify)
    classify_pr "$2"
    ;;
  merge)
    merge_pr "$2"
    ;;
  reconcile)
    reconcile_state
    ;;
  mark-dispatched)
    remember_dispatch "$2" "$3"
    ;;
  was-dispatched)
    was_dispatched "$2" "$3"
    ;;
  record-started)
    record_started_pr "$2"
    ;;
  *)
    echo "usage: $0 {scan|classify <pr>|merge <pr>|reconcile|mark-dispatched <pr> <fingerprint>|was-dispatched <pr> <fingerprint>|record-started <pr>}" >&2
    exit 1
    ;;
esac
