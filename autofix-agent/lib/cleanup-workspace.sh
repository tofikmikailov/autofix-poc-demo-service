#!/usr/bin/env bash
#
# Section 20: wipe the job's working directory and release the
# workspace lock. Retry/backoff scheduling (the old
# mark-incident-failed.sh RETRY branch) is intentionally NOT ported here
# -- the agent container has no PostgreSQL credentials, so it never
# decides when to retry. It only ever reports one terminal-for-this-attempt
# status (PR_READY / HUMAN_REQUIRED / AGENT_FAILED) via send-result.sh;
# n8n's Workflow 04 is the sole owner of the backoff schedule (1min / 5min
# / 15min by attempt number, parsed from the jobId autofix-<id>-<attempt>)
# and of clearing/re-queuing the incident row.
#
# Usage:
#   cleanup-workspace.sh [--keep-logs]

set -uo pipefail

WORKSPACE_ROOT="${AUTOFIX_WORKSPACE_ROOT:-/workspace}"
KEEP_LOGS="false"
[[ "${1:-}" == "--keep-logs" ]] && KEEP_LOGS="true"

if [[ "$KEEP_LOGS" != "true" ]]; then
  rm -rf "${WORKSPACE_ROOT:?}/current"
else
  rm -rf "${WORKSPACE_ROOT:?}/current/repository"
fi

rm -f "$WORKSPACE_ROOT/agent.lock"

echo "[cleanup-workspace] workspace reset (keep-logs=$KEEP_LOGS)" >&2
