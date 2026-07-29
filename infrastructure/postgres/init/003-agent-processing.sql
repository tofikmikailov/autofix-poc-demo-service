-- Stage 5B: Agent Runner processing lifecycle
--
-- Extends the incident state machine past JIRA_CREATED with the states
-- needed to track a local Copilot CLI agent run through to a Draft PR
-- and the Jira REVIEW transition:
--
--   JIRA_CREATED
--       v policy approved
--   AGENT_PENDING
--       v runner claimed
--   AGENT_RUNNING
--       v PR created
--   PR_READY
--       v Jira comment + transition
--   REVIEW
--
-- AGENT_FAILED is the retry/lease-expiry counterpart to JIRA_FAILED,
-- mirroring the same claim/lease pattern used for Jira publishing.

ALTER TABLE autofix.incident
    DROP CONSTRAINT IF EXISTS incident_status_check;

ALTER TABLE autofix.incident
    ADD CONSTRAINT incident_status_check CHECK (
        status IN (
            'DETECTED',
            'JIRA_PENDING',
            'JIRA_CREATED',
            'JIRA_FAILED',
            'AGENT_PENDING',
            'AGENT_RUNNING',
            'PR_READY',
            'REVIEW',
            'HUMAN_REQUIRED',
            'AGENT_FAILED',
            'COMPLETED',
            'FAILED'
        )
    );

-- pull_request_url is superseded by branch_name (a deterministic
-- identifier the runner can use to look up the PR via
-- `gh pr list --head <branch_name>`) plus the PR number captured inside
-- agent_result. Dropping it keeps the schema aligned with the actual
-- process instead of carrying an unused, redundant field.
ALTER TABLE autofix.incident
    DROP COLUMN IF EXISTS pull_request_url;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS branch_name VARCHAR(255);

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_attempt_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_claimed_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_started_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_completed_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_last_error TEXT;

-- Technical summary only (no PR URL): testsPassed, changedFiles,
-- addedLines, deletedLines, commitSha, prNumber, etc.
ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS agent_result JSONB;

CREATE INDEX IF NOT EXISTS idx_incident_agent_queue
    ON autofix.incident (
        status,
        agent_claimed_at,
        created_at
    )
    WHERE branch_name IS NULL;
