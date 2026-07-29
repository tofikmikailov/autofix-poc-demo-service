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
# Usage:
#   claim-job.sh
#
# Output:
#   A single JSON object on stdout describing the claimed incident, e.g.:
#     {"id":1,"jira_key":"AUTO-3","branch_name":"autofix/AUTO-3",
#      "exception_type":"...","normalized_exception_message":"...",
#      "application_stack_frame":"...","sample_request_path":"...",
#      "sample_http_method":"...","sample_correlation_id":"...",
#      "sample_stack_trace":"...","agent_attempt_count":1}
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
    SELECT id
    FROM autofix.incident
    WHERE status = 'AGENT_PENDING'
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
    RETURNING i.id, i.jira_key, i.branch_name, i.exception_type,
              i.normalized_exception_message, i.application_stack_frame,
              i.sample_request_path, i.sample_http_method,
              i.sample_correlation_id, i.sample_stack_trace,
              i.agent_attempt_count
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
