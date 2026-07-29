-- Stage 6: Jira as the source of truth for AutoFix task context.
--
-- Prior to this migration, the Agent Runner built the Copilot prompt from
-- a snapshot of the incident stored in PostgreSQL (exception type,
-- message, stack trace, request path, ...). That snapshot could go stale
-- the moment a human edited the Jira ticket (added context, clarified
-- acceptance criteria, ...).
--
-- From Stage 6 onward, PostgreSQL only stores orchestration state; the
-- Agent Runner reads the live Jira issue via the REST API and treats it
-- as the source of task context. These new columns are technical/audit
-- metadata about that fetch -- never the Jira content itself:
--
--   agent_context_source     - where the last successful prompt context
--                               came from (e.g. 'JIRA_REST')
--   jira_context_fetched_at  - when the Jira issue was last fetched and
--                               successfully validated
--   jira_context_hash        - sha256 of the normalized, validated
--                               context (audit: which exact Jira snapshot
--                               was used; detect a ticket edit between
--                               attempts) -- NOT the content itself
--   agent_next_attempt_at    - backoff scheduling for transient Jira
--                               fetch failures (see Stage 6 retry policy)
--
-- This migration is idempotent and safe to re-run against an existing
-- database.

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_context_source VARCHAR(50);

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_context_fetched_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_context_hash CHAR(64);

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_next_attempt_at TIMESTAMPTZ;

-- The AGENT_PENDING queue query (Workflow 03 / claim-job.sh) must respect
-- backoff scheduling: a job whose next-attempt time is still in the
-- future must not be claimed early after a transient Jira failure.
CREATE INDEX IF NOT EXISTS idx_incident_agent_next_attempt
    ON autofix.incident (status, agent_next_attempt_at)
    WHERE status = 'AGENT_PENDING';
