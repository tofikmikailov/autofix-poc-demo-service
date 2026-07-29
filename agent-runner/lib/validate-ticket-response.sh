#!/usr/bin/env bash
#
# Stage 6B: independently re-validate the sanitized ticket context
# returned by n8n Workflow 05 before Copilot CLI is ever invoked.
#
# The Agent Runner never blindly trusts n8n's response just because it
# came back with HTTP 200 -- this is the second independent judge in the
# pipeline (the first being validate-diff.sh for the resulting code
# change, later renumbered as the third once this gate is added). It
# re-checks the same allow-list Workflow 03's Policy Gate already applied
# (defense in depth: Jira or the ticket may have changed between Workflow
# 03's decision and this fetch) plus structural/provenance checks that
# only the Agent Runner -- holder of the claimed job's expected
# incidentId/jiraKey/fingerprint -- can perform.
#
# Usage:
#   validate-ticket-response.sh <ticket-context.json> <incident-id> \
#                                <expected-jira-key> <expected-fingerprint>
#
# Exit codes:
#   0  - PASS; JSON verdict on stdout
#   20 - FAIL (HUMAN_REQUIRED); JSON verdict with reason on stdout --
#        every failure here is permanent/non-retryable: a malformed or
#        policy-ineligible ticket will not fix itself on retry.

set -euo pipefail

CONTEXT_FILE="${1:?usage: validate-ticket-response.sh <ticket-context.json> <incident-id> <expected-jira-key> <expected-fingerprint>}"
INCIDENT_ID="${2:?missing incident-id}"
EXPECTED_JIRA_KEY="${3:?missing expected-jira-key}"
EXPECTED_FINGERPRINT="${4:?missing expected-fingerprint}"

# Stage 6B Section 14: same allow-list as n8n Workflow 05 applied
# server-side -- deliberately duplicated here rather than trusted blindly,
# and deliberately narrow/hard-coded for the first POC.
ALLOWED_SERVICES=("autofix-demo-service")
ALLOWED_ENVIRONMENTS=("local")
ALLOWED_EXCEPTION_TYPES=("java.lang.NullPointerException")
ALLOWED_REQUEST_PATHS=("/api/customers/200/display-name")
CLOSED_STATUSES=("Done" "Closed" "Cancelled")
REQUIRED_LABELS=("auto-generated" "autofix-candidate")

