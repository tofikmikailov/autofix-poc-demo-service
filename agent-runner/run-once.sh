#!/usr/bin/env bash
#
# Stage 5D: Host Agent Runner -- top-level orchestrator.
#
# Runs on the host (not in a container) because that is where Copilot
# CLI, git credentials, GitHub CLI, the repository, and the Gradle/JDK
# toolchain all live.
#
# Pipeline for a single job:
#   claim-job          AGENT_PENDING -> AGENT_RUNNING (atomic, leased)
#   prepare-worktree    isolated git worktree, deterministic branch
#   run-copilot         Copilot CLI, no git/gh/network/MCP access
#   validate-diff       independent judge (never trusts Copilot's report)
#   create-pr           commit + push + idempotent Draft PR -> PR_READY
#   report-result       notify workflow 04 -> Jira comment + REVIEW
#
# On any validation failure, the incident is written back as
# AGENT_FAILED (retryable: no changes at all) or HUMAN_REQUIRED (not
# retryable: policy/size/forbidden-construct violation, or the
# independent test run failed) -- see Stage 5I.
#
# A simple mkdir-based lock (macOS has no `flock` CLI) prevents two
# run-once.sh instances from claiming jobs concurrently on the same host;
# the database-level `FOR UPDATE SKIP LOCKED` claim is the real safety
# net if this is ever run from more than one host.
#
# Usage:
#   run-once.sh
#
# Exit codes:
#   0 - either no job was available, or a job was processed to some
#       terminal state (PR_READY/REVIEW, AGENT_FAILED, or HUMAN_REQUIRED)
#   1 - hard failure in the runner itself (git/gh/psql/lock error)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_TEMPLATE="$SCRIPT_DIR/prompts/autofix-prompt.md"

AUTOFIX_ROOT="${AUTOFIX_ROOT:-$HOME/autofix-poc}"
export AUTOFIX_ROOT
RUNTIME_ROOT="$AUTOFIX_ROOT"
LOCK_DIR="$RUNTIME_ROOT/locks/run-once.lock"
PROMPTS_DIR="$RUNTIME_ROOT/prompts"
LOGS_DIR="$RUNTIME_ROOT/logs"
RESULTS_DIR="$RUNTIME_ROOT/results"

mkdir -p "$RUNTIME_ROOT/locks" "$PROMPTS_DIR" "$LOGS_DIR" "$RESULTS_DIR" "$RUNTIME_ROOT/worktrees"

export AUTOFIX_REPO="${AUTOFIX_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export AUTOFIX_BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"
export INFRA_DIR="${INFRA_DIR:-$AUTOFIX_REPO/infrastructure}"

release_lock() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another run-once.sh instance appears to be running (lock: $LOCK_DIR)" >&2
  exit 1
fi
trap release_lock EXIT

log() { echo "[run-once] $*" >&2; }

pg_exec() {
  # $1 = SQL (heredoc-style, read via stdin so :'var' interpolation works)
  cd "$INFRA_DIR"
  local pg_user pg_db
  pg_user="$(grep '^POSTGRES_USER=' .env | cut -d= -f2)"
  pg_db="$(grep '^POSTGRES_DB=' .env | cut -d= -f2)"
  docker compose exec -T postgres psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 "$@"
}

# --- 1. Claim a job ---------------------------------------------------------
CLAIM_JSON="$(bash "$LIB_DIR/claim-job.sh")"
CLAIM_EXIT=$?
if [[ "$CLAIM_EXIT" -eq 3 ]]; then
  log "No AGENT_PENDING job available -- nothing to do"
  exit 0
elif [[ "$CLAIM_EXIT" -ne 0 ]]; then
  log "claim-job.sh failed (exit $CLAIM_EXIT)"
  exit 1
fi

INCIDENT_ID="$(jq -r '.id' <<<"$CLAIM_JSON")"
JIRA_KEY="$(jq -r '.jira_key' <<<"$CLAIM_JSON")"
BRANCH_NAME="$(jq -r '.branch_name' <<<"$CLAIM_JSON")"
EXCEPTION_TYPE="$(jq -r '.exception_type // "unknown"' <<<"$CLAIM_JSON")"
NORMALIZED_MESSAGE="$(jq -r '.normalized_exception_message // "n/a"' <<<"$CLAIM_JSON")"
APPLICATION_STACK_FRAME="$(jq -r '.application_stack_frame // "n/a"' <<<"$CLAIM_JSON")"
SAMPLE_REQUEST_PATH="$(jq -r '.sample_request_path // "n/a"' <<<"$CLAIM_JSON")"
SAMPLE_HTTP_METHOD="$(jq -r '.sample_http_method // "n/a"' <<<"$CLAIM_JSON")"
SAMPLE_CORRELATION_ID="$(jq -r '.sample_correlation_id // "n/a"' <<<"$CLAIM_JSON")"
SAMPLE_STACK_TRACE="$(jq -r '.sample_stack_trace // "n/a"' <<<"$CLAIM_JSON")"
ATTEMPT_COUNT="$(jq -r '.agent_attempt_count' <<<"$CLAIM_JSON")"

