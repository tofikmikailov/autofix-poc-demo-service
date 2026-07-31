#!/usr/bin/env bash
#
# Section 15: check for an existing PR for this branch BEFORE Copilot
# ever runs. If one already exists, execute-job.sh must skip Copilot,
# skip commit/push, and report the existing PR straight to the
# callback -- this is the early-exit half of the local Agent Runner's
# create-pr.sh idempotent lookup. The create-or-reuse half (run after
# Copilot has produced a diff) lives in find-or-create-pr.sh.
#
# Usage:
#   check-existing-pr.sh <repo-dir> <branch-name>
#
# Output (stdout): JSON, either {"exists": false} or
#   {"exists": true, "number": 4, "url": "...", "isDraft": true}

set -euo pipefail

REPO_DIR="${1:?usage: find-existing-pr.sh <repo-dir> <branch-name>}"
BRANCH_NAME="${2:?missing branch-name}"

cd "$REPO_DIR"

RESULT="$(gh pr list \
  --repo "${AUTOFIX_REPOSITORY_OWNER:?missing AUTOFIX_REPOSITORY_OWNER}/${AUTOFIX_REPOSITORY_NAME:?missing AUTOFIX_REPOSITORY_NAME}" \
  --head "$BRANCH_NAME" \
  --state all \
  --json number,url,state,isDraft \
  --limit 1)"

COUNT="$(echo "$RESULT" | jq 'length')"

if [[ "$COUNT" -gt 0 ]]; then
  echo "$RESULT" | jq '{exists: true, number: .[0].number, url: .[0].url, isDraft: .[0].isDraft, state: .[0].state}'
else
  jq -n '{exists: false}'
fi
