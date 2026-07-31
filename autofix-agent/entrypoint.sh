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

exec uvicorn server:app --host 0.0.0.0 --port 8090
