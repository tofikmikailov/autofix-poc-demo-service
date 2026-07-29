#!/usr/bin/env bash
#
# Stage 5H glue: notify workflow 04 ("Finalize AutoFix Review") that a
# Draft PR is ready, so it can add the Jira comment and transition the
# ticket to REVIEW.
#
# This is intentionally a thin, best-effort caller: the incident is
# already durably PR_READY in PostgreSQL (create-pr.sh already committed
# that) before this script ever runs, so if the webhook call itself fails
# (n8n down, network blip, ...) that is NOT treated as a pipeline failure
# -- see Stage 5I "PR создан, но webhook не дошёл": the incident simply
# stays PR_READY and the next reconciliation pass (a later run-once.sh
# invocation, or a manual re-call of this script) will find the PR via
# branch_name and safely retry, since workflow 04 itself is idempotent
# (marker-based comment dedup, REVIEW-status short-circuit).
#
# Usage:
#   report-result.sh <incident-id> <jira-key> <branch-name> \
#                     <pr-number> <pr-url> <commit-sha> \
#                     <changed-files> <added-lines> <deleted-lines>
#
# Exit codes:
#   0 - webhook responded 200 (Jira comment/transition done or already done)
#   1 - webhook call failed or responded with a non-200 status (non-fatal
#       to the overall pipeline -- see note above)

set -uo pipefail

INCIDENT_ID="${1:?usage: report-result.sh <incident-id> <jira-key> <branch-name> <pr-number> <pr-url> <commit-sha> <changed-files> <added-lines> <deleted-lines>}"
JIRA_KEY="${2:?missing jira-key}"
BRANCH_NAME="${3:?missing branch-name}"
PR_NUMBER="${4:?missing pr-number}"
PR_URL="${5:?missing pr-url}"
COMMIT_SHA="${6:?missing commit-sha}"
CHANGED_FILES="${7:?missing changed-files}"
ADDED_LINES="${8:?missing added-lines}"
DELETED_LINES="${9:?missing deleted-lines}"

WEBHOOK_URL="${N8N_RESULT_WEBHOOK_URL:-http://localhost:5678/webhook/autofix/pr-ready}"

PAYLOAD="$(jq -n \
  --argjson incidentId "$INCIDENT_ID" \
  --arg jiraKey "$JIRA_KEY" \
  --arg branchName "$BRANCH_NAME" \
  --argjson pullRequestNumber "$PR_NUMBER" \
  --arg pullRequestUrl "$PR_URL" \
  --arg commitSha "$COMMIT_SHA" \
  --argjson changedFiles "$CHANGED_FILES" \
  --argjson addedLines "$ADDED_LINES" \
  --argjson deletedLines "$DELETED_LINES" \
  '{
    incidentId: $incidentId,
    jiraKey: $jiraKey,
    branchName: $branchName,
    pullRequestNumber: $pullRequestNumber,
    pullRequestUrl: $pullRequestUrl,
    commitSha: $commitSha,
    testsPassed: true,
    changedFiles: $changedFiles,
    addedLines: $addedLines,
    deletedLines: $deletedLines
  }')"

RESPONSE_FILE="$(mktemp -t agent-runner-report-result-XXXXXX.json)"
HTTP_STATUS="$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")"

RESPONSE_BODY="$(cat "$RESPONSE_FILE" 2>/dev/null || true)"
rm -f "$RESPONSE_FILE"

if [[ "$HTTP_STATUS" == "200" ]]; then
  echo "Workflow 04 finalized $JIRA_KEY -> REVIEW: $RESPONSE_BODY" >&2
  exit 0
else
  echo "Workflow 04 call failed (HTTP $HTTP_STATUS): $RESPONSE_BODY -- incident stays PR_READY, safe to retry later" >&2
  exit 1
fi
