#!/usr/bin/env bash
#
# Section 17: commit and push the diff Copilot produced, once
# validate-diff.sh has already returned PASS. Mirrors the commit half
# of the local Agent Runner's create-pr.sh, but with the PostgreSQL
# write removed -- the agent container has no database credentials
# (see spec Section 6); the result is reported back to n8n via
# send-result.sh instead, and n8n's Workflow 04 owns the incident row.
#
# Usage:
#   create-commit.sh <repo-dir> <branch-name> <commit-message> \
#                     <validation-json-file>
#
# Prints "unchanged" or "<commit-sha>" as the last stdout line.
#
# Exit codes:
#   0 - committed (or a prior commit was reused) and pushed
#   1 - hard failure, or nothing to commit on a branch with no prior commit

set -euo pipefail

REPO_DIR="${1:?usage: create-commit.sh <repo-dir> <branch-name> <commit-message> <validation-json-file>}"
BRANCH_NAME="${2:?missing branch-name}"
COMMIT_MESSAGE="${3:?missing commit-message}"
VALIDATION_JSON_FILE="${4:?missing validation-json-file}"
BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"

cd "$REPO_DIR"

VALIDATION_RESULT="$(jq -r '.result' "$VALIDATION_JSON_FILE")"
if [[ "$VALIDATION_RESULT" != "PASS" ]]; then
  echo "Refusing to commit: validation result is '$VALIDATION_RESULT', not PASS" >&2
  exit 1
fi

git add src/main src/test >&2
if [[ -f README.md ]] && ! git diff --cached --quiet -- README.md 2>/dev/null; then
  git add README.md >&2
fi

if git diff --cached --quiet; then
  MERGE_BASE="$(git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "$BASE_BRANCH")"
  if [[ "$(git rev-parse HEAD)" == "$MERGE_BASE" ]]; then
    echo "Nothing staged to commit (src/main, src/test, README.md are all clean)" >&2
    exit 1
  fi
  echo "Nothing new to stage -- reusing existing commit $(git rev-parse --short HEAD) from a prior attempt" >&2
else
  git commit -m "$COMMIT_MESSAGE" >&2
fi

COMMIT_SHA="$(git rev-parse HEAD)"
git push -u origin "$BRANCH_NAME" >&2

echo "$COMMIT_SHA"
