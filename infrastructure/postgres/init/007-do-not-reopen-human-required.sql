-- Stage 8 follow-up: HUMAN_REQUIRED must NOT be treated as terminal for the
-- fingerprint-reopen logic introduced in migration 006.
--
-- Bug observed live: a recurring error whose exception type is rejected by
-- Workflow 03's Policy Gate (e.g. org.springframework.web.servlet.resource.
-- NoResourceFoundException for GET /favicon.ico) lands in HUMAN_REQUIRED on
-- every single occurrence -- Policy Gate will reject it again and again,
-- forever, since the policy allow-list never changes. Nobody actually
-- "handles" this ticket in Jira; it just sits in the backlog. Because
-- migration 006 excluded HUMAN_REQUIRED from the active-uniqueness index,
-- every recurrence of such a permanently-rejected fingerprint created a
-- brand-new Jira ticket (AUTO-13, AUTO-15, ... one per occurrence) instead
-- of bumping occurrence_count on the existing open ticket -- pure ticket
-- spam for a class of error that will never progress past HUMAN_REQUIRED.
--
-- REVIEW/AGENT_FAILED remain terminal: those really do represent "this
-- system's automated lifecycle for the incident concluded" (fix proposed
-- for human review, or agent retries exhausted). HUMAN_REQUIRED from a
-- policy rejection is different -- it is a standing, unresolved backlog
-- item, not a concluded one, so recurrences should keep accumulating on it
-- like any other active incident.
--
-- Safe to re-run against an existing database.

DROP INDEX IF EXISTS autofix.idx_incident_fingerprint_active;

CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_fingerprint_active
    ON autofix.incident (fingerprint)
    WHERE status NOT IN (
        'REVIEW', 'AGENT_FAILED', 'COMPLETED', 'FAILED'
    );
