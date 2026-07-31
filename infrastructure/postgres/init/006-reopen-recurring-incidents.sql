-- Stage 7 follow-up: reopen recurring incidents as a new record instead
-- of silently accumulating occurrence_count on an incident whose
-- AutoFix lifecycle has already reached a terminal outcome.
--
-- Previously `fingerprint` had a plain UNIQUE constraint, so Workflow 01's
-- upsert (`ON CONFLICT (fingerprint) DO UPDATE ...`) would match ANY
-- existing row with the same fingerprint, regardless of status -- including
-- one already sitting in REVIEW (fix proposed, ticket may since have been
-- merged and closed by a human outside this system), HUMAN_REQUIRED, or
-- AGENT_FAILED. A later recurrence of the exact same error would just bump
-- last_seen_at/occurrence_count on that old row: no new Jira ticket, no new
-- AutoFix attempt -- even if the original ticket had long since been closed.
--
-- This migration replaces the plain UNIQUE constraint with a PARTIAL unique
-- index that only enforces uniqueness among "active" (still in-flight)
-- incidents. Once an incident reaches one of the terminal statuses below,
-- it no longer participates in the uniqueness check, so a fresh occurrence
-- of the same fingerprint is inserted as a brand-new incident row (new id,
-- new Jira ticket, new AutoFix cycle) rather than reopening/mutating the
-- old one. At most one ACTIVE incident per fingerprint still exists at any
-- time -- this migration only relaxes uniqueness across terminal history,
-- not within the active pipeline.
--
-- Terminal statuses (no longer unique-constrained against new occurrences):
--   REVIEW          -- fix proposed; human may have merged & closed since
--   HUMAN_REQUIRED  -- policy-rejected or exhausted agent retries
--   AGENT_FAILED    -- exhausted agent retries via the ctx-fetch path
--   COMPLETED       -- reserved for future use
--   FAILED          -- reserved for future use
--
-- Safe to re-run against an existing database.

ALTER TABLE autofix.incident
    DROP CONSTRAINT IF EXISTS incident_fingerprint_key;

CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_fingerprint_active
    ON autofix.incident (fingerprint)
    WHERE status NOT IN (
        'REVIEW', 'HUMAN_REQUIRED', 'AGENT_FAILED', 'COMPLETED', 'FAILED'
    );
