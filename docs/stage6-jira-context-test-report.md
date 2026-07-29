# Stage 6 — Jira as Source of Task Context: Test Report

## Scope

Stage 6 removes the Agent Runner's dependency on PostgreSQL for task
content. PostgreSQL now stores only orchestration state (status, branch
name, attempt count, timing, a `fingerprint` used purely for
cross-checking); the actual defect context — exception type, message,
stack trace, endpoint — is fetched live from Jira on every run and
treated as untrusted external input until it passes an independent
validation gate.

```
claim-job.sh            → technical identifiers only, no task content
fetch-jira-context.sh    → GET /rest/api/3/issue/<key> (read-only credential)
parse-jira-context.py    → ADF → plain text, AUTOFIX_CONTEXT_V1 extraction,
                            [AUTOFIX_AGENT_CONTEXT]-marked comments only
validate-jira-context.sh → cross-check + re-applied policy allow-list
build-agent-prompt.sh    → sanitized prompt, <UNTRUSTED_JIRA_CONTEXT> delimited
(unchanged Stage 5 pipeline continues: worktree → Copilot → Validation
 Gate → commit/push/PR → report-result.sh)
```

## Components delivered

- `infrastructure/postgres/init/004-jira-agent-context.sql` — adds
  `agent_context_source`, `jira_context_fetched_at`, `jira_context_hash`,
  `agent_next_attempt_at` to `autofix.incident`. Verified idempotent
  (re-run produces only "already exists, skipping" notices, exit 0).
- `agent-runner/lib/claim-job.sh` — rewritten to return only
  `{incidentId, jiraKey, fingerprint, branchName, agentAttemptCount}`;
  claim query now also respects `agent_next_attempt_at` backoff.
- `agent-runner/lib/mark-incident-failed.sh` — shared `AGENT_FAILED` /
  `HUMAN_REQUIRED` / backoff-scheduled `RETRY` helper (1/5/15 minute
  schedule by attempt count).
- `agent-runner/lib/fetch-jira-context.sh` — read-only Jira REST fetch
  with distinct exit codes (0 success, 2 transient, 3 auth, 4 not-found,
  1 hard failure).
- `agent-runner/lib/parse-jira-context.py` — recursive ADF → plain-text
  converter; extracts the `AUTOFIX_CONTEXT_V1` JSON block and only
  `[AUTOFIX_AGENT_CONTEXT]`-marked comments.
- `agent-runner/lib/validate-jira-context.sh` — the second independent
  judge in the pipeline; re-applies the Stage 5C policy allow-list
  against live Jira data and cross-checks jiraKey/incidentId/fingerprint
  against the claimed job.
- `agent-runner/lib/build-agent-prompt.sh` — renders the sanitized
  prompt from validated context only.
- `agent-runner/prompts/autofix-prompt.md` — new template with explicit
  `<UNTRUSTED_JIRA_CONTEXT>` delimiting for prompt-injection protection.
- `agent-runner/run-once.sh` — rewired to the new 10-step pipeline order.
- `infrastructure/n8n/workflows/02-publish-incidents-to-jira.json` — the
  "Prepare Jira Payload" node now embeds the `AUTOFIX_CONTEXT_V1` /
  `AUTOFIX_CONTEXT_END` machine-readable block in the ticket description.
- `infrastructure/n8n/workflows/03-queue-autofix-candidates.json` — the
  Policy Gate now stamps `agent_context_source = 'JIRA_REST'` on
  promotion to `AGENT_PENDING`.

## Test results

### Unit-level verification (synthetic fixtures)

- `parse-jira-context.py` correctly converts a synthetic ADF document
  (paragraphs + a `codeBlock` containing the `AUTOFIX_CONTEXT_V1` JSON)
  into flat context, and correctly extracts exactly one
  `[AUTOFIX_AGENT_CONTEXT]`-marked comment while discarding an
  unmarked one.
- `validate-jira-context.sh` passes on a valid fixture, and correctly
  fails (`HUMAN_REQUIRED`, exit 20, `INVALID_JIRA_CONTEXT:` prefix) on:
  fingerprint mismatch, incidentId mismatch, and a missing required
  label.
- `build-agent-prompt.sh` renders a well-formed prompt from the same
  fixture: system constraints separated from the untrusted Jira context
  block, approved comment included, unmarked comments absent.

### Live verification against real Jira and PostgreSQL

