#!/usr/bin/env bash
#
# Section 11: reset the single, reused workspace directory before a job
# starts. There is no per-job worktree here -- the container handles one
# job at a time (MAX_CONCURRENT_JOBS=1), so a full clean-and-clone is
# simpler and safer than trying to reuse a stale checkout across jobs.
#
# Usage:
#   prepare-workspace.sh

set -euo pipefail

WORKSPACE_ROOT="${AUTOFIX_WORKSPACE_ROOT:-/workspace}"
CURRENT="$WORKSPACE_ROOT/current"

rm -rf "$CURRENT"
mkdir -p "$CURRENT" "$WORKSPACE_ROOT/state"

echo "$CURRENT"
