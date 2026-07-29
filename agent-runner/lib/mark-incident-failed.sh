#!/usr/bin/env bash
#
# Stage 6: shared helper for writing a terminal (or retry) outcome back
# to PostgreSQL. Factored out of run-once.sh so both the main pipeline
# and the Jira-context-fetch retry path share exactly one place that
# knows how to update incident.status/agent_last_error.
#
# Usage:
#   mark-incident-failed.sh <incident-id> <status> <reason>
#   mark-incident-failed.sh <incident-id> RETRY <reason> <attempt-count>
#
# <status> is one of: AGENT_FAILED | HUMAN_REQUIRED | RETRY
#
# RETRY is not a real incident.status value -- it means "put the job back
# in AGENT_PENDING with a backoff delay" (Stage 6 transient Jira error
# handling: connection timeout, 429, 5xx). The incident row's status
# becomes AGENT_PENDING again, agent_next_attempt_at is set according to
# the backoff schedule below, and agent_claimed_at is cleared so the
# lease-reclaim logic in claim-job.sh does not also try to reclaim it.
#
# Backoff schedule (by agent_attempt_count):
#   attempt 1 -> retry in 1 minute
#   attempt 2 -> retry in 5 minutes
#   attempt 3 -> retry in 15 minutes
#   attempt 4+ -> caller should stop retrying and mark AGENT_FAILED instead
#
# Exit codes:
#   0 - incident row updated
#   1 - hard failure (psql/docker error)

set -euo pipefail

INCIDENT_ID="${1:?usage: mark-incident-failed.sh <incident-id> <status> <reason> [attempt-count]}"
NEW_STATUS="${2:?missing status (AGENT_FAILED|HUMAN_REQUIRED|RETRY)}"
REASON="${3:?missing reason}"
ATTEMPT_COUNT="${4:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX_REPO="${AUTOFIX_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
INFRA_DIR="${INFRA_DIR:-$AUTOFIX_REPO/infrastructure}"

cd "$INFRA_DIR"
PG_USER="$(grep '^POSTGRES_USER=' .env | cut -d= -f2)"
PG_DB="$(grep '^POSTGRES_DB=' .env | cut -d= -f2)"

if [[ "$NEW_STATUS" == "RETRY" ]]; then
  case "$ATTEMPT_COUNT" in
    1) BACKOFF_INTERVAL="1 minute" ;;
    2) BACKOFF_INTERVAL="5 minutes" ;;
    *) BACKOFF_INTERVAL="15 minutes" ;;
  esac

  echo "[mark-incident-failed] incident $INCIDENT_ID -> AGENT_PENDING (retry in $BACKOFF_INTERVAL): $REASON" >&2
  docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
    -v incident_id="$INCIDENT_ID" -v reason="$REASON" -v backoff="$BACKOFF_INTERVAL" <<'SQL'
    UPDATE autofix.incident
    SET status = 'AGENT_PENDING',
        agent_last_error = :'reason',
        agent_claimed_at = NULL,
        agent_next_attempt_at = NOW() + (:'backoff')::interval,
        updated_at = NOW()
    WHERE id = :'incident_id'
    RETURNING id, status, agent_last_error, agent_next_attempt_at;
SQL
else
  echo "[mark-incident-failed] incident $INCIDENT_ID -> $NEW_STATUS: $REASON" >&2
  docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
    -v incident_id="$INCIDENT_ID" -v new_status="$NEW_STATUS" -v reason="$REASON" <<'SQL'
    UPDATE autofix.incident
    SET status = :'new_status',
        agent_last_error = :'reason',
        agent_completed_at = NOW(),
        agent_claimed_at = NULL,
        agent_next_attempt_at = NULL,
        updated_at = NOW()
    WHERE id = :'incident_id'
    RETURNING id, status, agent_last_error;
SQL
fi
