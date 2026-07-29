#!/usr/bin/env bash
#
# Stage 5D: Atomic job claim.
#
# Claims exactly one AGENT_PENDING incident and flips it to AGENT_RUNNING,
# using `FOR UPDATE SKIP LOCKED` so that if two runner instances ever ran
# concurrently, each would claim a *different* job (or find none) rather
# than racing on the same one.
#
# Before claiming, this also reclaims any incident that has been stuck in
# AGENT_RUNNING for longer than the lease (default 30 minutes) -- e.g. a
# runner process that crashed mid-job -- by resetting it back to
# AGENT_PENDING so it becomes claimable again.
#
# Stage 6B: this deliberately returns ONLY technical orchestration fields
# -- no exception/stack-trace/request-path detail. Since Stage 6, Jira is
# the source of truth for task context; since Stage 6B, the Agent Runner
# fetches it via a local n8n webhook (fetch-ticket-context.sh) instead of
# calling Jira REST directly or trusting a PostgreSQL snapshot that could
# have gone stale the moment a human edited the ticket.
#
# Usage:
#   claim-job.sh
#
# Output:
#   A single JSON object on stdout describing the claimed incident, e.g.:
#     {"incidentId":1,"jiraKey":"AUTO-3","fingerprint":"<sha256>",
#      "branchName":"autofix/AUTO-3","agentAttemptCount":1}
#   Nothing is printed if there is no AGENT_PENDING job to claim.
#
# Exit codes:
#   0 - a job was claimed (JSON printed)
#   3 - no AGENT_PENDING job available (nothing to do right now)
#   1 - hard failure (psql/docker error)

set -euo pipefail

LEASE_MINUTES="${AGENT_LEASE_MINUTES:-30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX_REPO="${AUTOFIX_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INFRA_DIR="${INFRA_DIR:-$AUTOFIX_REPO/infrastructure}"

cd "$INFRA_DIR"
PG_USER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2)"
PG_DB="$(grep '^POSTGRES_DB=' .env | cut -d= -f2)"

RESULT="$(docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -t -A \
  -v lease_minutes="$LEASE_MINUTES" <<'SQL'
WITH lease_reclaim AS (
    UPDATE autofix.incident
    SET status = 'AGENT_PENDING',
        agent_claimed_at = NULL,
        agent_last_error = 'LEASE_EXPIRED: previous agent run exceeded ' || :'lease_minutes' || ' minute lease and was reclaimed',
        updated_at = NOW()
    WHERE status = 'AGENT_RUNNING'
      AND agent_claimed_at < NOW() - (:'lease_minutes' || ' minutes')::interval
    RETURNING id
),
claimable AS (
    -- Stage 6: agent_next_attempt_at enforces backoff after a transient
    -- ticket-context-fetch failure (see fetch-ticket-context.sh /
    -- mark-incident-failed.sh) -- a job whose next-attempt time is still
    -- in the future must not be claimed early.
    SELECT id
    FROM autofix.incident
    WHERE status = 'AGENT_PENDING'
      AND (agent_next_attempt_at IS NULL OR agent_next_attempt_at <= NOW())
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1
),
claimed AS (
    UPDATE autofix.incident i
    SET status = 'AGENT_RUNNING',
        agent_claimed_at = NOW(),
        agent_started_at = NOW(),
        agent_attempt_count = agent_attempt_count + 1,
        agent_last_error = NULL,
        updated_at = NOW()
    FROM claimable
    WHERE i.id = claimable.id
    -- Stage 6: only technical orchestration fields are returned --
    -- fingerprint is included so validate-ticket-response.sh can confirm
    -- the n8n-fetched ticket context still matches this incident, but
    -- no exception/message/stack-trace/request-path detail is returned
    -- here (that is fetched fresh from Jira, never from this snapshot).
    RETURNING i.id AS "incidentId", i.jira_key AS "jiraKey",
              i.fingerprint, i.branch_name AS "branchName",
              i.agent_attempt_count AS "agentAttemptCount"
)
SELECT row_to_json(claimed) FROM claimed;
SQL
)"

# Trim surrounding whitespace/newlines only -- do NOT use xargs here, it
# would mangle the JSON's internal quoting/whitespace.
RESULT="${RESULT#"${RESULT%%[![:space:]]*}"}"
RESULT="${RESULT%"${RESULT##*[![:space:]]}"}"

if [[ -z "$RESULT" ]]; then
  echo "No AGENT_PENDING job available to claim" >&2
  exit 3
fi

printf '%s\n' "$RESULT"
