#!/usr/bin/env bash
# resolve-review-threads.sh <thread-id> [<thread-id> ...]
# Resolves one or more GitHub review threads by their node IDs.
# Thread IDs come from the "threads[].id" field in the fix-review JSON.
set -euo pipefail

REPO="${ROUTER_PROXY_REPO:-pjbrau/openclaw-router-proxy}"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <thread-id> [<thread-id> ...]" >&2
  exit 1
fi

for thread_id in "$@"; do
  gh api graphql \
    -f query='mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { id isResolved } } }' \
    -f id="$thread_id" \
    --jq '.data.resolveReviewThread.thread | "resolved \(.id): \(.isResolved)"'
done
