#!/usr/bin/env bash
#
# Stage 5G: Commit, push, and idempotent Draft PR creation.
#
# Runs only after validate.sh has already returned PASS. This script never
# re-validates the diff itself -- it trusts the validation-gate JSON it is
# given and focuses solely on making the result durable: a pushed branch,
# a Draft PR (created or reused), and a PR_READY incident row. No PR URL
# is ever stored in PostgreSQL -- branch_name plus agent_result.prNumber
# are sufficient to look the PR up again via `gh pr list --head`.
#
# Usage:
#   create-pr.sh <worktree-dir> <incident-id> <branch-name> \
#                <commit-message> <pr-title> <pr-body-file> \
#                <validation-json-file>
#
# validation-json-file must contain the PASS verdict produced by
# validate-diff.sh, e.g.:
#   {"result":"PASS","changedFiles":2,"addedLines":14,"deletedLines":6}
#
# On success, prints a single JSON object to stdout (informational logs
# go to stderr), so callers (run-once.sh) can feed it straight into
# report-result.sh:
#   {"prNumber":12,"prUrl":"https://github.com/.../pull/12",
#    "commitSha":"...","changedFiles":2,"addedLines":14,"deletedLines":6}
#
# Exit codes:
#   0  - PR_READY (commit/push/PR succeeded, incident row updated)
#   1  - hard failure (git/gh/psql error) -- incident is left untouched,
#        so the standard Agent Runner claim/lease logic can retry safely.

set -euo pipefail

WORKTREE_DIR="${1:?usage: create-pr.sh <worktree-dir> <incident-id> <branch-name> <commit-message> <pr-title> <pr-body-file> <validation-json-file>}"
INCIDENT_ID="${2:?missing incident-id}"
BRANCH_NAME="${3:?missing branch-name}"
COMMIT_MESSAGE="${4:?missing commit-message}"
PR_TITLE="${5:?missing pr-title}"
PR_BODY_FILE="${6:?missing pr-body-file}"
VALIDATION_JSON_FILE="${7:?missing validation-json-file}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX_REPO="${AUTOFIX_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INFRA_DIR="${INFRA_DIR:-$AUTOFIX_REPO/infrastructure}"
BASE_BRANCH="${AUTOFIX_BASE_BRANCH:-main}"

if [[ ! -f "$PR_BODY_FILE" ]]; then
  echo "PR body file not found: $PR_BODY_FILE" >&2
  exit 1
fi

VALIDATION_RESULT="$(jq -r '.result' "$VALIDATION_JSON_FILE")"
if [[ "$VALIDATION_RESULT" != "PASS" ]]; then
  echo "Refusing to publish: validation result is '$VALIDATION_RESULT', not PASS" >&2
  exit 1
fi

CHANGED_FILES="$(jq -r '.changedFiles' "$VALIDATION_JSON_FILE")"
ADDED_LINES="$(jq -r '.addedLines' "$VALIDATION_JSON_FILE")"
DELETED_LINES="$(jq -r '.deletedLines' "$VALIDATION_JSON_FILE")"

cd "$WORKTREE_DIR"

# --- Commit ----------------------------------------------------------------
# Only the allow-listed source trees are staged; validate.sh has already
# guaranteed nothing else was touched, but we intentionally re-scope the
# add here rather than reuse validate.sh's `git add -A` index, to keep
# this script safe to run standalone.
git add src/main src/test >&2
if [[ -f README.md ]] && ! git diff --cached --quiet -- README.md 2>/dev/null; then
  git add README.md >&2
fi

if git diff --cached --quiet; then
  # Nothing staged. This is only a real error if no commit has been made
  # yet on this branch (i.e. it's still even with main) -- otherwise this
  # is a resumed run after a prior attempt already committed (e.g. the
  # PR/DB update step failed and is being retried), and the existing
  # commit should simply be reused.
  MERGE_BASE="$(git merge-base HEAD "origin/$BASE_BRANCH" 2>/dev/null || git merge-base HEAD "$BASE_BRANCH")"
  if [[ "$(git rev-parse HEAD)" == "$MERGE_BASE" ]]; then
    echo "Nothing staged to commit (src/main, src/test, README.md are all clean)" >&2
    exit 1
  fi
  echo "Nothing new to stage -- reusing existing commit $(git rev-parse --short HEAD) from a prior attempt" >&2
else
  git commit -m "$COMMIT_MESSAGE" >&2
fi
COMMIT_SHA="$(git rev-parse HEAD)"

# --- Push --------------------------------------------------------------------
git push -u origin "$BRANCH_NAME" >&2

# --- Idempotent PR lookup / creation -----------------------------------------
EXISTING_PR="$(gh pr list --head "$BRANCH_NAME" --state open --json number,url,state,isDraft --limit 1)"
PR_COUNT="$(echo "$EXISTING_PR" | jq 'length')"

if [[ "$PR_COUNT" -gt 0 ]]; then
  PR_NUMBER="$(echo "$EXISTING_PR" | jq -r '.[0].number')"
  PR_URL="$(echo "$EXISTING_PR" | jq -r '.[0].url')"
  echo "Reusing existing PR #$PR_NUMBER for branch $BRANCH_NAME" >&2
else
  gh pr create \
    --draft \
    --base "$BASE_BRANCH" \
    --head "$BRANCH_NAME" \
    --title "$PR_TITLE" \
    --body-file "$PR_BODY_FILE" >&2

  CREATED_PR="$(gh pr list --head "$BRANCH_NAME" --state open --json number,url --limit 1)"
  PR_NUMBER="$(echo "$CREATED_PR" | jq -r '.[0].number')"
  PR_URL="$(echo "$CREATED_PR" | jq -r '.[0].url')"
  echo "Created new Draft PR #$PR_NUMBER for branch $BRANCH_NAME" >&2
fi

if [[ -z "$PR_NUMBER" || "$PR_NUMBER" == "null" ]]; then
  echo "Failed to determine PR number after create/lookup" >&2
  exit 1
fi

# --- Update PostgreSQL --------------------------------------------------------
# No PR URL is persisted -- branch_name (already set by workflow 03) plus
# agent_result.prNumber are enough to reconstruct/find the PR via
# `gh pr list --head <branch_name>`.
AGENT_RESULT_JSON="$(jq -n \
  --argjson testsPassed true \
  --argjson changedFiles "$CHANGED_FILES" \
  --argjson addedLines "$ADDED_LINES" \
  --argjson deletedLines "$DELETED_LINES" \
  --arg commitSha "$COMMIT_SHA" \
  --argjson prNumber "$PR_NUMBER" \
  '{
    testsPassed: $testsPassed,
    changedFiles: $changedFiles,
    addedLines: $addedLines,
    deletedLines: $deletedLines,
    commitSha: $commitSha,
    prNumber: $prNumber
  }')"

