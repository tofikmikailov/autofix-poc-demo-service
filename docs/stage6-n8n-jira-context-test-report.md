# Stage 6B — Jira Credentials Only in n8n: Test Report

## Scope

Stage 6B removes the Agent Runner's own Jira REST credential entirely.
Where Stage 6's first version had `agent-runner/.env` hold
`JIRA_BASE_URL` / `JIRA_USER_EMAIL` / `JIRA_API_TOKEN`, Stage 6B moves
all Jira access into n8n: a new workflow, **`05 - Get AutoFix Ticket
Context`**, is the only place in the system (besides Workflow 04) that
holds a Jira credential. The Agent Runner authenticates to this local
webhook with a separate, non-Jira shared secret
(`AUTOFIX_RUNNER_WEBHOOK_TOKEN`).

```
claim-job.sh               → technical identifiers only, no task content
fetch-ticket-context.sh    → POST /webhook/autofix/ticket-context
                              (X-AutoFix-Runner-Token shared secret)
n8n Workflow 05            → validates request, fetches Jira issue +
                              comments (n8n's own Jira credential),
                              ADF → text, AUTOFIX_CONTEXT_V1 extraction,
                              [AUTOFIX_AGENT_CONTEXT] comment filter,
                              policy allow-list, sanitize/truncate,
                              SHA-256 contextHash
validate-ticket-response.sh → independent re-check: schema/provenance,
                              incidentId/jiraKey/fingerprint match,
                              allow-list, contextHash format, non-empty
                              stack trace
build-agent-prompt.sh      → sanitized prompt from the validated response
(unchanged Stage 5 pipeline continues: worktree → Copilot → Validation
 Gate → commit/push/PR → report-result.sh)
```

## Components delivered

- `infrastructure/n8n/workflows/05-get-autofix-ticket-context.json` — 24
  nodes: request validation (shared token + field shape), Jira issue
  fetch with `continueOnFail` classification of not-found vs. transient
  errors, Jira comment fetch (with `alwaysOutputData` so a ticket with
  zero comments still produces one empty item instead of halting the
  rest of the graph), ADF → text conversion, `AUTOFIX_CONTEXT_V1`
  extraction, approved-comment filtering, full re-application of the
  Stage 5C policy allow-list, sanitization/truncation, and a dedicated
  Crypto node (`SHA256`) for `contextHash` (Node.js's built-in `crypto`
  module is not available inside n8n Code nodes — confirmed empirically,
  throws "Error in workflow").
- `agent-runner/lib/fetch-ticket-context.sh` — replaces
  `fetch-jira-context.sh`. POSTs the claimed job's identifiers to the
  webhook; exit codes `0`/`2`/`3`/`4`/`20`/`1` as documented in the
  script header.
- `agent-runner/lib/validate-ticket-response.sh` — replaces
  `parse-jira-context.py` + `validate-jira-context.sh` as a single
  independent-judge script operating on n8n's sanitized response.
- `agent-runner/lib/build-agent-prompt.sh` — updated to read
  `{ticket, incident, approvedAgentContext}` instead of the old
  `{autofixContext, approvedComments}` shape.
- `agent-runner/schemas/ticket-context.schema.json` — new schema for the
  n8n response shape (replaces `jira-context.schema.json`).
- `agent-runner/run-once.sh` — rewired: steps 2–4 now call
  `fetch-ticket-context.sh` → `validate-ticket-response.sh` →
  `build-agent-prompt.sh`; new error-code handling
  (`TICKET_CONTEXT_AUTH_FAILED` → `AGENT_FAILED`, `JIRA_UNAVAILABLE` /
  n8n-unreachable → `AGENT_PENDING` with backoff, `JIRA_ISSUE_NOT_FOUND`
  / `INVALID_JIRA_CONTEXT` → `HUMAN_REQUIRED`); `agent_context_source`
  now recorded as `N8N_JIRA_PROXY`.
- `infrastructure/n8n/workflows/03-queue-autofix-candidates.json` — the
  Policy Gate node now stamps `agent_context_source = 'N8N_JIRA_PROXY'`.
- `agent-runner/lib/fetch-jira-context.sh`,
  `agent-runner/lib/parse-jira-context.py`,
  `agent-runner/lib/validate-jira-context.sh` — removed.
- No new PostgreSQL migration: the columns Stage 6B needs
  (`agent_context_source`, `jira_context_fetched_at`, `jira_context_hash`,
  `agent_next_attempt_at`) already exist from Stage 6's
  `004-jira-agent-context.sql`.

## Test results

### Workflow 05 — direct webhook tests

All exercised live against `http://localhost:5678/webhook/autofix/ticket-context`:

