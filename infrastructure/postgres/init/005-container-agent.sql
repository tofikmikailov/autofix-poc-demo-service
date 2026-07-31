-- Section 21: containerized AutoFix Agent Runner (autofix-agent).
--
-- The container agent generates its own job identifier
-- (autofix-<incidentId>-<attempt>, see agent-job.schema.json) and n8n
-- Workflow 03 must persist it on the incident row before dispatching,
-- so that:
--   - a duplicate POST /api/jobs for the same attempt is detected as a
--     retry of an already-dispatched job, not a brand-new one
--   - the callback handler (Workflow 04) can look the incident back up
--     by jobId alone, without re-deriving it from incidentId/attempt
--
-- agent_started_at/agent_completed_at (added in 003) and
-- jira_context_hash/agent_next_attempt_at (added in 004) already cover
-- the rest of the container-agent lifecycle; only agent_job_id is new.
--
-- This migration is idempotent and safe to re-run against an existing
-- database.

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_job_id VARCHAR(64);

CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_agent_job_id
    ON autofix.incident (agent_job_id)
    WHERE agent_job_id IS NOT NULL;
