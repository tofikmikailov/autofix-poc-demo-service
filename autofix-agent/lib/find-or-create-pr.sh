#!/usr/bin/env bash
#
# Section 17: idempotent Draft PR creation/reuse, run after the commit
# has been pushed. No PostgreSQL write happens here (unlike the local
# Agent Runner's create-pr.sh) -- n8n's Workflow 04 updates the incident
# row once it receives the callback from send-result.sh.
#
# Usage:
#   find-or-create-pr.sh <repo-dir> <branch-name> <pr-title> <pr-body-file>
#
# Output (stdout): {"prNumber": 12, "prUrl": "https://github.com/.../pull/12"}

set -euo pipefail

REPO_DIR="${1:?usage: find-or-create-pr.sh <repo-dir> <branch-name> <pr-title> <pr-body-file>}"
BRANCH_NAME="${2:?missing branch-name}"
PR_TITLE="${3:?missing pr-title}"
PR_BODY_FILE="${4:?missing pr-body-file}"
BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"

cd "$REPO_DIR"

if [[ ! -f "$PR_BODY_FILE" ]]; then
  echo "PR body file not found: $PR_BODY_FILE" >&2
  exit 1
fi

EXISTING_PR="$(gh pr list --head "$BRANCH_NAME" --state open --json number,url --limit 1)"
PR_COUNT="$(echo "$EXISTING_PR" | jq 'length')"

if [[ "$PR_COUNT" -gt 0 ]]; then
  PR_NUMBER="$(echo "$EXISTING_PR" | jq -r '.[0].number')"
  PR_URL="$(echo "$EXISTING_PR" | jq -r '.[0].url')"
  echo "Reusing existing PR #$PR_NUMBER for branch $BRANCH_NAME" >&2
else
  gh pr create \
    --draft \
    --base "$BASE_BRANCH" \
    --head "$BRANCH_NAME" \
    --title "$PR_TITLE" \
    --body-file "$PR_BODY_FILE" >&2

  CREATED_PR="$(gh pr list --head "$BRANCH_NAME" --state open --json number,url --limit 1)"
  PR_NUMBER="$(echo "$CREATED_PR" | jq -r '.[0].number')"
  PR_URL="$(echo "$CREATED_PR" | jq -r '.[0].url')"
  echo "Created new Draft PR #$PR_NUMBER for branch $BRANCH_NAME" >&2
fi

if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
  echo "Failed to determine PR number after create/lookup" >&2
  exit 1
fi

jq -n --argjson prNumber "$PR_NUMBER" --arg prUrl "$PR_URL" '{prNumber: $prNumber, prUrl: $prUrl}'