fail() {
  local reason="$1"
  jq -n --arg reason "$reason" '{result: "FAIL", category: "HUMAN_REQUIRED", reason: ("INVALID_JIRA_CONTEXT: " + $reason)}'
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

if [[ ! -f "$CONTEXT_FILE" ]]; then
  fail "ticket context response file missing"
fi

# --- 0. Response envelope -----------------------------------------------
SCHEMA_VERSION="$(jq -r '.schemaVersion // empty' "$CONTEXT_FILE")"
if [[ "$SCHEMA_VERSION" != "1" ]]; then
  fail "unsupported schemaVersion: '$SCHEMA_VERSION' (expected 1)"
fi

SOURCE="$(jq -r '.source // empty' "$CONTEXT_FILE")"
if [[ "$SOURCE" != "JIRA_VIA_N8N" ]]; then
  fail "unexpected source: '$SOURCE' (expected JIRA_VIA_N8N)"
fi

# --- 1. Jira key matches the claimed job ---------------------------------
JIRA_KEY="$(jq -r '.ticket.key // empty' "$CONTEXT_FILE")"
if [[ "$JIRA_KEY" != "$EXPECTED_JIRA_KEY" ]]; then
  fail "jira key mismatch: response has '$JIRA_KEY', expected '$EXPECTED_JIRA_KEY'"
fi

PROJECT_KEY="$(jq -r '.ticket.projectKey // empty' "$CONTEXT_FILE")"
if [[ "$PROJECT_KEY" != "AUTO" ]]; then
  fail "unsupported project: $PROJECT_KEY (expected AUTO)"
fi

STATUS="$(jq -r '.ticket.status // empty' "$CONTEXT_FILE")"
for closed in "${CLOSED_STATUSES[@]}"; do
  if [[ "$STATUS" == "$closed" ]]; then
    fail "ticket status is '$STATUS' (closed tickets are not eligible)"
  fi
done

LABELS_JSON="$(jq -c '.ticket.labels // []' "$CONTEXT_FILE")"
for label in "${REQUIRED_LABELS[@]}"; do
  if ! jq -e --arg l "$label" '. as $labels | ($labels | index($l)) != null' <<<"$LABELS_JSON" >/dev/null; then
    fail "required label missing: $label"
  fi
done

FINGERPRINT_LABEL="$(jq -r '.[] | select(startswith("autofix-fp-"))' <<<"$LABELS_JSON" | head -n1)"
if [[ -z "$FINGERPRINT_LABEL" ]]; then
  fail "fingerprint label missing (expected autofix-fp-<sha256>)"
fi

# --- 2. incidentId / fingerprint / branch cross-check ---------------------
CONTEXT_INCIDENT_ID="$(jq -r '.incident.incidentId // empty' "$CONTEXT_FILE")"
if [[ "$CONTEXT_INCIDENT_ID" != "$INCIDENT_ID" ]]; then
  fail "incidentId mismatch: response has $CONTEXT_INCIDENT_ID, PostgreSQL claimed $INCIDENT_ID"
fi

CONTEXT_FINGERPRINT="$(jq -r '.incident.fingerprint // empty' "$CONTEXT_FILE")"
if [[ "$CONTEXT_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]]; then
  fail "fingerprint mismatch: response has $CONTEXT_FINGERPRINT, PostgreSQL has $EXPECTED_FINGERPRINT"
fi

FP_LABEL_SUFFIX="${FINGERPRINT_LABEL#autofix-fp-}"
if [[ "$FP_LABEL_SUFFIX" != "$EXPECTED_FINGERPRINT" ]]; then
  fail "fingerprint label ($FINGERPRINT_LABEL) does not match expected fingerprint $EXPECTED_FINGERPRINT"
fi

# --- 3. contextHash format --------------------------------------------------
CONTEXT_HASH="$(jq -r '.contextHash // empty' "$CONTEXT_FILE")"
if ! [[ "$CONTEXT_HASH" =~ ^[0-9a-f]{64}$ ]]; then
  fail "contextHash missing or not a 64-char hex SHA-256 digest"
fi

# --- 4. Policy allow-list (defense in depth) --------------------------------
SERVICE="$(jq -r '.incident.service // empty' "$CONTEXT_FILE")"
ENVIRONMENT="$(jq -r '.incident.environment // empty' "$CONTEXT_FILE")"
EXCEPTION_TYPE="$(jq -r '.incident.exceptionType // empty' "$CONTEXT_FILE")"
REQUEST_PATH="$(jq -r '.incident.requestPath // empty' "$CONTEXT_FILE")"
STACK_TRACE="$(jq -r '.incident.stackTrace // ""' "$CONTEXT_FILE")"

if ! in_allowlist "$SERVICE" "${ALLOWED_SERVICES[@]}"; then
  fail "unsupported service: $SERVICE"
fi
if ! in_allowlist "$ENVIRONMENT" "${ALLOWED_ENVIRONMENTS[@]}"; then
  fail "unsupported environment: $ENVIRONMENT"
fi
if ! in_allowlist "$EXCEPTION_TYPE" "${ALLOWED_EXCEPTION_TYPES[@]}"; then
  fail "unsupported exceptionType: $EXCEPTION_TYPE"
fi
if ! in_allowlist "$REQUEST_PATH" "${ALLOWED_REQUEST_PATHS[@]}"; then
  fail "unsupported requestPath: $REQUEST_PATH"
fi

# --- 5. Regression-test material must exist ---------------------------------
if [[ -z "$STACK_TRACE" ]]; then
  fail "stackTrace is empty in ticket context"
fi

jq -n '{result: "PASS"}'
exit 0