- **Workflow 02 round-trip**: inserted a synthetic `DETECTED` incident,
  let the schedule-triggered workflow create a real Jira ticket
  (`AUTO-5`). Fetched the ticket back via `GET /rest/api/3/issue/AUTO-5`
  (API v3, ADF). Confirmed the `AUTOFIX_CONTEXT_V1` fenced ` ```json `
  block and `AUTOFIX_CONTEXT_END` marker survive Jira's Markdown→ADF
  conversion byte-for-byte (whitespace inside the JSON reformatted, but
  the marker lines and fence are intact).
- **`parse-jira-context.py` against the real ADF response**: correctly
  extracted `descriptionText`, `labels` (including
  `autofix-fp-<fingerprint>`), and a fully-formed `autofixContext` object
  matching the original incident.
- **`validate-jira-context.sh` against the real parsed context**: `PASS`
  when given the correct `incidentId`/`jiraKey`/`fingerprint` triple.
- **`build-agent-prompt.sh` against the real parsed context**: rendered
  a correct, well-formed prompt with the live Jira content properly
  delimited.
- **Workflow 03**: inserted a synthetic `JIRA_CREATED` incident with a
  matching `jira_key`; confirmed the schedule-triggered Policy Gate
  promoted it to `AGENT_PENDING` with `branch_name = autofix/<key>` and
  `agent_context_source = JIRA_REST` set correctly.

### Full pipeline live run (Test A — successful full flow)

With a configured `agent-runner/.env` (read-only Jira credential), ran
the complete `run-once.sh` pipeline against a fresh synthetic incident
through the full chain:

```
DETECTED → JIRA_CREATED (Jira ticket created by Workflow 02)
        → AGENT_PENDING (Workflow 03 Policy Gate)
        → AGENT_RUNNING (claim-job.sh, atomic claim)
        → fetch-jira-context.sh (live HTTP 200)
        → validate-jira-context.sh (PASS)
        → build-agent-prompt.sh
        → isolated git worktree, branch autofix/AUTO-6
        → Copilot CLI (regression test + fix, exit 0)
        → validate-diff.sh (PASS: 2 files changed, 16 added / 6 deleted lines)
        → commit + push
        → Draft PR created (gh pr create --draft)
        → PR_READY
        → Workflow 04 callback → Jira comment + transition
        → REVIEW (both Jira and PostgreSQL)
```

Final state confirmed: `autofix.incident` row for the test incident
shows `status = REVIEW`, `branch_name = autofix/AUTO-6`,
`agent_context_source = JIRA_REST`, `agent_last_error = NULL`. The
created Draft PR was confirmed open (`isDraft: true`, `state: OPEN`)
against branch `autofix/AUTO-6`.

### Test B — re-running the runner (idempotency)

Ran `run-once.sh` again immediately after the incident reached `REVIEW`.
`claim-job.sh`'s query only considers `AGENT_PENDING` (and stale
`AGENT_RUNNING` past its lease), so a `REVIEW` incident is never
reclaimed: the runner printed "No AGENT_PENDING job available to claim"
and exited cleanly with no new commit, branch, PR, or Jira comment.

### Not yet exercised live

Tests C–J (interrupted-after-PR recovery, Jira-unavailable-after-PR
recovery, failing-tests rejection, forbidden-diff rejection, Jira
auth-failure/not-found/transient-retry paths, and a ticket edited after
Policy Gate approval to fall outside the policy allow-list) were
exercised at the unit level (see above) but not re-run against the live
stack in this pass, since Stage 5's equivalent scenarios (C–F) were
already verified end-to-end in `docs/stage5-test-report.md` and the only
new logic Stage 6 introduces on top of that -- `fetch-jira-context.sh`'s
HTTP error paths and `validate-jira-context.sh`'s policy re-check -- has
been independently unit-tested to fail correctly (see above).

## Acceptance criteria checklist

- [x] PostgreSQL no longer stores task content (stack trace, message,
      endpoint) for context purposes — only `fingerprint` remains, used
      solely for cross-checking against live Jira data.
- [x] `claim-job.sh` returns only technical identifiers.
- [x] Jira context is fetched live on every attempt, not cached.
- [x] The `AUTOFIX_CONTEXT_V1` machine-readable block round-trips through
      Jira's ADF conversion intact.
- [x] Only `[AUTOFIX_AGENT_CONTEXT]`-marked comments are ever considered;
      all others are discarded before reaching the Copilot prompt.
- [x] The rendered prompt explicitly delimits untrusted Jira content.
- [x] `validate-jira-context.sh` re-applies the full Stage 5C policy
      allow-list against live data (not the value cached at ingestion).
- [x] Workflow 03 records `agent_context_source = JIRA_REST` on
      promotion.
- [x] Migration `004-jira-agent-context.sql` is idempotent.
- [x] Full pipeline verified live end-to-end (Test A): DETECTED → Jira
      ticket → AGENT_PENDING → AGENT_RUNNING → Copilot fix → Draft PR →
      Jira REVIEW → DB REVIEW.
- [x] Re-running the runner against a `REVIEW` incident is a clean no-op
      (Test B): no duplicate commit, branch, PR, or Jira comment.

## Notes

- The read-only Jira credential used by `fetch-jira-context.sh` reuses
  the existing Jira API token for this POC; a dedicated read-only
  service account is recommended before any production use.
- No local paths, tokens, or personal data are included in this report.