log "Claimed incident $INCIDENT_ID / $JIRA_KEY (attempt $ATTEMPT_COUNT), branch $BRANCH_NAME"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mark_incident_failed() {
  # $1 = status (AGENT_FAILED | HUMAN_REQUIRED), $2 = reason
  local status="$1" reason="$2"
  log "Marking incident $INCIDENT_ID as $status: $reason"
  pg_exec -v incident_id="$INCIDENT_ID" -v new_status="$status" -v reason="$reason" <<'SQL'
    UPDATE autofix.incident
    SET status = :'new_status',
        agent_last_error = :'reason',
        agent_completed_at = NOW(),
        agent_claimed_at = NULL,
        updated_at = NOW()
    WHERE id = :'incident_id'
    RETURNING id, status, agent_last_error;
SQL
}

# --- 2. Prepare isolated worktree --------------------------------------------
WORKTREE="$(bash "$LIB_DIR/prepare-worktree.sh" "$JIRA_KEY" "$BRANCH_NAME")"
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" ]]; then
  mark_incident_failed "AGENT_FAILED" "WORKTREE_SETUP_FAILED: could not prepare git worktree for $BRANCH_NAME"
  exit 0
fi
log "Worktree ready at $WORKTREE"

# --- 2b. Reconciliation shortcut ---------------------------------------------
# Stage 5I: "Push выполнен, но runner упал" -- if this branch already has a
# commit ahead of main (a prior attempt got as far as create-pr.sh) AND an
# open PR already exists for it, there is nothing left for Copilot to do:
# re-invoking it would find the bug already fixed and correctly report "no
# changes", which validate-diff.sh would then (wrongly, for this resumed
# case) treat as AGENT_FAILED. Detect this up front and skip straight to
# create-pr.sh, which already knows how to reuse an existing commit/PR.
RECONCILE_MODE="false"
(
  cd "$WORKTREE"
  MERGE_BASE="$(git merge-base HEAD "origin/$AUTOFIX_BASE_BRANCH" 2>/dev/null || true)"
  HEAD_SHA="$(git rev-parse HEAD)"
  [[ -n "$MERGE_BASE" && "$HEAD_SHA" != "$MERGE_BASE" ]]
) && BRANCH_AHEAD="true" || BRANCH_AHEAD="false"

if [[ "$BRANCH_AHEAD" == "true" ]] && command -v gh >/dev/null 2>&1; then
  OPEN_PR_COUNT="$(gh pr list --head "$BRANCH_NAME" --state open --json number --limit 1 2>/dev/null | jq 'length' || echo 0)"
  if [[ "$OPEN_PR_COUNT" -gt 0 ]]; then
    RECONCILE_MODE="true"
  fi
fi

VALIDATION_JSON_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-validation.json"

if [[ "$RECONCILE_MODE" == "true" ]]; then
  log "Branch $BRANCH_NAME is already ahead of main and has an open PR -- reconciling instead of re-running Copilot (Stage 5I resume)"
  (
    cd "$WORKTREE"
    STAT="$(git diff "origin/$AUTOFIX_BASE_BRANCH"...HEAD --shortstat || true)"
    CHANGED_FILES_N="$(git diff "origin/$AUTOFIX_BASE_BRANCH"...HEAD --name-only | grep -c . || true)"
    ADDED_N="$(echo "$STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    DELETED_N="$(echo "$STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)"
    jq -n --argjson changedFiles "${CHANGED_FILES_N:-0}" --argjson addedLines "${ADDED_N:-0}" --argjson deletedLines "${DELETED_N:-0}" \
      '{result:"PASS", changedFiles:$changedFiles, addedLines:$addedLines, deletedLines:$deletedLines}'
  ) > "$VALIDATION_JSON_FILE"
  cat "$VALIDATION_JSON_FILE" >&2
else

# --- 3. Render prompt and invoke Copilot CLI ---------------------------------
PROMPT_FILE="$PROMPTS_DIR/${JIRA_KEY}-${TIMESTAMP}.md"
sed \
  -e "s/{{JIRA_KEY}}/${JIRA_KEY//\//\\/}/g" \
  -e "s/{{EXCEPTION_TYPE}}/${EXCEPTION_TYPE//\//\\/}/g" \
  -e "s/{{SAMPLE_HTTP_METHOD}}/${SAMPLE_HTTP_METHOD//\//\\/}/g" \
  -e "s/{{SAMPLE_REQUEST_PATH}}/${SAMPLE_REQUEST_PATH//\//\\/}/g" \
  -e "s/{{SAMPLE_CORRELATION_ID}}/${SAMPLE_CORRELATION_ID//\//\\/}/g" \
  "$PROMPTS_TEMPLATE" > "$PROMPT_FILE"
