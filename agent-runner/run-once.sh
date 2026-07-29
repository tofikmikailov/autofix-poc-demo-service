#!/usr/bin/env bash
#
# Stage 5D / Stage 6: Host Agent Runner -- top-level orchestrator.
#
# Runs on the host (not in a container) because that is where Copilot
# CLI, git credentials, GitHub CLI, the repository, and the Gradle/JDK
# toolchain all live.
#
# Pipeline for a single job (Stage 6B order):
#   claim-job                AGENT_PENDING -> AGENT_RUNNING (atomic, leased)
#   fetch-ticket-context      POST to local n8n webhook (Workflow 05) --
#                             the ONLY network call the runner makes for
#                             task context; no Jira credential lives here
#   validate-ticket-response  independent re-check: schema/provenance/
#                             fingerprint/incidentId/allow-list
#   build-agent-prompt        sanitized prompt from the VALIDATED response
#   prepare-worktree          isolated git worktree, deterministic branch
#   run-copilot               Copilot CLI, no git/gh/network/Jira/MCP access
#   validate-diff             independent judge (never trusts Copilot's report)
#   create-pr                 commit + push + idempotent Draft PR -> PR_READY
#   report-result             notify workflow 04 -> Jira comment + REVIEW
#
# Since Stage 6B, Jira credentials exist ONLY inside n8n (Workflow 05's
# Jira credential). PostgreSQL still owns orchestration state (status,
# branch_name, attempt counters, leases) and a fingerprint used only to
# cross-check that the sanitized ticket context still refers to the same
# incident.
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

# Stage 6B: load agent-runner/.env if present (N8N_TICKET_CONTEXT_WEBHOOK_URL,
# AUTOFIX_RUNNER_WEBHOOK_TOKEN, timeouts/retries, ...). Never committed --
# see agent-runner/.env.example. No Jira credential is ever loaded here.
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

# Stage 6B Section 24: after this many failed ticket-context-fetch
# attempts (transient n8n/Jira errors only), stop retrying and give up
# permanently (AGENT_FAILED) rather than retry forever.
MAX_TICKET_CONTEXT_FETCH_ATTEMPTS="${MAX_TICKET_CONTEXT_FETCH_ATTEMPTS:-3}"

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

# --- 2. Fetch the sanitized ticket context via n8n Workflow 05 --------------
# Stage 6B: PostgreSQL is never used as the source of task context from
# here on -- only the fingerprint above (for cross-checking) and the
# technical orchestration fields already claimed. The Agent Runner holds
# no Jira credential; n8n's Workflow 05 does the actual Jira read using
# its own credential and returns only a sanitized, size-limited response.
TICKET_CONTEXT_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-ticket-context.json"
set +e
bash "$LIB_DIR/fetch-ticket-context.sh" "$INCIDENT_ID" "$JIRA_KEY" "$FINGERPRINT" "$BRANCH_NAME" "$TICKET_CONTEXT_FILE"
FETCH_EXIT=$?
set -e

case "$FETCH_EXIT" in
  0)
    log "[$JIRA_KEY] Ticket context fetched successfully via n8n Workflow 05"
    ;;
  2)
    # Transient: n8n reported JIRA_UNAVAILABLE (503), or n8n itself was
    # unreachable (TICKET_CONTEXT_SERVICE_UNAVAILABLE).
    if [[ "$ATTEMPT_COUNT" -ge "$MAX_TICKET_CONTEXT_FETCH_ATTEMPTS" ]]; then
      mark_incident "AGENT_FAILED" "TICKET_CONTEXT_FETCH_FAILED: exceeded $MAX_TICKET_CONTEXT_FETCH_ATTEMPTS attempts fetching ticket context for $JIRA_KEY"
    else
      mark_incident "RETRY" "TICKET_CONTEXT_FETCH_FAILED: transient error fetching ticket context for $JIRA_KEY (attempt $ATTEMPT_COUNT)" "$ATTEMPT_COUNT"
    fi
    exit 0
    ;;
  3)
    mark_incident "AGENT_FAILED" "TICKET_CONTEXT_AUTH_FAILED: n8n webhook rejected the shared runner token while fetching $JIRA_KEY"
    exit 0
    ;;
  4)
    mark_incident "HUMAN_REQUIRED" "JIRA_ISSUE_NOT_FOUND: $JIRA_KEY does not exist or is not visible to n8n's Jira credential"
    exit 0
    ;;
  20)
    REASON="$(jq -r '.message // "INVALID_JIRA_CONTEXT"' "$TICKET_CONTEXT_FILE")"
    mark_incident "HUMAN_REQUIRED" "INVALID_JIRA_CONTEXT: $REASON"
    exit 0
    ;;
  *)
    log "fetch-ticket-context.sh failed unexpectedly (exit $FETCH_EXIT) -- leaving incident as AGENT_RUNNING for lease-based retry"
    exit 1
    ;;
