#!/usr/bin/env bash
#
# Section 13/14: clone the single allow-listed repository into the
# workspace. The repository URL is never accepted from the job request
# -- only from environment configuration set on the container -- so the
# agent can never be pointed at an arbitrary repository via a crafted
# HTTP request.
#
# Usage:
#   clone-repository.sh <workspace-dir>

set -euo pipefail

WORKSPACE_DIR="${1:?usage: clone-repository.sh <workspace-dir>}"

: "${AUTOFIX_REPOSITORY_URL:?AUTOFIX_REPOSITORY_URL is required}"

REPO_DIR="$WORKSPACE_DIR/repository"

echo "Cloning $AUTOFIX_REPOSITORY_URL into $REPO_DIR" >&2
git clone --quiet "$AUTOFIX_REPOSITORY_URL" "$REPO_DIR" >&2

cd "$REPO_DIR"
git config user.name "AutoFix Bot" >&2
git config user.email "autofix-bot@users.noreply.github.com" >&2

git fetch origin --prune --quiet >&2

printf '%s\n' "$REPO_DIR"
