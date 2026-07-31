#!/usr/bin/env bash
#
# Container entrypoint. Ensures the workspace skeleton exists, clears
# any stale lock left by a previous (killed) container instance, and
# then starts the FastAPI server via uvicorn.

set -euo pipefail

WORKSPACE_ROOT="${AUTOFIX_WORKSPACE_ROOT:-/workspace}"
mkdir -p "$WORKSPACE_ROOT/state" "$WORKSPACE_ROOT/logs" "$WORKSPACE_ROOT/current"
rm -f "$WORKSPACE_ROOT/agent.lock"

: "${AUTOFIX_AGENT_API_TOKEN:?AUTOFIX_AGENT_API_TOKEN must be set}"
: "${AUTOFIX_CALLBACK_TOKEN:?AUTOFIX_CALLBACK_TOKEN must be set}"
: "${AUTOFIX_REPOSITORY_URL:?AUTOFIX_REPOSITORY_URL must be set}"
: "${AUTOFIX_REPOSITORY_OWNER:?AUTOFIX_REPOSITORY_OWNER must be set}"
: "${AUTOFIX_REPOSITORY_NAME:?AUTOFIX_REPOSITORY_NAME must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set (gh CLI auth)}"
: "${COPILOT_GITHUB_TOKEN:?COPILOT_GITHUB_TOKEN must be set (Copilot CLI auth)}"

# GH_TOKEN authenticates `gh`/Copilot CLI's API calls, but plain `git push`
# over HTTPS has no credential helper configured by default -- it fails with
# "could not read Username for 'https://github.com'". `gh auth setup-git`
# wires git's credential.helper to shell out to `gh auth git-credential`,
# which honors GH_TOKEN, so create-commit.sh's `git push` can authenticate.
gh auth setup-git

exec uvicorn server:app --host 0.0.0.0 --port 8090
