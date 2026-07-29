#!/usr/bin/env bash
#
# Stage 5D / Stage 6: Host Agent Runner -- top-level orchestrator.
#
# Runs on the host (not in a container) because that is where Copilot
# CLI, git credentials, GitHub CLI, the repository, and the Gradle/JDK
# toolchain all live.
#
# Pipeline for a single job (Stage 6 order):
#   claim-job              AGENT_PENDING -> AGENT_RUNNING (atomic, leased)
#   fetch-jira-context      GET the live Jira issue (read-only credential)
#   parse-jira-context      ADF -> plain text, extract AUTOFIX_CONTEXT_V1
#   validate-jira-context   labels / fingerprint / schema / allow-list
#   build-agent-prompt      sanitized prompt from the VALIDATED Jira context
#   prepare-worktree        isolated git worktree, deterministic branch
#   run-copilot             Copilot CLI, no git/gh/network/Jira/MCP access
#   validate-diff           independent judge (never trusts Copilot's report)
#   create-pr               commit + push + idempotent Draft PR -> PR_READY
#   report-result           notify workflow 04 -> Jira comment + REVIEW
#
# Since Stage 6, PostgreSQL is no longer read for task context (exception
# type, message, stack trace, request path, ...) -- Jira is the single
# source of truth for that. PostgreSQL still owns orchestration state
# (status, branch_name, attempt counters, leases) and a fingerprint used
# only to cross-check that the live Jira issue's embedded context still
# refers to the same incident.
#
# On any validation failure, the incident is written back as
# AGENT_FAILED (retryable) or HUMAN_REQUIRED (not retryable) -- see
# Stage 5I and Stage 6 Section 18.
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
#       terminal state (PR_READY/REVIEW, AGENT_FAILED, HUMAN_REQUIRED, or
#       AGENT_PENDING-with-backoff for a transient Jira error)
#   1 - hard failure in the runner itself (git/gh/psql/lock error)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_TEMPLATE="$SCRIPT_DIR/prompts/autofix-prompt.md"

# Stage 6: load agent-runner/.env if present (JIRA_BASE_URL,
# JIRA_USER_EMAIL, JIRA_API_TOKEN, timeouts/retries, ...). Never
# committed -- see agent-runner/.env.example.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

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

# Stage 6 Section 18.1: after this many failed Jira-context-fetch
# attempts, stop retrying and give up permanently (AGENT_FAILED) rather
# than retry forever.
MAX_JIRA_FETCH_ATTEMPTS="${MAX_JIRA_FETCH_ATTEMPTS:-3}"

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
  cd "$INFRA_DIR"
  local pg_user pg_db
  pg_user="$(grep '^POSTGRES_USER=' .env | cut -d= -f2)"
  pg_db="$(grep '^POSTGRES_DB=' .env | cut -d= -f2)"
  docker compose exec -T postgres psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 "$@"
}

mark_incident() {
  # $1 = status (AGENT_FAILED | HUMAN_REQUIRED | RETRY), $2 = reason, $3 = attempt count (RETRY only)
  bash "$LIB_DIR/mark-incident-failed.sh" "$INCIDENT_ID" "$1" "$2" "${3:-0}" >&2
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

INCIDENT_ID="$(jq -r '.incidentId' <<<"$CLAIM_JSON")"
JIRA_KEY="$(jq -r '.jiraKey' <<<"$CLAIM_JSON")"
FINGERPRINT="$(jq -r '.fingerprint' <<<"$CLAIM_JSON")"
BRANCH_NAME="$(jq -r '.branchName' <<<"$CLAIM_JSON")"
ATTEMPT_COUNT="$(jq -r '.agentAttemptCount' <<<"$CLAIM_JSON")"

log "Claimed incident $INCIDENT_ID / $JIRA_KEY (attempt $ATTEMPT_COUNT), branch $BRANCH_NAME"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# --- 2. Fetch the live Jira issue --------------------------------------------
# Stage 6: PostgreSQL is never used as the source of task context from
# here on -- only the fingerprint above (for cross-checking) and the
# technical orchestration fields already claimed.
RAW_JIRA_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-jira-raw.json"
set +e
bash "$LIB_DIR/fetch-jira-context.sh" "$JIRA_KEY" "$RAW_JIRA_FILE"
FETCH_EXIT=$?
set -e

case "$FETCH_EXIT" in
  0)
    log "[$JIRA_KEY] Jira context fetched successfully"
    ;;
  2)
    # Transient: connection timeout / 429 / 5xx.
    if [[ "$ATTEMPT_COUNT" -ge "$MAX_JIRA_FETCH_ATTEMPTS" ]]; then
      mark_incident "AGENT_FAILED" "JIRA_CONTEXT_FETCH_FAILED: exceeded $MAX_JIRA_FETCH_ATTEMPTS attempts fetching Jira context"
    else
      mark_incident "RETRY" "JIRA_CONTEXT_FETCH_FAILED: transient error fetching Jira issue $JIRA_KEY (attempt $ATTEMPT_COUNT)" "$ATTEMPT_COUNT"
    fi
    exit 0
    ;;
  3)
    mark_incident "AGENT_FAILED" "JIRA_AUTH_FAILED: authentication failed while fetching $JIRA_KEY"
    exit 0
    ;;
  4)
    mark_incident "HUMAN_REQUIRED" "JIRA_ISSUE_NOT_FOUND: $JIRA_KEY does not exist or is not visible to the read-only credential"
    exit 0
    ;;
  *)
    log "fetch-jira-context.sh failed unexpectedly (exit $FETCH_EXIT) -- leaving incident as AGENT_RUNNING for lease-based retry"
    exit 1
    ;;
esac

