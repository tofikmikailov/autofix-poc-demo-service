#!/usr/bin/env bash
#
# Stage 6: validate the parsed Jira context before Copilot CLI is ever
# invoked. This is the second independent judge in the pipeline (the
# first being validate-diff.sh for the resulting code change): it never
# trusts that a ticket picked up by Workflow 03's Policy Gate is still
# safe to act on -- Jira may have changed since, or the ticket may simply
# not carry a well-formed AutoFix context.
#
# Usage:
#   validate-jira-context.sh <parsed-context.json> <incident-id> \
#                             <expected-jira-key> <expected-fingerprint>
#
# Exit codes:
#   0  - PASS; JSON verdict on stdout
#   20 - FAIL (HUMAN_REQUIRED); JSON verdict with reason on stdout --
#        every failure here is permanent/non-retryable: a malformed or
#        policy-ineligible ticket will not fix itself on retry.

set -euo pipefail

CONTEXT_FILE="${1:?usage: validate-jira-context.sh <parsed-context.json> <incident-id> <expected-jira-key> <expected-fingerprint>}"
INCIDENT_ID="${2:?missing incident-id}"
EXPECTED_JIRA_KEY="${3:?missing expected-jira-key}"
EXPECTED_FINGERPRINT="${4:?missing expected-fingerprint}"

# Stage 6 Section 13.2: allow-list for the first POC. Deliberately
# narrow and hard-coded -- widening this is a conscious policy decision,
# not a config toggle.
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
  fail "parsed context file missing"
fi

JIRA_KEY="$(jq -r '.key' "$CONTEXT_FILE")"
STATUS="$(jq -r '.status' "$CONTEXT_FILE")"
LABELS_JSON="$(jq -c '.labels' "$CONTEXT_FILE")"
AUTOFIX_CONTEXT="$(jq -c '.autofixContext' "$CONTEXT_FILE")"
AUTOFIX_CONTEXT_ERROR="$(jq -r '.autofixContextError // empty' "$CONTEXT_FILE")"

# --- 1. Jira key matches the claimed job ---------------------------------
if [[ "$JIRA_KEY" != "$EXPECTED_JIRA_KEY" ]]; then
  fail "jira key mismatch: fetched '$JIRA_KEY', expected '$EXPECTED_JIRA_KEY'"
fi

# --- 2. Project key ---------------------------------------------------------
PROJECT_KEY="$(jq -r '.projectKey' "$CONTEXT_FILE")"
if [[ "$PROJECT_KEY" != "AUTO" ]]; then
  fail "unsupported project: $PROJECT_KEY (expected AUTO)"
fi

# --- 3. Ticket not closed ----------------------------------------------------
for closed in "${CLOSED_STATUSES[@]}"; do
  if [[ "$STATUS" == "$closed" ]]; then
    fail "ticket status is '$STATUS' (closed tickets are not eligible)"
  fi
done

# --- 4. Required labels ------------------------------------------------------
for label in "${REQUIRED_LABELS[@]}"; do
  if ! jq -e --arg l "$label" '. as $labels | ($labels | index($l)) != null' <<<"$LABELS_JSON" >/dev/null; then
    fail "required label missing: $label"
  fi
done

FINGERPRINT_LABEL="$(jq -r '.[] | select(startswith("autofix-fp-"))' <<<"$LABELS_JSON" | head -n1)"
if [[ -z "$FINGERPRINT_LABEL" ]]; then
  fail "fingerprint label missing (expected autofix-fp-<sha256>)"
fi

# --- 5. AUTOFIX_CONTEXT_V1 block present and well-formed ---------------------
if [[ -n "$AUTOFIX_CONTEXT_ERROR" ]]; then
  fail "$AUTOFIX_CONTEXT_ERROR"
fi
if [[ "$AUTOFIX_CONTEXT" == "null" ]]; then
  fail "AUTOFIX_CONTEXT_V1 block missing from description"
fi

SCHEMA_VERSION="$(jq -r '.schemaVersion' <<<"$AUTOFIX_CONTEXT")"
if [[ "$SCHEMA_VERSION" != "1" ]]; then
  fail "unsupported schema version: $SCHEMA_VERSION (expected 1)"
fi

# --- 6. incidentId / fingerprint match PostgreSQL -----------------------------
CONTEXT_INCIDENT_ID="$(jq -r '.incidentId' <<<"$AUTOFIX_CONTEXT")"
if [[ "$CONTEXT_INCIDENT_ID" != "$INCIDENT_ID" ]]; then
  fail "incidentId mismatch: Jira context has $CONTEXT_INCIDENT_ID, PostgreSQL claimed $INCIDENT_ID"
fi

CONTEXT_FINGERPRINT="$(jq -r '.fingerprint' <<<"$AUTOFIX_CONTEXT")"
if [[ "$CONTEXT_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]]; then
  fail "fingerprint mismatch: Jira context has $CONTEXT_FINGERPRINT, PostgreSQL has $EXPECTED_FINGERPRINT"
fi

FP_LABEL_SUFFIX="${FINGERPRINT_LABEL#autofix-fp-}"
if [[ "$FP_LABEL_SUFFIX" != "$EXPECTED_FINGERPRINT" ]]; then
  fail "fingerprint label ($FINGERPRINT_LABEL) does not match expected fingerprint $EXPECTED_FINGERPRINT"
fi

# --- 7. Policy allow-list ------------------------------------------------------
SERVICE="$(jq -r '.service' <<<"$AUTOFIX_CONTEXT")"
ENVIRONMENT="$(jq -r '.environment' <<<"$AUTOFIX_CONTEXT")"
EXCEPTION_TYPE="$(jq -r '.exceptionType' <<<"$AUTOFIX_CONTEXT")"
REQUEST_PATH="$(jq -r '.requestPath' <<<"$AUTOFIX_CONTEXT")"
STACK_TRACE="$(jq -r '.stackTrace // ""' <<<"$AUTOFIX_CONTEXT")"

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
if [[ -z "$STACK_TRACE" ]]; then
  fail "stackTrace is empty in AUTOFIX_CONTEXT_V1"
fi

jq -n '{result: "PASS"}'
exit 0
