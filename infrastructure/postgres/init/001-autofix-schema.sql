CREATE SCHEMA IF NOT EXISTS autofix;

CREATE TABLE IF NOT EXISTS autofix.processed_log_event (
    elasticsearch_id VARCHAR(255) PRIMARY KEY,
    elasticsearch_index VARCHAR(255) NOT NULL,
    correlation_id VARCHAR(255),
    processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS autofix.incident (
    id BIGSERIAL PRIMARY KEY,

    fingerprint CHAR(64) NOT NULL UNIQUE,

    service_name VARCHAR(255) NOT NULL,
    environment VARCHAR(100) NOT NULL,
    exception_type VARCHAR(500) NOT NULL,

    normalized_exception_message TEXT,
    application_stack_frame TEXT,

    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,

    occurrence_count BIGINT NOT NULL DEFAULT 1,

    first_elasticsearch_id VARCHAR(255),
    last_elasticsearch_id VARCHAR(255),

    sample_correlation_id VARCHAR(255),
    sample_request_path TEXT,
    sample_http_method VARCHAR(20),
    sample_stack_trace TEXT,

    status VARCHAR(50) NOT NULL DEFAULT 'DETECTED',

    jira_key VARCHAR(100),
    pull_request_url TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT incident_status_check CHECK (
        status IN (
            'DETECTED',
            'JIRA_CREATED',
            'AGENT_PENDING',
            'AGENT_RUNNING',
            'PR_CREATED',
            'HUMAN_REQUIRED',
            'COMPLETED',
            'FAILED'
        )
    )
);

CREATE INDEX IF NOT EXISTS idx_incident_status
    ON autofix.incident (status);

CREATE INDEX IF NOT EXISTS idx_incident_last_seen
    ON autofix.incident (last_seen_at DESC);

CREATE INDEX IF NOT EXISTS idx_processed_event_processed_at
    ON autofix.processed_log_event (processed_at DESC);