# Multi-line fields (message/frame/stack trace) are substituted with
# python instead of sed -- they can contain '/' and newlines that would
# break a sed s/// replacement.
python3 - "$PROMPT_FILE" "$NORMALIZED_MESSAGE" "$APPLICATION_STACK_FRAME" "$SAMPLE_STACK_TRACE" <<'PYEOF'
import sys
path, message, frame, trace = sys.argv[1:5]
text = open(path).read()
text = text.replace("{{NORMALIZED_MESSAGE}}", message)
text = text.replace("{{APPLICATION_STACK_FRAME}}", frame)
text = text.replace("{{SAMPLE_STACK_TRACE}}", trace)
open(path, "w").write(text)
PYEOF

LOG_FILE="$LOGS_DIR/${JIRA_KEY}-${TIMESTAMP}-copilot.log"
bash "$LIB_DIR/run-copilot.sh" "$WORKTREE" "$PROMPT_FILE" "$LOG_FILE"
COPILOT_EXIT=$?
log "Copilot CLI finished with exit code $COPILOT_EXIT (non-fatal -- validate-diff.sh decides)"

# --- 4. Independent validation gate ------------------------------------------
VALIDATION_JSON_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-validation.json"
set +e
bash "$LIB_DIR/validate-diff.sh" "$WORKTREE" > "$VALIDATION_JSON_FILE"
VALIDATE_EXIT=$?
set -e
cat "$VALIDATION_JSON_FILE" >&2

if [[ "$VALIDATE_EXIT" -eq 10 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  mark_incident_failed "AGENT_FAILED" "$REASON"
  exit 0
elif [[ "$VALIDATE_EXIT" -eq 20 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  mark_incident_failed "HUMAN_REQUIRED" "$REASON"
  exit 0
elif [[ "$VALIDATE_EXIT" -ne 0 ]]; then
  mark_incident_failed "AGENT_FAILED" "VALIDATION_GATE_ERROR: validate-diff.sh exited $VALIDATE_EXIT unexpectedly"
  exit 0
fi

fi
# end of RECONCILE_MODE / normal-Copilot-run branch

log "Validation gate: PASS"

# --- 5. Commit, push, Draft PR -----------------------------------------------
COMMIT_MESSAGE="fix: autofix for ${EXCEPTION_TYPE} [$JIRA_KEY]"
PR_TITLE="[$JIRA_KEY] Automated fix for ${EXCEPTION_TYPE}"
PR_BODY_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-pr-body.md"
cat > "$PR_BODY_FILE" <<EOF
## Jira

$JIRA_KEY

## Root cause

$EXCEPTION_TYPE at $APPLICATION_STACK_FRAME (sample request: $SAMPLE_HTTP_METHOD $SAMPLE_REQUEST_PATH).

## Changes

- Added regression test
- Minimal production fix
- Preserved the existing public API

## Validation

- ./gradlew clean test: PASSED
- Changed files: $(jq -r '.changedFiles' "$VALIDATION_JSON_FILE")

## Safety

- No infrastructure changes
- No dependency changes
- No database changes
- Human review required
EOF

PR_JSON_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-pr.json"
set +e
bash "$LIB_DIR/create-pr.sh" "$WORKTREE" "$INCIDENT_ID" "$BRANCH_NAME" \
  "$COMMIT_MESSAGE" "$PR_TITLE" "$PR_BODY_FILE" "$VALIDATION_JSON_FILE" > "$PR_JSON_FILE"
CREATE_PR_EXIT=$?
set -e
cat "$PR_JSON_FILE" >&2

if [[ "$CREATE_PR_EXIT" -ne 0 ]]; then
  log "create-pr.sh failed (exit $CREATE_PR_EXIT) -- incident left as AGENT_RUNNING for retry"
  exit 1
fi

log "PR_READY: $(cat "$PR_JSON_FILE")"

# --- 6. Notify workflow 04 (Jira comment + REVIEW) ---------------------------
PR_NUMBER="$(jq -r '.prNumber' "$PR_JSON_FILE")"
PR_URL="$(jq -r '.prUrl' "$PR_JSON_FILE")"
COMMIT_SHA="$(jq -r '.commitSha' "$PR_JSON_FILE")"
CHANGED_FILES="$(jq -r '.changedFiles' "$PR_JSON_FILE")"
ADDED_LINES="$(jq -r '.addedLines' "$PR_JSON_FILE")"
DELETED_LINES="$(jq -r '.deletedLines' "$PR_JSON_FILE")"

set +e
bash "$LIB_DIR/report-result.sh" "$INCIDENT_ID" "$JIRA_KEY" "$BRANCH_NAME" \
  "$PR_NUMBER" "$PR_URL" "$COMMIT_SHA" "$CHANGED_FILES" "$ADDED_LINES" "$DELETED_LINES"
REPORT_EXIT=$?
set -e

if [[ "$REPORT_EXIT" -ne 0 ]]; then
  log "report-result.sh failed -- incident stays PR_READY, safe to retry (see Stage 5I)"
  exit 0
fi

log "Incident $INCIDENT_ID / $JIRA_KEY fully processed: PR #$PR_NUMBER, Jira REVIEW"
exit 0
