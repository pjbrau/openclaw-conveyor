#!/usr/bin/env bash
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

REPO="${1:-pjbrau/openclaw-router-proxy}"

gh pr list --repo "$REPO" --state open --limit 50 \
  --json number,title,headRefName,updatedAt,url,isDraft
