-- Stage 8 follow-up #2: REVIEW must not be treated as terminal for the
-- fingerprint-reopen logic either.
--
-- Bug observed live: incident 26 (AUTO-16) reached REVIEW (agent created
-- PR #14, awaiting human merge). The exact same NPE was retriggered a few
-- minutes later, before the PR had been merged -- i.e. the bug was still
-- live in the codebase, unfixed. Because REVIEW was in the terminal-status
-- list (migrations 006/007), the recurrence did NOT bump occurrence_count
-- on incident 26; it spawned a brand-new incident (28, AUTO-17) with its
-- own PR (#15) for the identical, still-unfixed bug -- duplicate tickets
-- and a duplicate AutoFix cycle for one open, unresolved fix.
--
-- REVIEW means "a PR is open, awaiting human review/merge" -- it is NOT a
-- concluded lifecycle. Until the PR merges (which this system does not
-- track back from GitHub), the underlying bug is still present, so any
-- recurrence is the same open issue, not a new one. AGENT_FAILED remains
-- the only true terminal status for this table (agent retries genuinely
-- exhausted with no PR produced).
--
-- Safe to re-run against an existing database.

DROP INDEX IF EXISTS autofix.idx_incident_fingerprint_active;

CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_fingerprint_active
    ON autofix.incident (fingerprint)
    WHERE status NOT IN (
        'AGENT_FAILED', 'COMPLETED', 'FAILED'
    );
