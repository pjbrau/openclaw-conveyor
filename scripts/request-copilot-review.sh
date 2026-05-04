#!/usr/bin/env bash
set -euo pipefail

# NOTE:
# This script captures the intended explicit review-request step.
# The reviewer handle/route for Copilot may vary by repo/org setup and
# should be validated in this environment before making it mandatory.

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required" >&2
  exit 1
fi

REPO="${1:-pjbrau/openclaw-router-proxy}"
PR="${2:-}"
REVIEWER="${3:-copilot-pull-request-reviewer}"

if [[ -z "$PR" ]]; then
  echo "usage: $0 <owner/repo> <pr-number> [reviewer-handle]" >&2
  exit 1
fi

# Try the ordinary reviewer path first.
gh pr edit "$PR" --repo "$REPO" --add-reviewer "$REVIEWER"
