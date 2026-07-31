#!/usr/bin/env bash
#
# Section 12: the containerized replacement for run-once.sh. Orchestrates
# a single job end-to-end: validate -> workspace -> clone -> branch ->
# (early PR short-circuit) -> prompt -> Copilot -> Validation Gate ->
# commit -> PR -> callback -> cleanup.
#
# Invoked by server.py as a detached subprocess, never directly by a
# human (though it can be run manually with a hand-built job.json for
# the Phase 3 "manual curl test").
#
# Usage:
#   execute-job.sh <job.json> <result.json>
#
# <result.json> is written by this script on exit (success or failure)
# so server.py can serve it back via GET /api/jobs/{jobId} without
# re-parsing logs. Exit code mirrors the outcome:
#   0  - PR_READY
#   10 - AGENT_FAILED (retryable, per jobId attempt number, by n8n)
#   20 - HUMAN_REQUIRED (terminal)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

JOB_FILE="${1:?usage: execute-job.sh <job.json> <result.json>}"
RESULT_FILE="${2:?missing result.json output path}"

JOB_ID="$(jq -r '.jobId' "$JOB_FILE")"
JIRA_KEY="$(jq -r '.jiraKey' "$JOB_FILE")"
INCIDENT_ID="$(jq -r '.incidentId' "$JOB_FILE")"
CONTEXT_HASH="$(jq -r '.contextHash' "$JOB_FILE")"
BRANCH_NAME="$(jq -r '.branchName' "$JOB_FILE")"

LOG_DIR="/workspace/logs/$JOB_ID"
mkdir -p "$LOG_DIR"
MAIN_LOG="$LOG_DIR/execute-job.log"
exec > >(tee -a "$MAIN_LOG") 2>&1

echo "=== [$JOB_ID] execute-job.sh starting for $JIRA_KEY (incident $INCIDENT_ID) ==="

write_result() {
  local status="$1"
  jq -n \
    --arg status "$status" \
    --arg jobId "$JOB_ID" \
    --arg jiraKey "$JIRA_KEY" \
    --argjson incidentId "$INCIDENT_ID" \
    --arg contextHash "$CONTEXT_HASH" \
    --arg errorCode "${2:-}" \
    --arg errorMessage "${3:-}" \
    --arg prUrl "${4:-}" \
    --argjson prNumber "${5:-null}" \
    --arg commitSha "${6:-}" \
    --argjson changedFiles "${7:-null}" \
    --argjson addedLines "${8:-null}" \
    --argjson deletedLines "${9:-null}" \
    --arg finishedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      status: $status, jobId: $jobId, jiraKey: $jiraKey,
      incidentId: $incidentId, contextHash: $contextHash,
      errorCode: $errorCode, errorMessage: $errorMessage,
      prUrl: $prUrl, prNumber: $prNumber, commitSha: $commitSha,
      changedFiles: $changedFiles, addedLines: $addedLines,
      deletedLines: $deletedLines, finishedAt: $finishedAt
    }' > "$RESULT_FILE"
}

fail_and_exit() {
  local status="$1" code="$2" message="$3" exit_code="$4"
  echo "[$JOB_ID] FAIL ($status): $code -- $message"
  write_result "$status" "$code" "$message"
  "$LIB_DIR/send-result.sh" "$status" "$JOB_ID" "$JIRA_KEY" "$INCIDENT_ID" "$CONTEXT_HASH" \
    null "" "" null null null "$code" "$message" || true
  "$LIB_DIR/cleanup-workspace.sh" --keep-logs || true
  exit "$exit_code"
}

# --- Step 1: validate job -------------------------------------------------
VALIDATE_OUT="$("$LIB_DIR/validate-job.sh" "$JOB_FILE")"
VALIDATE_RC=$?
if [[ "$VALIDATE_RC" -ne 0 ]]; then
  REASON="$(echo "$VALIDATE_OUT" | jq -r '.reason // "INVALID_JOB"')"
  fail_and_exit "HUMAN_REQUIRED" "INVALID_JOB" "$REASON" 20
