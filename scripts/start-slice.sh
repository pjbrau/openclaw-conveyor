#!/usr/bin/env bash
# start-slice.sh <branch-name> — sync main and create a fresh branch.
# Output: {"branch":"test/cmd-proxy-coverage","base":"main","sha":"abc123"}
set -euo pipefail

BRANCH="${1:-}"
REMOTE="${2:-origin}"

if [[ -z "$BRANCH" ]]; then
  echo "usage: $0 <branch-name> [remote]" >&2
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

git fetch "$REMOTE" main --quiet
git checkout main --quiet
git reset --hard "$REMOTE/main" --quiet
git checkout -b "$BRANCH" --quiet

sha=$(git rev-parse HEAD)
echo "{\"branch\": \"$BRANCH\", \"base\": \"main\", \"sha\": \"$sha\"}"
