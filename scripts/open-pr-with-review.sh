#!/usr/bin/env bash
# open-pr-with-review.sh <title> [body] — open a PR and immediately request Copilot review.
# Output: {"pr":101,"url":"https://github.com/pjbrau/openclaw-router-proxy/pull/101"}
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

PR_URL=$(gh pr create --repo "$REPO" --title "$TITLE" --body "$BODY")
PR_NUMBER=$(gh pr view "$PR_URL" --repo "$REPO" --json number --jq .number)

"$SCRIPT_DIR/request-copilot-review.sh" "$REPO" "$PR_NUMBER" >/dev/null 2>&1 || true

echo "{\"pr\": $PR_NUMBER, \"url\": \"$PR_URL\"}"