esac

# --- 3. Independently re-validate the ticket context ------------------------
VALIDATE_CONTEXT_JSON_FILE="$RESULTS_DIR/${JIRA_KEY}-${TIMESTAMP}-context-validation.json"
set +e
bash "$LIB_DIR/validate-ticket-response.sh" "$TICKET_CONTEXT_FILE" "$INCIDENT_ID" "$JIRA_KEY" "$FINGERPRINT" > "$VALIDATE_CONTEXT_JSON_FILE"
VALIDATE_CONTEXT_EXIT=$?
set -e
cat "$VALIDATE_CONTEXT_JSON_FILE" >&2

if [[ "$VALIDATE_CONTEXT_EXIT" -ne 0 ]]; then
  REASON="$(jq -r '.reason' "$VALIDATE_CONTEXT_JSON_FILE")"
  mark_incident "HUMAN_REQUIRED" "$REASON"
  exit 0
fi

log "[$JIRA_KEY] Ticket context schema V1 validated"

# Fields used for the commit message / PR title+body below -- sourced
# exclusively from the validated n8n response now, never from PostgreSQL.
EXCEPTION_TYPE="$(jq -r '.incident.exceptionType // "unknown"' "$TICKET_CONTEXT_FILE")"
APPLICATION_STACK_FRAME="$(jq -r '.incident.applicationFrame // "n/a"' "$TICKET_CONTEXT_FILE")"
SAMPLE_HTTP_METHOD="$(jq -r '.incident.httpMethod // "n/a"' "$TICKET_CONTEXT_FILE")"
SAMPLE_REQUEST_PATH="$(jq -r '.incident.requestPath // "n/a"' "$TICKET_CONTEXT_FILE")"
CONTEXT_HASH="$(jq -r '.contextHash' "$TICKET_CONTEXT_FILE")"
log "[$JIRA_KEY] Ticket context hash: $CONTEXT_HASH"

# --- 4. Build the sanitized Copilot prompt -----------------------------------
PROMPT_FILE="$PROMPTS_DIR/${JIRA_KEY}-${TIMESTAMP}.md"
bash "$LIB_DIR/build-agent-prompt.sh" "$TICKET_CONTEXT_FILE" "$PROMPTS_TEMPLATE" "$PROMPT_FILE"

# --- 5. Prepare isolated worktree --------------------------------------------
WORKTREE="$(bash "$LIB_DIR/prepare-worktree.sh" "$JIRA_KEY" "$BRANCH_NAME")"
if [[ -z "$WORKTREE" || ! -d "$WORKTREE" ]]; then
  mark_incident "AGENT_FAILED" "WORKTREE_SETUP_FAILED: could not prepare git worktree for $BRANCH_NAME"
  exit 0
fi
log "Worktree ready at $WORKTREE"

# --- 5b. Reconciliation shortcut ---------------------------------------------
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

# --- 6. Run Copilot CLI -------------------------------------------------------
LOG_FILE="$LOGS_DIR/${JIRA_KEY}-${TIMESTAMP}-copilot.log"
bash "$LIB_DIR/run-copilot.sh" "$WORKTREE" "$PROMPT_FILE" "$LOG_FILE"
COPILOT_EXIT=$?
log "Copilot CLI finished with exit code $COPILOT_EXIT (non-fatal -- validate-diff.sh decides)"

# --- 7. Independent validation gate ------------------------------------------
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

# --- 8. Commit, push, Draft PR -----------------------------------------------
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

# Stage 6B: record the ticket-context provenance/audit fields alongside
# the PR_READY update create-pr.sh already made -- jira_context_hash is
# an audit fingerprint of the validated n8n response (not the content
# itself). Source is N8N_JIRA_PROXY since Stage 6B: Jira was never
# contacted directly by this runner -- only via n8n Workflow 05.
pg_exec -v incident_id="$INCIDENT_ID" -v source="N8N_JIRA_PROXY" -v hash="$CONTEXT_HASH" <<'SQL' >&2
    UPDATE autofix.incident
    SET agent_context_source = :'source',
        jira_context_hash = :'hash',
        jira_context_fetched_at = NOW(),
        updated_at = NOW()
    WHERE id = :'incident_id';
SQL

log "PR_READY: $(cat "$PR_JSON_FILE")"

# --- 9. Notify workflow 04 (Jira comment + REVIEW) --------------------------
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
