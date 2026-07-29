#!/usr/bin/env bash
#
# Stage 5E: Isolated git worktree preparation.
#
# Creates (or reuses) a dedicated worktree for a given Jira key so that
# Copilot CLI operates on a clean, isolated checkout rather than the main
# working copy. Deterministic branch name: autofix/<JIRA-KEY>.
#
# Handles every resume scenario a crashed/restarted runner can leave
# behind:
#   - worktree directory already exists and is a valid git worktree
#     (e.g. runner crashed mid-job)      -> reused as-is, uncommitted
#                                            Copilot changes are preserved
#   - worktree directory exists but is NOT a registered git worktree
#     (corrupted leftover)               -> removed and recreated
#   - branch already exists locally      -> worktree checks it out
#   - branch already exists on origin
#     (but not locally)                  -> worktree tracks origin/<branch>
#   - branch does not exist anywhere     -> new branch cut from origin/<base-branch>
#     (AUTOFIX_BASE_BRANCH, default "main")
#   - a PR already exists for the branch -> logged as informational only
#     (idempotent PR handling itself lives in create-pr.sh)
#
# Usage:
#   prepare-worktree.sh <jira-key> <branch-name>
#
# Output:
#   Absolute path to the prepared worktree, printed on stdout as the last
#   line (informational/log lines go to stderr).
#
# Exit codes:
#   0 - worktree ready
#   1 - hard failure (git/gh error)

set -euo pipefail

JIRA_KEY="${1:?usage: prepare-worktree.sh <jira-key> <branch-name>}"
BRANCH_NAME="${2:?missing branch-name}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX_REPO="${AUTOFIX_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AUTOFIX_ROOT="${AUTOFIX_ROOT:-$HOME/autofix-poc}"
WORKTREES_ROOT="${AUTOFIX_WORKTREES_DIR:-$AUTOFIX_ROOT/worktrees}"
BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"
WORKTREE="$WORKTREES_ROOT/$JIRA_KEY"

mkdir -p "$WORKTREES_ROOT"
cd "$AUTOFIX_REPO"

echo "Fetching latest refs from origin..." >&2
git fetch origin --prune --quiet

is_registered_worktree() {
  git worktree list --porcelain | grep -qx "worktree $WORKTREE"
}

branch_exists_locally() {
  git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"
}

branch_exists_on_remote() {
  git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"
}

if [[ -d "$WORKTREE" ]]; then
  if is_registered_worktree; then
    echo "Reusing existing worktree at $WORKTREE (resumed after a prior run)" >&2
  else
    echo "Found a leftover, unregistered directory at $WORKTREE -- removing it" >&2
    rm -rf "$WORKTREE"
  fi
fi

if [[ ! -d "$WORKTREE" ]]; then
  if branch_exists_locally; then
    echo "Branch $BRANCH_NAME already exists locally -- checking it out into a new worktree" >&2
    git worktree add "$WORKTREE" "$BRANCH_NAME" >&2
  elif branch_exists_on_remote; then
    echo "Branch $BRANCH_NAME already exists on origin -- tracking it in a new worktree" >&2
    git worktree add "$WORKTREE" -b "$BRANCH_NAME" "origin/$BRANCH_NAME" >&2
  else
    echo "Branch $BRANCH_NAME does not exist yet -- cutting it from origin/$BASE_BRANCH" >&2
    git worktree add "$WORKTREE" -b "$BRANCH_NAME" "origin/$BASE_BRANCH" >&2
  fi
fi

if command -v gh >/dev/null 2>&1; then
  EXISTING_PR_COUNT="$(gh pr list --head "$BRANCH_NAME" --state open --json number --limit 1 2>/dev/null | jq 'length' || echo 0)"
  if [[ "$EXISTING_PR_COUNT" -gt 0 ]]; then
    echo "Note: a PR already exists for branch $BRANCH_NAME (create-pr.sh will reuse it)" >&2
  fi
fi

printf '%s\n' "$WORKTREE"
