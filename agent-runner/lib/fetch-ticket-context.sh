#!/usr/bin/env bash
#
# Stage 6B: fetch the sanitized Jira ticket context for a claimed job via
# the local n8n webhook (Workflow 05 -- "Get AutoFix Ticket Context"),
# instead of calling Jira REST directly.
#
# This is the ONLY network call the Agent Runner makes to obtain task
# context. The Agent Runner (and Copilot CLI, which never sees this
# script at all) holds no Jira credential whatsoever -- JIRA_BASE_URL /
# JIRA_USER_EMAIL / JIRA_API_TOKEN do not exist anywhere in
# agent-runner/.env under Stage 6B. Authentication to the webhook itself
# uses a separate, non-Jira shared secret (AUTOFIX_RUNNER_WEBHOOK_TOKEN)
# that n8n compares against its own copy of the same value -- revoking or
# rotating this token never touches Jira credentials.
#
# Usage:
#   fetch-ticket-context.sh <incident-id> <jira-key> <fingerprint> \
#                            <branch-name> <output-file>
#
# Writes the raw n8n response body (success or structured error) to
# <output-file>. Like the old raw Jira response, this is a transient
# artifact under AUTOFIX_ROOT/results -- never committed to the
# repository.
#
# Exit codes:
#   0  - 200 OK; sanitized ticket context written to <output-file>
#   2  - transient error -- caller should retry with backoff:
#          503 JIRA_UNAVAILABLE (n8n reached Jira, but Jira itself is
#              slow/unreachable/rate-limited)
#          curl connection failure (n8n itself unreachable) --
#              TICKET_CONTEXT_SERVICE_UNAVAILABLE
#   3  - 401 Unauthorized -- webhook token rejected (not retryable; a
#        config/secret problem, not a Jira problem)
#   4  - 404 -- Jira issue not found (not retryable)
#   20 - 422 -- invalid/unsupported ticket context (schema, allow-list,
#        fingerprint/incidentId mismatch, ...) -- not retryable
#   1  - hard/unexpected failure (missing config, curl error, malformed
#        response, unexpected HTTP status)

set -uo pipefail

INCIDENT_ID="${1:?usage: fetch-ticket-context.sh <incident-id> <jira-key> <fingerprint> <branch-name> <output-file>}"
JIRA_KEY="${2:?missing jira-key}"
FINGERPRINT="${3:?missing fingerprint}"
BRANCH_NAME="${4:?missing branch-name}"
OUTPUT_FILE="${5:?missing output-file}"

: "${N8N_TICKET_CONTEXT_WEBHOOK_URL:?N8N_TICKET_CONTEXT_WEBHOOK_URL is required (see agent-runner/.env.example)}"
: "${AUTOFIX_RUNNER_WEBHOOK_TOKEN:?AUTOFIX_RUNNER_WEBHOOK_TOKEN is required (see agent-runner/.env.example)}"

CONNECT_TIMEOUT="${N8N_CONNECT_TIMEOUT_SECONDS:-5}"
REQUEST_TIMEOUT="${N8N_REQUEST_TIMEOUT_SECONDS:-30}"
MAX_RETRIES="${N8N_MAX_RETRIES:-3}"

REQUEST_BODY="$(jq -n \
  --argjson incidentId "$INCIDENT_ID" \
  --arg jiraKey "$JIRA_KEY" \
  --arg fingerprint "$FINGERPRINT" \
  --arg branchName "$BRANCH_NAME" \
  '{incidentId: $incidentId, jiraKey: $jiraKey, fingerprint: $fingerprint, branchName: $branchName}')"

HTTP_STATUS_FILE="$(mktemp -t fetch-ticket-context-status-XXXXXX)"
trap 'rm -f "$HTTP_STATUS_FILE"' EXIT

# --retry/--retry-all-errors/--retry-connrefused handle transient
# connection failures to n8n itself; they do not retry on 4xx/5xx HTTP
# responses that curl successfully received (those are decided below by
# HTTP_STATUS/OUTPUT_FILE content, not by curl's own exit code).
HTTP_STATUS="$(curl \
  --silent \
  --show-error \
  --connect-timeout "$CONNECT_TIMEOUT" \
  --max-time "$REQUEST_TIMEOUT" \
  --retry "$MAX_RETRIES" \
  --retry-connrefused \
  --request POST \
  --header "Content-Type: application/json" \
  --header "X-AutoFix-Runner-Token: $AUTOFIX_RUNNER_WEBHOOK_TOKEN" \
  --data "$REQUEST_BODY" \
  --output "$OUTPUT_FILE" \
  --write-out '%{http_code}' \
  "$N8N_TICKET_CONTEXT_WEBHOOK_URL" 2>/dev/null)"
CURL_EXIT=$?

if [[ "$CURL_EXIT" -ne 0 ]]; then
  echo "[fetch-ticket-context] curl failed to reach n8n webhook (exit $CURL_EXIT): TICKET_CONTEXT_SERVICE_UNAVAILABLE" >&2
  jq -n --arg msg "TICKET_CONTEXT_SERVICE_UNAVAILABLE: curl exit $CURL_EXIT reaching n8n webhook" \
    '{success: false, retryable: true, errorCode: "TICKET_CONTEXT_SERVICE_UNAVAILABLE", message: $msg}' > "$OUTPUT_FILE"
  exit 2
fi

case "$HTTP_STATUS" in
  200)
    echo "[fetch-ticket-context] $JIRA_KEY: 200 OK, sanitized context written to $OUTPUT_FILE" >&2
    exit 0
    ;;
  401)
    echo "[fetch-ticket-context] $JIRA_KEY: 401 Unauthorized -- webhook token rejected" >&2
    exit 3
    ;;
  404)
    echo "[fetch-ticket-context] $JIRA_KEY: 404 -- Jira issue not found" >&2
    exit 4
    ;;
  422)
    echo "[fetch-ticket-context] $JIRA_KEY: 422 -- invalid/unsupported ticket context" >&2
    exit 20
    ;;
  503)
    echo "[fetch-ticket-context] $JIRA_KEY: 503 -- Jira temporarily unavailable (retryable)" >&2
    exit 2
    ;;
  400)
    echo "[fetch-ticket-context] $JIRA_KEY: 400 -- request rejected by n8n as malformed (bug in caller)" >&2
    exit 1
    ;;
  *)
    echo "[fetch-ticket-context] $JIRA_KEY: unexpected HTTP status $HTTP_STATUS" >&2
    exit 1
    ;;
esac
