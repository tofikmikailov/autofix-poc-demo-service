# Stage 5 — AutoFix Agent Runner: End-to-End Test Report

## Scope

Stage 5 automates the segment of the AutoFix pipeline between a triaged Jira
incident and a human-reviewable Draft Pull Request:

```
Jira ticket (JIRA_CREATED)
        ↓
Policy Gate (Workflow 03)
        ↓
Host Agent Runner (claim → worktree → Copilot CLI → validation)
        ↓
branch + commit + push
        ↓
Draft Pull Request
        ↓
Jira comment + transition to REVIEW (Workflow 04)
        ↓
Human code review
```

No automatic merge, deployment, or push to `main` occurs at any point.
Copilot CLI has no Jira, GitHub, or MCP access; it operates only on an
isolated Git worktree with a restricted tool allow-list.

## Components delivered

- `agent-runner/` — Bash-based orchestrator (`run-once.sh` + `lib/*.sh`)
  implementing claim, worktree isolation, Copilot invocation, an independent
  Validation Gate, commit/push, idempotent Draft PR creation, and result
  reporting to n8n.
- `infrastructure/postgres/init/003-agent-processing.sql` — adds the
  AutoFix processing state machine (`AGENT_PENDING`, `AGENT_RUNNING`,
  `PR_READY`, `REVIEW`, `HUMAN_REQUIRED`, `AGENT_FAILED`) and supporting
  columns (`branch_name`, `agent_attempt_count`, `agent_claimed_at`,
  `agent_started_at`, `agent_completed_at`, `agent_last_error`,
  `agent_result`) to `autofix.incident`. Verified idempotent (safe to
  re-run against a live database).
- `infrastructure/n8n/workflows/03-queue-autofix-candidates.json` — Policy
  Gate workflow: promotes an eligible `JIRA_CREATED` incident to
  `AGENT_PENDING`, or routes it to `HUMAN_REQUIRED` with a recorded
  rejection reason.
- `infrastructure/n8n/workflows/04-finalize-autofix-review.json` — receives
  the runner's PR-ready callback, posts an idempotent Jira comment with the
  PR link, transitions the Jira issue to `REVIEW`, and updates the
  incident's orchestration state in PostgreSQL.

## Test results

All tests below were executed against a live local stack (PostgreSQL, n8n,
Jira Cloud sandbox project, and a real GitHub repository) using the actual
runner scripts — not mocked.

### Test A — successful full flow

Incident in `JIRA_CREATED` → Policy Gate approval → `AGENT_PENDING` →
runner claim → `AGENT_RUNNING` → isolated worktree → Copilot CLI added a
regression test and a minimal fix → independent test run passed →
Validation Gate passed → branch pushed → Draft PR created → PR-ready
webhook delivered → Jira comment added → Jira transitioned to `REVIEW` →
incident status updated to `REVIEW` in PostgreSQL.

**Result: PASS.**

### Test B — re-running the runner against an already-completed incident

Running the orchestrator again for the same incident did not create a new
commit, a second Draft PR, or a duplicate Jira comment. The runner detects
the existing branch/PR and short-circuits via its reconciliation path.

**Result: PASS.**

### Test C — interrupted after PR creation

The runner process was terminated immediately after `gh pr create`. On the
next run, the existing PR was found by branch name (`gh pr list --head`),
no duplicate branch or PR was created, and Jira was updated correctly.

**Result: PASS.**

### Test D — Jira temporarily unavailable after PR creation

With the PR already created, the Jira-callback step was simulated as
failing. The incident correctly remained in `PR_READY`. Once Jira access
was restored, replaying the callback added exactly one comment and
transitioned the ticket to `REVIEW`, with the incident updated to `REVIEW`.

**Result: PASS.**

### Test E — regression test still fails after the fix attempt

Using a synthetic incident and a fix attempt that left a failing test in
place, the orchestrator ran the full pipeline (claim → worktree →
independent `./gradlew clean test`). The Validation Gate detected the test
failure and set the incident to `HUMAN_REQUIRED`. No push, no branch on
the remote, and no Pull Request were created.

**Result: PASS.**

### Test F — forbidden file modified

Using a synthetic incident and a change that touched a disallowed
infrastructure file, the Validation Gate rejected the diff with
`POLICY_VIOLATION: prohibited file <path>`, set the incident to
`HUMAN_REQUIRED`, and did not push or create a Pull Request. The base
branch remained untouched.

**Result: PASS.**

## Acceptance criteria checklist

- [x] Jira has a working `REVIEW` status/transition.
- [x] A `JIRA_CREATED` incident passes through the Policy Gate.
- [x] An approved incident is promoted to `AGENT_PENDING`.
- [x] The runner atomically claims exactly one job (`FOR UPDATE SKIP LOCKED`).
- [x] A deterministic branch name is derived from the Jira key.
- [x] Work happens in an isolated Git worktree.
- [x] Copilot CLI has no Git, GitHub, Jira, or MCP access
      (`--disable-builtin-mcps`, restricted tool allow-list).
- [x] Copilot CLI adds a regression test.
- [x] Copilot CLI applies a minimal fix.
- [x] The runner independently re-runs the full test suite.
- [x] Disallowed changes are blocked by the Validation Gate.
- [x] Commit and push only occur after validation passes.
- [x] Exactly one Draft Pull Request is created.
- [x] A retry reuses the existing PR found by branch name.
- [x] Jira receives exactly one comment containing the PR link.
- [x] Jira is transitioned to `REVIEW`.
- [x] PostgreSQL stores orchestration state; the PR URL is not persisted
      as a required or authoritative field.
- [x] Partial failure after PR creation recovers correctly on retry.
- [x] No automatic merge occurs at any stage.
- [x] A human reviewer receives a ready-to-review Draft Pull Request.

## Notes

- All incident/branch identifiers referenced above (`AUTO-3`,
  `autofix/AUTO-3`) belong to a demo Jira project created for this POC.
- Runner configuration (repository path, base branch, runtime directory,
  database connection, n8n callback URL) is supplied entirely through
  environment variables (`AUTOFIX_REPO`, `AUTOFIX_BASE_BRANCH`,
  `AUTOFIX_ROOT`, `DATABASE_URL`/`PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`,
  `N8N_RESULT_WEBHOOK_URL`) — no host-specific paths are hardcoded in the
  committed scripts or workflows.
- The demo Draft Pull Request produced by Test A is intentionally left
  open (not merged) so the intentional defect and the AutoFix flow remain
  reproducible for future demonstrations.