fi
echo "[$JOB_ID] validate-job: PASS"

# --- Step 2: prepare workspace --------------------------------------------
WORKSPACE_DIR="$("$LIB_DIR/prepare-workspace.sh")"
echo "[$JOB_ID] workspace: $WORKSPACE_DIR"

# --- Step 3: clone repository ----------------------------------------------
if ! REPO_DIR="$("$LIB_DIR/clone-repository.sh" "$WORKSPACE_DIR")"; then
  fail_and_exit "AGENT_FAILED" "CLONE_FAILED" "git clone of AUTOFIX_REPOSITORY_URL failed" 10
fi
echo "[$JOB_ID] repository: $REPO_DIR"

# --- Step 4: prepare branch --------------------------------------------
BRANCH_STATE="$("$LIB_DIR/prepare-branch.sh" "$REPO_DIR" "$BRANCH_NAME")"
if [[ $? -ne 0 ]]; then
  fail_and_exit "AGENT_FAILED" "BRANCH_FAILED" "could not checkout/create branch $BRANCH_NAME" 10
fi
echo "[$JOB_ID] branch state: $BRANCH_STATE"

# --- Step 5: early PR short-circuit --------------------------------------
if [[ "$BRANCH_STATE" == "existing" ]]; then
  EXISTING="$("$LIB_DIR/check-existing-pr.sh" "$REPO_DIR" "$BRANCH_NAME")"
  EXISTS="$(echo "$EXISTING" | jq -r '.exists')"
  if [[ "$EXISTS" == "true" ]]; then
    PR_NUMBER="$(echo "$EXISTING" | jq -r '.number')"
    PR_URL="$(echo "$EXISTING" | jq -r '.url')"
    echo "[$JOB_ID] existing PR #$PR_NUMBER found for $BRANCH_NAME -- skipping Copilot entirely"
    write_result "PR_READY" "" "" "$PR_URL" "$PR_NUMBER" "$(cd "$REPO_DIR" && git rev-parse HEAD)" 0 0 0
    "$LIB_DIR/send-result.sh" "PR_READY" "$JOB_ID" "$JIRA_KEY" "$INCIDENT_ID" "$CONTEXT_HASH" \
      "$PR_NUMBER" "$PR_URL" "$(cd "$REPO_DIR" && git rev-parse HEAD)" 0 0 0 || true
    "$LIB_DIR/cleanup-workspace.sh" || true
    exit 0
  fi
fi

# --- Step 6: build Copilot prompt ------------------------------------------
PROMPT_FILE="$WORKSPACE_DIR/prompt.md"
if ! "$LIB_DIR/build-agent-prompt.sh" "$JOB_FILE" "$SCRIPT_DIR/prompts/autofix-prompt.md" "$PROMPT_FILE"; then
  fail_and_exit "AGENT_FAILED" "PROMPT_BUILD_FAILED" "failed to render Copilot prompt from job/template" 10
fi

# --- Step 7: run Copilot ----------------------------------------------------
COPILOT_LOG="$LOG_DIR/copilot.log"
"$LIB_DIR/run-copilot.sh" "$REPO_DIR" "$PROMPT_FILE" "$COPILOT_LOG"
COPILOT_EXIT=$?
echo "[$JOB_ID] copilot exit code: $COPILOT_EXIT (log: $COPILOT_LOG)"

# --- Step 8: Validation Gate ------------------------------------------------
VALIDATION_JSON_FILE="$WORKSPACE_DIR/validation-result.json"
"$LIB_DIR/validate-diff.sh" "$REPO_DIR" > "$VALIDATION_JSON_FILE"
VALIDATION_EXIT=$?
VALIDATION_RESULT="$(jq -r '.result' "$VALIDATION_JSON_FILE")"

