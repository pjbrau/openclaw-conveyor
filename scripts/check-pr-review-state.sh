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

gh api graphql -f query='query($owner:String!, $name:String!, $number:Int!) { repository(owner:$owner, name:$name) { pullRequest(number:$number) { number title state mergeStateStatus reviewDecision reviews(first:20) { nodes { author { login } body state submittedAt } } reviewThreads(first:100) { nodes { isResolved isOutdated path line comments(first:20) { nodes { author { login } body url createdAt } } } } } } }' -F owner="${REPO%/*}" -F name="${REPO#*/}" -F number="$PR"