| Scenario | Expected | Result |
|---|---|---|
| Valid request, real ticket, no comments | 200, sanitized JSON, `approvedAgentContext: []` | PASS (after fixing the zero-comments bug below) |
| Valid request, real ticket, one approved + one unmarked comment | 200, `approvedAgentContext` contains only the approved text with the marker stripped | PASS |
| Wrong `X-AutoFix-Runner-Token` | 401 `UNAUTHORIZED` | PASS |
| Malformed request (bad `incidentId`/`jiraKey`/`fingerprint`/`branchName`) | 400 `INVALID_REQUEST` with per-field errors | PASS |
| Nonexistent Jira key | 404 `JIRA_ISSUE_NOT_FOUND` | PASS |
| Fingerprint mismatch (request fingerprint doesn't match ticket's context/label) | 422 `INVALID_JIRA_CONTEXT` | PASS |
| Ticket with no `AUTOFIX_CONTEXT_V1` block (pre-Stage-6 ticket) | 422 `UNSUPPORTED_JIRA_CONTEXT` | PASS |

**Bug found and fixed during testing:** the `Get Jira Comments` node,
using `runOnceForAllItems` downstream, produced **zero** output items
when a ticket had no comments at all. In n8n, a node with zero input
items simply does not execute, so every downstream node (ADF parsing,
context extraction, hash computation, the final Respond node) also
received zero items — the webhook returned **HTTP 200 with an
empty body** instead of the sanitized JSON. Fixed by setting
`alwaysOutputData: true` on the `Get Jira Comments` node, which forces
it to emit one empty item when it would otherwise emit none, keeping
the rest of the graph running. Verified fixed against a real ticket
with zero comments (see Test A below).

### Test A — full pipeline live run (successful full flow)

Inserted a fresh synthetic `DETECTED` incident directly into
PostgreSQL. Let the schedule-triggered Workflow 02 create a real Jira
ticket, then Workflow 03's Policy Gate promote it to `AGENT_PENDING`
with `agent_context_source = N8N_JIRA_PROXY`. Ran the complete
`run-once.sh` pipeline:

```
DETECTED → JIRA_CREATED (Workflow 02 creates the Jira ticket)
        → AGENT_PENDING (Workflow 03 Policy Gate, agent_context_source=N8N_JIRA_PROXY)
        → AGENT_RUNNING (claim-job.sh, atomic claim)
        → fetch-ticket-context.sh (POST to n8n Workflow 05, HTTP 200)
        → validate-ticket-response.sh (PASS)
        → build-agent-prompt.sh
        → isolated git worktree, new branch
        → Copilot CLI (regression test + fix, exit 0)
        → validate-diff.sh (PASS: 2 files changed, 15 added / 6 deleted lines)
        → commit + push
        → Draft PR created (gh pr create --draft)
        → PR_READY
        → Workflow 04 callback → Jira comment + transition
        → REVIEW (both Jira and PostgreSQL)
```

Final state confirmed: the incident row shows `status = REVIEW`,
`agent_context_source = N8N_JIRA_PROXY`, `agent_last_error = NULL`. The
Draft PR was created against the deterministic `autofix/<jira-key>`
branch. The Agent Runner's `.env` on the test host was confirmed to
contain **no** `JIRA_BASE_URL`/`JIRA_USER_EMAIL`/`JIRA_API_TOKEN` at any
point during this run.

### Test B — re-running the runner (idempotency)

Ran `run-once.sh` again immediately after the incident reached
`REVIEW`. `claim-job.sh` only considers `AGENT_PENDING` (and stale
`AGENT_RUNNING` past its lease); the runner printed "No AGENT_PENDING
job available to claim" and exited cleanly — no new commit, branch, PR,
or Jira comment.

### Not yet exercised live in this pass

Tests C–L from the original spec (interrupted-after-PR recovery,
Jira-unavailable-after-PR recovery, n8n-itself-unreachable retry/backoff,
failing-tests rejection, forbidden-diff rejection, a ticket edited after
Policy Gate approval to fall outside the allow-list, webhook token
rotation) reuse Stage 5's and Stage 6's already-verified recovery paths
(`create-pr.sh`'s idempotent PR lookup by branch, `validate-diff.sh`'s
policy checks, `mark-incident-failed.sh`'s backoff schedule) and were
not independently re-run end-to-end in this session; the underlying
mechanisms are unchanged from Stage 5/6 and were exercised there.

## Security notes

- Confirmed via `grep` that no committed file (workflow JSON, scripts,
  README, this report) contains a real Jira API token, the real
  `AUTOFIX_RUNNER_WEBHOOK_TOKEN` value, or any `/Users/...` /
  `atlassian.net` account-specific path.
- The exported `05-get-autofix-ticket-context.json` references the
  existing Jira credential only by `id`/`name` (`Jira SW Cloud
  account`) — no credential value is present in the export.
- The local, gitignored `agent-runner/.env` was stripped of the
  Stage-6-v1 Jira credential fields (`JIRA_BASE_URL`, `JIRA_USER_EMAIL`,
  `JIRA_API_TOKEN`, `JIRA_PROJECT_KEY`) as part of this change, even
  though it was never committed.