if [[ "$VALIDATION_EXIT" -eq 10 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  fail_and_exit "AGENT_FAILED" "AGENT_FAILED" "$REASON" 10
elif [[ "$VALIDATION_EXIT" -eq 20 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  ERROR_CODE="POLICY_VIOLATION"
  [[ "$REASON" == TESTS_FAILED:* ]] && ERROR_CODE="TESTS_FAILED"
  fail_and_exit "HUMAN_REQUIRED" "$ERROR_CODE" "$REASON" 20
elif [[ "$VALIDATION_EXIT" -ne 0 ]]; then
  fail_and_exit "AGENT_FAILED" "VALIDATION_GATE_ERROR" "validate-diff.sh exited $VALIDATION_EXIT unexpectedly" 10
fi
echo "[$JOB_ID] validate-diff: PASS"

CHANGED_FILES="$(jq -r '.changedFiles' "$VALIDATION_JSON_FILE")"
ADDED_LINES="$(jq -r '.addedLines' "$VALIDATION_JSON_FILE")"
DELETED_LINES="$(jq -r '.deletedLines' "$VALIDATION_JSON_FILE")"

# --- Step 9: commit + push --------------------------------------------------
COMMIT_MESSAGE="fix(${JIRA_KEY}): AutoFix agent remediation

Automated fix generated by the AutoFix agent container in response to
$JIRA_KEY. See the linked Draft PR description for validation details.

Co-authored-by: AutoFix Bot <autofix-bot@users.noreply.github.com>"

COMMIT_SHA="$("$LIB_DIR/create-commit.sh" "$REPO_DIR" "$BRANCH_NAME" "$COMMIT_MESSAGE" "$VALIDATION_JSON_FILE")"
if [[ $? -ne 0 || -z "$COMMIT_SHA" ]]; then
  fail_and_exit "AGENT_FAILED" "COMMIT_FAILED" "create-commit.sh failed to produce/push a commit" 10
fi
echo "[$JOB_ID] commit: $COMMIT_SHA"

# --- Step 10: PR body + create/reuse PR -------------------------------------
PR_BODY_FILE="$WORKSPACE_DIR/pr-body.md"
cat > "$PR_BODY_FILE" <<EOF
## AutoFix: $JIRA_KEY

Automated remediation produced by the AutoFix agent container.

- **Jira ticket:** $JIRA_KEY
- **Job ID:** $JOB_ID
- **Changed files:** $CHANGED_FILES
- **Added / deleted lines:** +$ADDED_LINES / -$DELETED_LINES
- **Independent Validation Gate:** PASS (see \`./gradlew clean test\` in CI/log)

This PR was opened as a **Draft** and requires human review before merge.
EOF

PR_RESULT="$("$LIB_DIR/find-or-create-pr.sh" "$REPO_DIR" "$BRANCH_NAME" "AutoFix: $JIRA_KEY" "$PR_BODY_FILE")"
if [[ $? -ne 0 ]]; then
  fail_and_exit "AGENT_FAILED" "PR_CREATE_FAILED" "find-or-create-pr.sh failed to create/reuse the PR" 10
fi
PR_NUMBER="$(echo "$PR_RESULT" | jq -r '.prNumber')"
PR_URL="$(echo "$PR_RESULT" | jq -r '.prUrl')"
echo "[$JOB_ID] PR: #$PR_NUMBER $PR_URL"

# --- Step 11: report result + cleanup ---------------------------------------
write_result "PR_READY" "" "" "$PR_URL" "$PR_NUMBER" "$COMMIT_SHA" "$CHANGED_FILES" "$ADDED_LINES" "$DELETED_LINES"
"$LIB_DIR/send-result.sh" "PR_READY" "$JOB_ID" "$JIRA_KEY" "$INCIDENT_ID" "$CONTEXT_HASH" \
  "$PR_NUMBER" "$PR_URL" "$COMMIT_SHA" "$CHANGED_FILES" "$ADDED_LINES" "$DELETED_LINES" || true

"$LIB_DIR/cleanup-workspace.sh" || true

echo "=== [$JOB_ID] execute-job.sh finished: PR_READY (#$PR_NUMBER) ==="
exit 0
