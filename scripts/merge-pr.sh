#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

REPO="${1:-pjbrau/openclaw-router-proxy}"
PR="${2:-}"

if [[ -z "$PR" ]]; then
  echo "usage: $0 <owner/repo> <pr-number>" >&2
  exit 1
fi

# Intentionally preserve the branch after merge.
gh pr merge "$PR" --repo "$REPO" --squash

gh pr view "$PR" --repo "$REPO" --json state,mergedAt,mergeCommit,url
