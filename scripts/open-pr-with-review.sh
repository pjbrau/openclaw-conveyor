#!/usr/bin/env bash
# open-pr-with-review.sh <title> [body] — open a PR and immediately request Copilot review.
# Refuses to open if `go build ./...` or `go test ./...` fails, and deletes the
# pushed remote branch so the conveyor re-slices instead of looping on `open-pr`.
# Output: {"pr":101,"url":"https://github.com/pjbrau/openclaw-router-proxy/pull/101"}
# Exit: 0 opened · 3 slice rejected by build/test, branch deleted, re-slice next tick
#       · 1 usage/unexpected failure
set -euo pipefail

REPO="${ROUTER_PROXY_REPO:-pjbrau/openclaw-router-proxy}"
TITLE="${1:-}"
BODY="${2:-}"

if [[ -z "$TITLE" ]]; then
  echo "usage: $0 <title> [body]" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

abort_with_dead_branch() {
  local reason="$1" logfile="$2"
  echo "$reason — refusing to open PR" >&2
  tail -50 "$logfile" >&2 || true
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "HEAD" && "$branch" != "main" && "$branch" != "master" ]]; then
    git push origin --delete "$branch" >/dev/null 2>&1 || true
    echo "deleted remote branch $branch so conveyor re-slices" >&2
  fi
  # 3, not 1: this is the handled outcome — the slice was rejected, the branch is
  # gone, and the conveyor will re-slice next tick. Callers that treat any nonzero
  # as a crash marked their systemd unit failed for a result we deliberately
  # produce. Still nonzero, because no PR was opened and no JSON was printed.
  exit 3
}

BUILD_LOG="$(mktemp -t open-pr-build.XXXXXX.log)"
TEST_LOG="$(mktemp -t open-pr-test.XXXXXX.log)"
trap 'rm -f "$BUILD_LOG" "$TEST_LOG"' EXIT

if ! go build ./... >"$BUILD_LOG" 2>&1; then
  abort_with_dead_branch "go build failed" "$BUILD_LOG"
fi
if ! go test ./... >"$TEST_LOG" 2>&1; then
  abort_with_dead_branch "go test failed" "$TEST_LOG"
fi

PR_URL=$(gh pr create --repo "$REPO" --title "$TITLE" --body "$BODY")
PR_NUMBER=$(gh pr view "$PR_URL" --repo "$REPO" --json number --jq .number)

"$SCRIPT_DIR/request-copilot-review.sh" "$REPO" "$PR_NUMBER" || echo "warning: failed to add Copilot reviewer — preflight will retry via add-reviewer action" >&2

echo "{\"pr\": $PR_NUMBER, \"url\": \"$PR_URL\"}"