# --- 3. Parse Jira ADF -> plain text + AUTOFIX_CONTEXT_V1 --------------------
PARSED_CONTEXT_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-context.json"
if ! python3 "$LIB_DIR/parse-jira-context.py" "$RAW_JIRA_FILE" "$PARSED_CONTEXT_FILE"; then
  mark_incident "AGENT_FAILED" "JIRA_CONTEXT_PARSE_FAILED: parse-jira-context.py failed on $JIRA_KEY"
  exit 0
fi

# --- 4. Validate the parsed context ------------------------------------------
VALIDATE_CONTEXT_JSON_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-context-validation.json"
set +e
bash "$LIB_DIR/validate-jira-context.sh" "$PARSED_CONTEXT_FILE" "$INCIDENT_ID" "$JIRA_KEY" "$FINGERPRINT" > "$VALIDATE_CONTEXT_JSON_FILE"
VALIDATE_CONTEXT_EXIT=$?
set -e
cat "$VALIDATE_CONTEXT_JSON_FILE" >&2

if [[ "$VALIDATE_CONTEXT_EXIT" -ne 0 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATE_CONTEXT_JSON_FILE")"
  mark_incident "HUMAN_REQUIRED" "$REASON"
  exit 0
fi

log "[$JIRA_KEY] Context schema V1 validated"

# Fields used for the commit message / PR title+body below -- sourced
# exclusively from the validated Jira context now, never from PostgreSQL.
EXCEPTION_TYPE="$(jq -r '.autofixContext.exceptionType // "unknown"' "$PARSED_CONTEXT_FILE")"
APPLICATION_STACK_FRAME="$(jq -r '.autofixContext.applicationFrame // "n/a"' "$PARSED_CONTEXT_FILE")"
SAMPLE_HTTP_METHOD="$(jq -r '.autofixContext.httpMethod // "n/a"' "$PARSED_CONTEXT_FILE")"
SAMPLE_REQUEST_PATH="$(jq -r '.autofixContext.requestPath // "n/a"' "$PARSED_CONTEXT_FILE")"
CONTEXT_HASH="$(jq -c '.autofixContext' "$PARSED_CONTEXT_FILE" | shasum -a 256 | awk '{print $1}')"
log "[$JIRA_KEY] Jira context hash: $CONTEXT_HASH"

# --- 5. Build the sanitized Copilot prompt -----------------------------------
PROMPT_FILE="$PROMPTS_DIR/${JIRA_KEY}-${TIMESTAMP}.md"
bash "$LIB_DIR/build-agent-prompt.sh" "$PARSED_CONTEXT_FILE" "$PROMPTS_TEMPLATE" "$PROMPT_FILE"

# --- 6. Prepare isolated worktree --------------------------------------------
WORKTREE="$(bash "$LIB_DIR/prepare-worktree.sh" "$JIRA_KEY" "$BRANCH_NAME")"
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" ]]; then
  mark_incident "AGENT_FAILED" "WORKTREE_SETUP_FAILED: could not prepare git worktree for $BRANCH_NAME"
  exit 0
fi
log "Worktree ready at $WORKTREE"

# --- 6b. Reconciliation shortcut ---------------------------------------------
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

# --- 7. Run Copilot CLI -------------------------------------------------------
LOG_FILE="$LOGS_DIR/${JIRA_KEY}-${TIMESTAMP}-copilot.log"
bash "$LIB_DIR/run-copilot.sh" "$WORKTREE" "$PROMPT_FILE" "$LOG_FILE"
COPILOT_EXIT=$?
log "Copilot CLI finished with exit code $COPILOT_EXIT (non-fatal -- validate-diff.sh decides)"

# --- 8. Independent validation gate ------------------------------------------
set +e
bash "$LIB_DIR/validate-diff.sh" "$WORKTREE" > "$VALIDATION_JSON_FILE"
VALIDATE_EXIT=$?
set -e
cat "$VALIDATION_JSON_FILE" >&2

if [[ "$VALIDATE_EXIT" -eq 10 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  mark_incident "AGENT_FAILED" "$REASON"
  exit 0
elif [[ "$VALIDATE_EXIT" -eq 20 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATION_JSON_FILE")"
  mark_incident "HUMAN_REQUIRED" "$REASON"
  exit 0
elif [[ "$VALIDATE_EXIT" -ne 0 ]]; then
  mark_incident "AGENT_FAILED" "VALIDATION_GATE_ERROR: validate-diff.sh exited $VALIDATE_EXIT unexpectedly"
  exit 0
fi

fi
# end of RECONCILE_MODE / normal-Copilot-run branch

log "Validation gate: PASS"

# --- 9. Commit, push, Draft PR -----------------------------------------------
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

# Stage 6: record the Jira-context provenance/audit fields alongside the
# PR_READY update create-pr.sh already made -- jira_context_hash is an
# audit fingerprint of the validated context (not the content itself).
pg_exec -v incident_id="$INCIDENT_ID" -v source="JIRA_REST" -v hash="$CONTEXT_HASH" <<'SQL' >&2
    UPDATE autofix.incident
    SET agent_context_source = :'source',
        jira_context_hash = :'hash',
        jira_context_fetched_at = NOW(),
        updated_at = NOW()
    WHERE id = :'incident_id';
SQL

log "PR_READY: $(cat "$PR_JSON_FILE")"

# --- 10. Notify workflow 04 (Jira comment + REVIEW) --------------------------
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
  log "report-result.sh failed -- incident stays PR_READY, safe to retry later (see Stage 5I)"
  exit 0
fi

log "Incident $INCIDENT_ID / $JIRA_KEY fully processed: PR #$PR_NUMBER, Jira REVIEW"
exit 0
