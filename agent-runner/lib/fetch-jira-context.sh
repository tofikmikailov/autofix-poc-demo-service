#!/usr/bin/env bash
#
# Stage 6: fetch the live Jira issue for a given key via the Jira Cloud
# REST API, using a dedicated *read-only* credential
# (JIRA_USER_EMAIL/JIRA_API_TOKEN from agent-runner/.env). This is the
# only place in the Agent Runner that talks to Jira -- Copilot CLI never
# sees these credentials and never calls Jira itself.
#
# Usage:
#   fetch-jira-context.sh <jira-key> <output-file>
#
# Writes the raw Jira issue JSON (fields: summary, description, labels,
# status, issuetype, project, priority, comment, updated) to
# <output-file>. The raw response is a transient artifact under
# AUTOFIX_ROOT/results -- it must never be committed to the repository.
#
# Exit codes:
#   0  - fetched successfully, raw JSON written to <output-file>
#   2  - transient error (timeout, 429, 5xx) -- caller should retry with
#        backoff (see mark-incident-failed.sh RETRY)
#   3  - authentication error (401/403) -- not retryable
#   4  - issue not found (404) -- not retryable
#   1  - hard/unexpected failure (missing config, curl error, ...)

set -uo pipefail

JIRA_KEY="${1:?usage: fetch-jira-context.sh <jira-key> <output-file>}"
OUTPUT_FILE="${2:?missing output-file}"

: "${JIRA_BASE_URL:?JIRA_BASE_URL is required (see agent-runner/.env.example)}"
: "${JIRA_USER_EMAIL:?JIRA_USER_EMAIL is required (see agent-runner/.env.example)}"
: "${JIRA_API_TOKEN:?JIRA_API_TOKEN is required (see agent-runner/.env.example)}"

CONNECT_TIMEOUT="${JIRA_CONNECT_TIMEOUT_SECONDS:-5}"
REQUEST_TIMEOUT="${JIRA_REQUEST_TIMEOUT_SECONDS:-20}"
MAX_RETRIES="${JIRA_MAX_RETRIES:-3}"

FIELDS="summary,description,labels,status,issuetype,project,priority,comment,updated"
URL="${JIRA_BASE_URL%/}/rest/api/3/issue/${JIRA_KEY}?fields=${FIELDS}"

HTTP_STATUS_FILE="$(mktemp -t fetch-jira-context-status-XXXXXX)"
trap 'rm -f "$HTTP_STATUS_FILE"' EXIT

# --fail-with-body would make curl exit non-zero on 4xx/5xx while still
# writing the response body to -o, but its exit code does not distinguish
# *which* HTTP status occurred -- capture that separately with -w.
HTTP_STATUS="$(curl \
  --silent \
  --show-error \
  --connect-timeout "$CONNECT_TIMEOUT" \
  --max-time "$REQUEST_TIMEOUT" \
  --retry "$MAX_RETRIES" \
  --retry-all-errors \
  --retry-connrefused \
  --user "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
  --header "Accept: application/json" \
  --output "$OUTPUT_FILE" \
  --write-out '%{http_code}' \
  "$URL" 2>/dev/null)"
CURL_EXIT=$?

if [[ "$CURL_EXIT" -ne 0 ]]; then
  echo "[fetch-jira-context] $JIRA_KEY: curl failed (exit $CURL_EXIT) -- treating as transient" >&2
  exit 2
fi

echo "[fetch-jira-context] $JIRA_KEY: HTTP $HTTP_STATUS" >&2

case "$HTTP_STATUS" in
  200)
    exit 0
    ;;
  401|403)
    echo "[fetch-jira-context] $JIRA_KEY: authentication failed (HTTP $HTTP_STATUS)" >&2
    exit 3
    ;;
  404)
    echo "[fetch-jira-context] $JIRA_KEY: issue not found (HTTP $HTTP_STATUS)" >&2
    exit 4
    ;;
  429|500|502|503|504)
    echo "[fetch-jira-context] $JIRA_KEY: transient Jira error (HTTP $HTTP_STATUS)" >&2
    exit 2
    ;;
  *)
    echo "[fetch-jira-context] $JIRA_KEY: unexpected HTTP status $HTTP_STATUS" >&2
    exit 1
    ;;
esac
