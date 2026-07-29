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
            'PR_CREATED',
            'HUMAN_REQUIRED',
            'COMPLETED',
            'FAILED'
        )
    );

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_attempt_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_claimed_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_last_attempt_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_created_at TIMESTAMPTZ;

ALTER TABLE autofix.incident
    ADD COLUMN IF NOT EXISTS jira_last_error TEXT;

CREATE INDEX IF NOT EXISTS idx_incident_jira_queue
    ON autofix.incident (
        status,
        jira_claimed_at,
        created_at
    )
    WHERE jira_key IS NULL;
