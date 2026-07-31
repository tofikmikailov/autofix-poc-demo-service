#!/usr/bin/env bash
#
# Section 19/22: notify n8n Workflow 04 ("Finalize AutoFix Result") of
# the job outcome via the new callback contract
# (POST /webhook/autofix/agent-result), replacing the old
# report-result.sh webhook. Unlike the local Agent Runner, this script
# never writes to PostgreSQL itself -- the agent container has no DB
# credentials (Section 6) -- Workflow 04 owns every incident-row update
# based on this callback's payload.
#
# This is intentionally best-effort for the HTTP call itself: by the
# time this script runs, PR creation (if any) has already happened and
# is durable in GitHub, so a failed callback does not undo that. n8n's
# reconciliation (a later GET /api/jobs/{jobId} poll, or a manual
# re-dispatch) can recover from a dropped callback.
#
# Usage:
#   send-result.sh <status> <job-id> <jira-key> <incident-id> \
#                  <context-hash> [pr-number] [pr-url] [commit-sha] \
#                  [changed-files] [added-lines] [deleted-lines] \
#                  [error-code] [error-message]
#
#   status must be one of: PR_READY | HUMAN_REQUIRED | AGENT_FAILED
#
# Exit codes:
#   0 - callback responded 2xx
#   1 - callback call failed or responded with a non-2xx status
#       (non-fatal to the job -- see note above)

set -uo pipefail

STATUS="${1:?usage: send-result.sh <status> <job-id> <jira-key> <incident-id> <context-hash> [...]}"
JOB_ID="${2:?missing job-id}"
JIRA_KEY="${3:?missing jira-key}"
INCIDENT_ID="${4:?missing incident-id}"
CONTEXT_HASH="${5:?missing context-hash}"
PR_NUMBER="${6:-null}"
PR_URL="${7:-}"
COMMIT_SHA="${8:-}"
CHANGED_FILES="${9:-null}"
ADDED_LINES="${10:-null}"
DELETED_LINES="${11:-null}"
ERROR_CODE="${12:-}"
ERROR_MESSAGE="${13:-}"

case "$STATUS" in
  PR_READY|HUMAN_REQUIRED|AGENT_FAILED) ;;
  *)
    echo "send-result.sh: invalid status '$STATUS'" >&2
    exit 1
    ;;
esac

CALLBACK_URL="${AUTOFIX_CALLBACK_URL:-http://n8n:5678/webhook/autofix/agent-result}"
CALLBACK_TOKEN="${AUTOFIX_CALLBACK_TOKEN:?AUTOFIX_CALLBACK_TOKEN is required}"

PAYLOAD="$(jq -n \
  --arg status "$STATUS" \
  --arg jobId "$JOB_ID" \
  --arg jiraKey "$JIRA_KEY" \
  --argjson incidentId "$INCIDENT_ID" \
  --arg contextHash "$CONTEXT_HASH" \
  --arg prUrl "$PR_URL" \
  --arg commitSha "$COMMIT_SHA" \
  --arg errorCode "$ERROR_CODE" \
  --arg errorMessage "$ERROR_MESSAGE" \
  --argjson prNumber "$PR_NUMBER" \
  --argjson changedFiles "$CHANGED_FILES" \
  --argjson addedLines "$ADDED_LINES" \
  --argjson deletedLines "$DELETED_LINES" \
  '{
    status: $status,
    jobId: $jobId,
    jiraKey: $jiraKey,
    incidentId: $incidentId,
    contextHash: $contextHash
  }
  + (if $status == "PR_READY" then {
      prNumber: $prNumber,
      prUrl: $prUrl,
      commitSha: $commitSha,
      testsPassed: true,
      changedFiles: $changedFiles,
      addedLines: $addedLines,
      deletedLines: $deletedLines
    } else {} end)
  + (if $errorCode != "" then {errorCode: $errorCode, errorMessage: $errorMessage} else {} end)')"

RESPONSE_FILE="$(mktemp -t autofix-agent-send-result-XXXXXX.json)"
HTTP_STATUS="$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "$CALLBACK_URL" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $CALLBACK_TOKEN" \
  -d "$PAYLOAD")"

RESPONSE_BODY="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
rm -f "$RESPONSE_FILE"

if [[ "$HTTP_STATUS" =~ ^2[0-9][0-9]$ ]]; then
  echo "Workflow 04 accepted callback for $JOB_ID ($STATUS): $RESPONSE_BODY" >&2
  exit 0
else
  echo "Callback failed (HTTP $HTTP_STATUS) for $JOB_ID: $RESPONSE_BODY -- result recoverable via GET /api/jobs/$JOB_ID" >&2
  exit 1
fi