cd "$INFRA_DIR"
PG_USER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2)"
PG_DB="$(grep '^POSTGRES_DB=' .env | cut -d= -f2)"

# psql variable interpolation (:'var') is only applied when the SQL is
# read as a script (stdin/-f), not when passed via -c -- pipe it in.
# The whole block's stdout is redirected to stderr so psql's RETURNING
# table never contaminates this script's single-JSON-object stdout
# contract (see header comment).
(
docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
  -v incident_id="$INCIDENT_ID" \
  -v branch_name="$BRANCH_NAME" \
  -v agent_result="$AGENT_RESULT_JSON" \
  <<'SQL'
    UPDATE autofix.incident
    SET
        status = 'PR_READY',
        branch_name = :'branch_name',
        agent_result = :'agent_result'::jsonb,
        agent_completed_at = NOW(),
        agent_claimed_at = NULL,
        agent_last_error = NULL,
        updated_at = NOW()
    WHERE id = :'incident_id'
    RETURNING id, status, branch_name, agent_result;
SQL
) >&2

echo "PR_READY: incident $INCIDENT_ID -> PR #$PR_NUMBER (branch $BRANCH_NAME, commit $COMMIT_SHA)" >&2

# Machine-readable summary for the caller (run-once.sh) to forward
# straight into report-result.sh -- PR_URL is used transiently here only,
# never persisted to PostgreSQL (see header comment).
jq -n \
  --argjson prNumber "$PR_NUMBER" \
  --arg prUrl "$PR_URL" \
  --arg commitSha "$COMMIT_SHA" \
  --argjson changedFiles "$CHANGED_FILES" \
  --argjson addedLines "$ADDED_LINES" \
  --argjson deletedLines "$DELETED_LINES" \
  '{
    prNumber: $prNumber,
    prUrl: $prUrl,
    commitSha: $commitSha,
    changedFiles: $changedFiles,
    addedLines: $addedLines,
    deletedLines: $deletedLines
  }'
