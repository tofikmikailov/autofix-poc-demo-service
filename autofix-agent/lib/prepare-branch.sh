#!/usr/bin/env bash
#
# Section 14/15: deterministic branch checkout with recovery, and an
# informational existing-PR check (the real idempotent PR handling
# lives in find-or-create-pr.sh -- this is just an early, cheap signal
# so execute-job.sh can skip straight to reporting the existing PR
# without re-running Copilot at all, see Section 15).
#
# Usage:
#   prepare-branch.sh <repo-dir> <branch-name>
#
# Exit codes:
#   0 - branch checked out; prints "existing" or "new" as the last line
#   1 - hard failure (git error)

set -euo pipefail

REPO_DIR="${1:?usage: prepare-branch.sh <repo-dir> <branch-name>}"
BRANCH_NAME="${2:?missing branch-name}"
BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"

cd "$REPO_DIR"

if git ls-remote --exit-code --heads origin "refs/heads/$BRANCH_NAME" >/dev/null 2>&1; then
  echo "Branch $BRANCH_NAME exists on origin -- restoring it" >&2
  git checkout -B "$BRANCH_NAME" "origin/$BRANCH_NAME" >&2
  echo "existing"
else
  echo "Branch $BRANCH_NAME does not exist -- cutting from origin/$BASE_BRANCH" >&2
  git checkout -B "$BRANCH_NAME" "origin/$BASE_BRANCH" >&2
  echo "new"
fi
