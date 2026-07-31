#!/usr/bin/env bash
#
# Section 16 / 33.6: independently re-validate an incoming job payload
# before any repository work starts. The agent never trusts n8n's
# request just because it parsed as JSON against agent-job.schema.json
# -- structural/policy checks are re-run here, the same way
# validate-ticket-response.sh re-checked Workflow 05's response in the
# Stage 6B local runner.
#
# Usage:
#   validate-job.sh <job.json>
#
# Exit codes:
#   0  - PASS; JSON verdict on stdout
#   20 - FAIL (HUMAN_REQUIRED); JSON verdict with reason on stdout

set -euo pipefail

JOB_FILE="${1:?usage: validate-job.sh <job.json>}"

ALLOWED_SERVICES=("autofix-demo-service")
ALLOWED_ENVIRONMENTS=("local")
ALLOWED_EXCEPTION_TYPES=("java.lang.NullPointerException")
ALLOWED_REQUEST_PATHS=("/api/customers/200/display-name")

fail() {
  local reason="$1"
  jq -n --arg reason "$reason" '{result: "FAIL", category: "HUMAN_REQUIRED", reason: ("INVALID_JOB: " + $reason)}'
  exit 20
}

in_allowlist() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$needle" == "$item" ]] && return 0
  done
  return 1
}

[[ -f "$JOB_FILE" ]] || fail "job file missing"

JIRA_KEY="$(jq -r '.jiraKey // empty' "$JOB_FILE")"
[[ "$JIRA_KEY" =~ ^AUTO-[0-9]+$ ]] || fail "jiraKey does not match ^AUTO-[0-9]+\$: '$JIRA_KEY'"

INCIDENT_ID="$(jq -r '.incidentId // empty' "$JOB_FILE")"
[[ "$INCIDENT_ID" =~ ^[0-9]+$ && "$INCIDENT_ID" -gt 0 ]] || fail "incidentId is not a positive integer: '$INCIDENT_ID'"

FINGERPRINT="$(jq -r '.fingerprint // empty' "$JOB_FILE")"
[[ "$FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || fail "fingerprint is not a 64-char hex sha256"

BRANCH_NAME="$(jq -r '.branchName // empty' "$JOB_FILE")"
[[ "$BRANCH_NAME" == "autofix/$JIRA_KEY" ]] || fail "branchName '$BRANCH_NAME' does not equal autofix/$JIRA_KEY"

CONTEXT_HASH="$(jq -r '.contextHash // empty' "$JOB_FILE")"
[[ "$CONTEXT_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "contextHash is not a 64-char hex sha256"

SERVICE="$(jq -r '.ticketContext.service // empty' "$JOB_FILE")"
in_allowlist "$SERVICE" "${ALLOWED_SERVICES[@]}" || fail "unsupported service: $SERVICE"

ENVIRONMENT="$(jq -r '.ticketContext.environment // empty' "$JOB_FILE")"
in_allowlist "$ENVIRONMENT" "${ALLOWED_ENVIRONMENTS[@]}" || fail "unsupported environment: $ENVIRONMENT"

EXCEPTION_TYPE="$(jq -r '.ticketContext.exceptionType // empty' "$JOB_FILE")"
in_allowlist "$EXCEPTION_TYPE" "${ALLOWED_EXCEPTION_TYPES[@]}" || fail "unsupported exceptionType: $EXCEPTION_TYPE"

REQUEST_PATH="$(jq -r '.ticketContext.requestPath // empty' "$JOB_FILE")"
in_allowlist "$REQUEST_PATH" "${ALLOWED_REQUEST_PATHS[@]}" || fail "unsupported requestPath: $REQUEST_PATH"

STACK_TRACE="$(jq -r '.ticketContext.stackTrace // ""' "$JOB_FILE")"
[[ -n "$STACK_TRACE" ]] || fail "stackTrace is empty in ticketContext"

jq -n '{result: "PASS"}'
