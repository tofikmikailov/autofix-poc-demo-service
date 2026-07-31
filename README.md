# autofix-demo-service

Demonstration Spring Boot microservice used as a proof of concept for an
automated error-handling / AutoFix pipeline:

```text
Error occurs → structured log → Elasticsearch/Kibana detection →
Jira ticket → coding agent fix + regression test → draft Pull Request
```

This repository covers the first stage: a working Spring Boot service with a
controlled runtime error, structured JSON logging, baseline tests, Docker
support, and Copilot instructions. Elasticsearch, Kibana, Logstash and Jira
integrations are added in later stages and are **not** part of this service.

## Tech stack

Java 21, Spring Boot 3, Gradle Wrapper, Spring Web, Spring Boot Actuator,
Logback (JSON via logstash-logback-encoder), JUnit 5, AssertJ, Mockito.

## Local run

```bash
./gradlew bootRun
```

The service starts on port `8080` (override with `SERVER_PORT`).

## Running tests

```bash
./gradlew clean test
```

## Check the successful endpoint

```bash
curl http://localhost:8080/api/customers/100/display-name
```

## Trigger the controlled error

Customer `200` has no `firstName` and deterministically triggers a
`NullPointerException` in `CustomerService`, which is converted into a safe
HTTP `500` response by the global exception handler. The full stack trace is
only written to the JSON log.

```bash
curl \
  -H "X-Correlation-ID: poc-error-001" \
  http://localhost:8080/api/customers/200/display-name
```

## Generate multiple errors

```bash
curl \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "200",
    "count": 5
  }' \
  http://localhost:8080/api/demo/generate-errors
```

## Health check

```bash
curl http://localhost:8080/actuator/health
```

## Correlation ID

Every request is tagged with a correlation ID:

* if the `X-Correlation-ID` request header is present, it is reused;
* otherwise a new UUID is generated;
* the value is returned in the `X-Correlation-ID` response header and
  included in every related JSON log line and error response.

## API error format

All unhandled exceptions are converted to a single JSON error format:

```json
{
  "timestamp": "2026-07-29T11:00:00Z",
  "status": 500,
  "error": "Internal Server Error",
  "code": "UNEXPECTED_ERROR",
  "message": "Unexpected application error",
  "path": "/api/customers/200/display-name",
  "correlationId": "7b32f08c-..."
}
```

No stack trace is ever returned to the client; it is only present in the
JSON logs written to stdout.

## Docker

```bash
docker build -t autofix-demo-service:local .

docker run \
  --rm \
  -p 8080:8080 \
  -e APP_ENVIRONMENT=local \
  autofix-demo-service:local
```

## Stage 3B: Elasticsearch polling and incident deduplication

An n8n workflow (`infrastructure/n8n/workflows/01-detect-and-deduplicate-errors.json`)
polls Elasticsearch for `ERROR` events, normalizes each error, computes a
SHA-256 fingerprint, and atomically claims/upserts an `autofix.incident` row
in PostgreSQL:

```
Manual Trigger ──────────┐
                          ▼
Schedule Trigger → Search Elasticsearch
                          ↓
                Split Elasticsearch Hits
                          ↓
                   Normalize Error
                          ↓
                Calculate Fingerprint
                          ↓
                 Claim & Upsert Incident
                          ↓
                  Is New Incident?
                   ├── true  → New Incident
                   └── false → Existing Incident
```

**Fingerprint composition:** `service + environment + exceptionType +
normalizedExceptionMessage + firstApplicationStackFrame + requestPath`.
Timestamps, correlation IDs, customer IDs, Elasticsearch document IDs, and
Java line numbers are intentionally excluded so identical logical errors
collapse into one incident.

**Deduplication is two-layered:**
- `autofix.processed_log_event` — has this specific Elasticsearch document
  already been handled? (keyed on `elasticsearch_id`)
- `autofix.incident` — has this logical error been seen before? (keyed on
  `fingerprint`; increments `occurrence_count` instead of creating a
  duplicate incident)

Both writes happen in one SQL statement (`Claim & Upsert Incident` node), so
a failed incident upsert also rolls back the processed-event claim — a
document is never silently marked "processed" without a corresponding
incident.

### Import the workflow

```bash
docker cp infrastructure/n8n/workflows/01-detect-and-deduplicate-errors.json autofix-n8n:/tmp/workflow.json
docker exec autofix-n8n n8n import:workflow --input=/tmp/workflow.json
```

### Verified test results (headless, via `n8n execute` CLI)

- **Test A** (one error): 1 `incident` row, 1 `processed_log_event` row,
  `occurrence_count = 1`, `status = DETECTED`, fingerprint is a 64-char hex
  SHA-256 string.
- **Test B** (re-run, no new errors): counts unchanged; the Postgres node
  emits zero output items for the already-processed document.
- **Test C** (5 identical bulk errors): the 5 documents collapse into a
  single incident with `occurrence_count = 5`; `processed_log_event` grows
  by 5.
  - Note: in this POC, `GET /api/customers/.../display-name` and
    `POST /api/demo/generate-errors` produce different `requestPath`
    values (and the bulk endpoint's log line doesn't include
    `requestPath`/`httpMethod` at all), so they fingerprint as two
    *separate* incidents rather than one. This is expected given the
    fingerprint definition above — request path is intentionally part of
    the fingerprint — not a workflow defect.

### Excluding the technical bulk-generation endpoint

`POST /api/demo/generate-errors` is a test-only endpoint for exercising
deduplication (Test C). Its errors should never become real incidents once
Jira ticket creation is wired up, so the **Search Elasticsearch** query
excludes them with a `must_not` clause:

```json
"must_not": [
  { "term": { "logger.keyword": "com.example.autofixdemo.controller.DemoController" } }
]
```

Note this filters on `logger`, not `requestPath`: the bulk endpoint's log
entries never populate `requestPath` at all (it's an empty field, not the
literal string `/api/demo/generate-errors`), so a `requestPath.keyword`
filter would silently do nothing. `logger` reliably distinguishes the
technical endpoint (`DemoController`) from the real business error path
(`GlobalExceptionHandler`), which does set `requestPath`.

Verified: after adding the filter, generating bulk errors no longer creates
`processed_log_event`/`incident` rows, while errors from
`/api/customers/{id}/display-name` continue to be captured normally.

### Activating the schedule

n8n 2.x tracks trigger activation through its own workflow-publication
pipeline (`workflow_history` / `workflow_published_version` /
`workflow_publication_trigger_status`), not a simple boolean flag, so this
must be toggled from the UI rather than by editing the database directly:

1. Open the workflow in n8n.
2. Toggle **Active** (top right).
3. Confirm new `execution_entity` rows appear with `mode = trigger` roughly
   once a minute.

Current POC limits: 15-minute lookback window, 100 documents per run,
single n8n instance. A persistent cursor (`search_after` / last-seen
timestamp) will replace the overlapping time-window approach in a later
stage.

## Stage 4B: Publishing incidents to Jira

A second, independent n8n workflow
(`infrastructure/n8n/workflows/02-publish-incidents-to-jira.json`) claims
`DETECTED` incidents and publishes them to Jira Cloud (project `AUTO`) as
issues, with effectively-once delivery even across transient Jira
failures. It is deliberately **not** merged into workflow 01: if Jira is
temporarily unavailable, an incident must stay claimable rather than being
marked "already handled".

```
01 - Detect and Deduplicate Elastic Errors
                    ↓
          PostgreSQL incident (DETECTED)
                    ↓
02 - Publish Incidents to Jira
                    ↓
               AUTO-<n>
```

### Workflow 02 pipeline

```
Manual Trigger ─┐
Schedule Trigger┴→ Claim Jira Incident (Postgres, FOR UPDATE SKIP LOCKED)
                          ↓
                  Incident Claimed? (IF: $json.id exists)
                   ├── false → stop (nothing to publish)
                   └── true
                          ↓
                  Prepare Jira Payload (Code: summary/description/labels)
                          ↓
                  Search Jira by Fingerprint (JQL on autofix-fp-<hash> label)
                          ↓
                  Jira Ticket Exists? (IF: $json.key exists)
                   ├── true  → Link Existing Jira (Postgres)
                   └── false → Create Jira Issue (Jira) → Link Created Jira (Postgres)
```

### Lifecycle states

```
DETECTED → JIRA_PENDING → JIRA_CREATED
                ↓ (lease expires after 10 min)
          reclaimed → Search Jira by fingerprint → JIRA_CREATED
```

`Claim Jira Incident` atomically selects one incident (`DETECTED`,
`JIRA_FAILED`, or a `JIRA_PENDING` row whose `jira_claimed_at` is older
than 10 minutes — a stale lease) and flips it to `JIRA_PENDING`,
incrementing `jira_attempt_count`. `FOR UPDATE SKIP LOCKED` guarantees two
concurrent executions never claim the same row. If the Jira nodes fail
(no `Continue On Fail`), the execution errors out and the incident is left
in `JIRA_PENDING` — safely reclaimable after the lease expires.

Every publish attempt searches Jira by the exact fingerprint label
(`autofix-fp-<sha256>`) *before* creating an issue. This makes ticket
creation effectively-once: even if Jira successfully creates an issue but
n8n never receives the response (network/timeout), the next attempt finds
the existing ticket by fingerprint and links it instead of creating a
duplicate.

### Migration

`infrastructure/postgres/init/002-jira-publishing.sql` extends the
`incident` table for this lifecycle: new status values
(`JIRA_PENDING`/`JIRA_FAILED`/`AGENT_*`/`PR_CREATED`/`HUMAN_REQUIRED`/
`COMPLETED`/`FAILED`), plus `jira_attempt_count`, `jira_claimed_at`,
`jira_last_attempt_at`, `jira_created_at`, `jira_last_error`, and a
partial index `idx_incident_jira_queue` for the claim query. Since init
scripts only run against an empty Postgres volume, apply it manually to an
existing volume:

```bash
cd infrastructure
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  < postgres/init/002-jira-publishing.sql
```

### A note on n8n's Postgres node and 0-row writes

For Postgres node `typeVersion >= 2.3`, a non-`SELECT` query (e.g. our
`UPDATE ... RETURNING` claim query) that affects **zero rows** still emits
one output item (`{success: true}`) instead of zero items — only pure
`SELECT`s correctly emit 0 items for 0 rows. Relying on "0 items = stop
the workflow" after a claim query is therefore unsafe and, in early
testing, caused a spurious duplicate Jira ticket when no incident was
actually claimed. The fix is the explicit `Incident Claimed?` IF node
right after `Claim Jira Incident`, checking `{{ $json.id }}` with the
`exists` operator — this is the correct way to detect "nothing claimed"
for any future Postgres claim/upsert pattern in this project.

### Verified test results (headless, via `n8n execute` CLI)

- **Test A** (new `DETECTED` incident): claimed, `Create Jira Issue` ran,
  ticket `AUTO-3` created, `status = JIRA_CREATED`,
  `jira_attempt_count = 1`.
- **Test B** (immediate re-run): 0 incidents claimed, `Incident Claimed?`
  correctly stops the run, no new ticket, `jira_attempt_count` unchanged.
- **Test C** (reconciliation — `jira_key`/`status` cleared in Postgres
  only, simulating a lost Jira response): `Search Jira by Fingerprint`
  found `AUTO-3`, `Create Jira Issue` was **not** called, `Link Existing
  Jira` restored `jira_key`. Exactly one Jira issue carries the
  fingerprint label throughout.
- **Test D** (stale claim retry — `status = JIRA_PENDING` with
  `jira_claimed_at` 11 minutes in the past): incident reclaimed by the
  lease-expiry branch, existing ticket found by fingerprint search,
  `jira_key` restored, no duplicate created.

### Activating the schedule

Same as workflow 01 — toggle **Active** from the n8n UI (raw SQL flag
edits do not reliably (de)register n8n's schedule trigger in this
version). Workflow 02 runs once a minute, independently of workflow 01, so
Jira outages never block error ingestion into `autofix.incident`.

## Stage 5: Local AutoFix Agent Runner and Jira review workflow

Stage 5 automates the segment of the pipeline between a triaged Jira
incident and a human-reviewable Draft Pull Request. Nothing merges
automatically and Copilot CLI never has direct access to Jira, GitHub, or
any MCP server.

```
Jira ticket (JIRA_CREATED)
        ↓
Policy Gate (Workflow 03)
        ↓
Agent Runner (claim → worktree → Copilot CLI → validation)
        ↓
branch + commit + push
        ↓
Draft Pull Request
        ↓
Jira comment + transition to REVIEW (Workflow 04)
        ↓
Human code review
```

> **Superseded by Stage 7.** Stage 5 originally ran the runner as a Bash
> script directly on a developer machine (`agent-runner/`). Stage 7 (below)
> replaced that host process with a persistent, containerized
> `autofix-agent` service dispatched over HTTP from n8n Workflow 03; the
> `agent-runner/` directory has been removed. The pipeline stages,
> Validation Gate rules, and no-auto-merge guarantee described below are
> unchanged — only *where* the runner executes changed.

### Components (original, host-based — see Stage 7 for the current architecture)

- **`agent-runner/`** *(removed — see Stage 7)* — a local Bash + `jq` +
  `psql` orchestrator that ran on a developer machine (where Copilot CLI,
  `git`, `gh`, and repository credentials already lived). Entry point:
  `agent-runner/run-once.sh`. Library scripts in `agent-runner/lib/`
  implemented each stage: `claim-job.sh`, `prepare-worktree.sh`,
  `run-copilot.sh`, `validate-diff.sh`, `create-pr.sh`, `report-result.sh`.
- **`infrastructure/postgres/init/003-agent-processing.sql`** — adds the
  AutoFix processing state machine to `autofix.incident`
  (`AGENT_PENDING` → `AGENT_RUNNING` → `PR_READY` → `REVIEW`, with
  `HUMAN_REQUIRED`/`AGENT_FAILED` as terminal failure states), plus
  `branch_name`, `agent_attempt_count`, `agent_claimed_at`,
  `agent_started_at`, `agent_completed_at`, `agent_last_error`, and a
  `agent_result` JSONB summary column. The migration is safe to re-run
  against an existing database.
- **`infrastructure/n8n/workflows/03-queue-autofix-candidates.json`** — a
  Policy Gate: promotes an eligible `JIRA_CREATED` incident to
  `AGENT_PENDING`, or routes it to `HUMAN_REQUIRED` with a recorded
  rejection reason. Only a narrow, hard-coded class of incidents is
  auto-eligible; entire categories (auth, payments, infrastructure,
  database migrations, dependency upgrades, secrets, etc.) are always
  excluded.
- **`infrastructure/n8n/workflows/04-finalize-autofix-review.json`** —
  receives the runner's PR-ready callback (`POST
  /webhook/autofix/pr-ready`), adds an idempotent Jira comment containing
  the PR link (guarded by a `[autofix-pr:<jira-key>]` marker), transitions
  the Jira issue to `REVIEW` (looked up by target status name, not a
  hard-coded transition ID), and updates the incident's orchestration
  state in PostgreSQL.

### Agent Runner pipeline

```
claim-job.sh       AGENT_PENDING → AGENT_RUNNING (FOR UPDATE SKIP LOCKED, atomic)
prepare-worktree.sh  isolated `git worktree` on branch autofix/<JIRA-KEY>
run-copilot.sh      Copilot CLI, non-interactive (-p), restricted tool
                    allow-list, --disable-builtin-mcps: no git/gh/curl/
                    ssh/kubectl/docker/psql, no Jira or GitHub access
validate-diff.sh    independent Validation Gate (see below)
create-pr.sh        commit + push + idempotent Draft PR (found by branch
                    name via `gh pr list --head`, or created via
                    `gh pr create --draft`)
report-result.sh    POST result to n8n Workflow 04
```

### Validation Gate

The runner never trusts Copilot's own "tests passed" claim. Before any
commit, push, or PR is created it independently verifies:

1. A non-empty diff exists.
2. Only allowed paths were touched (`src/main/java/**`, `src/test/java/**`,
   optionally `README.md`); infrastructure, build, and config files are
   rejected.
3. Diff size limits (files changed, lines changed, production classes
   touched).
4. At least one test file was changed (a regression test is mandatory).
5. No disallowed constructs appear in the diff (`@Disabled`, `skipTests`,
   `-x test`, `System.exit`, `Thread.sleep`, ignored exception catches,
   etc.).
6. The full test suite (`./gradlew clean test`) passes independently of
   Copilot's own run.

Only the runner decides `PASS` (commit/push/PR) or `FAIL`
(`HUMAN_REQUIRED` / `AGENT_FAILED`).

### Configuration

All host-specific values are supplied via environment variables — no
paths, hostnames, or credentials are hard-coded in the committed scripts
or workflows:

| Variable | Purpose |
|---|---|
| `AUTOFIX_REPO` | Path to the local clone of this repository |
| `AUTOFIX_BASE_BRANCH` | Base branch for worktrees/PRs (default `main`) |
| `AUTOFIX_ROOT` | Runtime directory for worktrees, logs, results, locks |
| `DATABASE_URL` / `PGHOST` / `PGPORT` / `PGUSER` / `PGDATABASE` | Postgres connection |
| `N8N_RESULT_WEBHOOK_URL` | n8n Workflow 04 callback (`/webhook/autofix/pr-ready`) |
| `JIRA_BASE_URL` | Jira Cloud tenant base URL (used by n8n workflow 04) |

### Running the agent runner

*(Historical — this host script no longer exists. See
[Stage 7](#stage-7-containerized-autofix-agent) for how to run the
current `autofix-agent` container.)*

```bash
export AUTOFIX_REPO=/path/to/autofix-poc-demo-service
export AUTOFIX_BASE_BRANCH=main
export AUTOFIX_ROOT=~/autofix-poc
export PGHOST=localhost PGPORT=5432 PGUSER=... PGDATABASE=...
export N8N_RESULT_WEBHOOK_URL=http://localhost:5678/webhook/autofix/pr-ready

./agent-runner/run-once.sh
```

Re-running the script is safe: it reconciles against any existing branch
or Draft PR instead of duplicating work.

### Test results

See [`docs/stage5-test-report.md`](docs/stage5-test-report.md) for the
full Stage 5 end-to-end test report (successful flow, idempotent re-run,
interrupted-after-PR recovery, Jira-unavailable recovery, failing-tests
rejection, and forbidden-diff rejection).

## Scope of Stage 5

Not included at this stage: automatic merge, automatic deployment, direct
push to `main`, and Copilot CLI access to Jira, GitHub, Kubernetes, or
Docker. A human always reviews and merges the Draft Pull Request.


## Stage 6: Jira as the source of task context

Stage 5 stored the incident's stack trace, message, and endpoint in
PostgreSQL, and the Agent Runner read that snapshot when building the
Copilot prompt. Stage 6 removes that duplication: **PostgreSQL now holds
only orchestration state** (status, branch name, attempt count, timing,
a `fingerprint` used only for cross-checking). The actual task context —
exception type, message, stack trace, endpoint — is fetched **live from
Jira** on every run and treated as untrusted external input until
validated.

An initial version of Stage 6 (superseded by Stage 6B below) had the
Agent Runner call Jira REST directly with its own read-only credential.
Stage 6B replaced that with an n8n-brokered fetch so that **no Jira
credential ever needs to exist on the Agent Runner host** — see below.

### Why Jira, not PostgreSQL

- A ticket can be edited by a human after triage (e.g. to add
  clarifying comments) — re-reading Jira on every attempt picks that up;
  a PostgreSQL snapshot taken at ingestion time would not.
- It removes an entire class of drift: the Jira ticket a reviewer reads
  and the data Copilot acted on are now guaranteed to be the same
  content, not two independently-evolving copies.
- It forces an explicit trust boundary: everything that reaches Copilot's
  prompt has passed through a parser and a validation gate, rather than
  being implicitly trusted because it came from "our own" database.

### Prompt-injection protection

Jira ticket content is external, human-editable input and is never
trusted outright:

- Only comments whose text begins with the literal marker
  `[AUTOFIX_AGENT_CONTEXT]` are extracted; the marker is stripped and the
  remainder is passed through. Every other comment is silently discarded
  and never reaches Copilot.
- The rendered prompt explicitly wraps all Jira-derived content in
  `<UNTRUSTED_JIRA_CONTEXT>...</UNTRUSTED_JIRA_CONTEXT>` and instructs
  Copilot to treat it as descriptive text only, never as operational
  instructions.
- The fetched context is independently re-verified against the same
  Stage 5C policy allow-list (service, environment, exception type,
  request path) — a ticket edited after Policy Gate approval to fall
  outside policy is rejected before Copilot ever runs.

### Configuration additions

| Variable | Purpose |
|---|---|
| `ALLOW_LEGACY_DB_CONTEXT_FALLBACK` | Must remain `false`; documents that there is deliberately no fallback to the old PostgreSQL-snapshot behavior |

See `agent-runner/.env.example` for the full list.

### Test results

See
[`docs/stage6-jira-context-test-report.md`](docs/stage6-jira-context-test-report.md)
for the original (superseded) direct-Jira-REST test report, and
[`docs/stage6-n8n-jira-context-test-report.md`](docs/stage6-n8n-jira-context-test-report.md)
for the current Stage 6B (n8n-brokered) test report.

## Scope of Stage 6

Not included at this stage: storage of Jira content in PostgreSQL (only
a `fingerprint` cross-check remains), and any change to Stage 5's
no-auto-merge / human-review guarantees.

## Stage 6B: Jira credentials live only in n8n

Stage 6's first version had the Agent Runner hold its own read-only
Jira REST credential (`JIRA_BASE_URL` / `JIRA_USER_EMAIL` /
`JIRA_API_TOKEN`). Stage 6B removes that credential from the Agent
Runner entirely: **Jira credentials exist only inside n8n.** The Agent
Runner instead calls a local n8n webhook, authenticated with a separate,
non-Jira shared secret that can be rotated or revoked without touching
any Jira credential.

```
claim-job.sh               claims a job, returns only technical identifiers
                            (incidentId, jiraKey, fingerprint, branchName,
                            agentAttemptCount) -- no task content
        ↓
fetch-ticket-context.sh     POST /webhook/autofix/ticket-context
                            (X-AutoFix-Runner-Token shared secret --
                            NOT a Jira credential; the only network call
                            the Agent Runner makes for task context)
        ↓
n8n Workflow 05             "Get AutoFix Ticket Context": validates the
("05 - Get AutoFix           request, fetches the Jira issue + comments
 Ticket Context")            using n8n's own Jira credential, converts
                             ADF → text, extracts the AUTOFIX_CONTEXT_V1
                             block and only [AUTOFIX_AGENT_CONTEXT]
                             comments, re-applies the policy allow-list,
                             sanitizes/truncates every field, computes a
                             SHA-256 contextHash, and returns one
                             sanitized JSON response (200) or a
                             structured error (400/401/404/422/503)
        ↓
validate-ticket-response.sh independently re-checks the n8n response:
                            schema/provenance, jiraKey/incidentId/
                            fingerprint match the claimed job, allow-list,
                            contextHash format, non-empty stack trace
        ↓
build-agent-prompt.sh      renders the Copilot prompt from the validated
                            response only, Jira content still delimited
                            as <UNTRUSTED_JIRA_CONTEXT>...</UNTRUSTED_JIRA_CONTEXT>
        ↓
(unchanged Stage 5 pipeline: worktree → Copilot CLI → Validation Gate →
 commit/push/Draft PR → report-result.sh)
```

### Why move Jira credentials into n8n

- **Smaller blast radius.** If the Agent Runner host or its `.env` is
  ever compromised, no Jira credential is exposed — only a revocable
  local webhook token that cannot read or write Jira at all by itself.
- **One place to audit/rotate Jira access.** n8n already holds the
  write-side Jira credential (Workflow 04's comment + transition);
  Stage 6B makes it the sole holder of the read-side credential too.
- **Same validation guarantees, one more independent check.** n8n
  applies the policy allow-list once; `validate-ticket-response.sh`
  re-applies it a second time on the Agent Runner side before Copilot
  ever runs, so a compromised or buggy n8n workflow alone cannot smuggle
  an out-of-policy ticket through.

### New/changed components

- **`infrastructure/n8n/workflows/05-get-autofix-ticket-context.json`**
  — new workflow, the only place in the whole system besides Workflow 04
  that holds a Jira credential. Validates the incoming request (shared
  token, `incidentId`/`jiraKey`/`fingerprint`/`branchName` shape),
  fetches the issue + comments, converts ADF → text, extracts the
  `AUTOFIX_CONTEXT_V1` block and `[AUTOFIX_AGENT_CONTEXT]`-marked
  comments only, re-applies the Stage 5C policy allow-list, sanitizes
  and truncates every field (summary 300 chars, normalized message 2000,
  application frame 1000, stack trace 12000, each approved comment 2000,
  approved comments total 6000), and computes a SHA-256 `contextHash`
  over the normalized fields using n8n's dedicated Crypto node (Node.js
  built-in `crypto` is not available inside n8n Code nodes).
- **`agent-runner/lib/fetch-ticket-context.sh`** — replaces
  `fetch-jira-context.sh`. POSTs to the local n8n webhook with the
  shared `X-AutoFix-Runner-Token`; exit codes: `0` success, `2`
  transient/retryable (n8n reports `JIRA_UNAVAILABLE`, or n8n itself is
  unreachable), `3` webhook auth failure (permanent), `4` Jira issue not
  found (permanent), `20` invalid/unsupported ticket context (permanent),
  `1` unexpected hard failure.
- **`agent-runner/lib/validate-ticket-response.sh`** — replaces
  `parse-jira-context.py` + `validate-jira-context.sh`. Re-validates the
  n8n response's schema/provenance, cross-checks it against the claimed
  job, re-applies the policy allow-list, and confirms a non-empty stack
  trace — the second independent judge in the pipeline
  (`validate-diff.sh` being the first for the code change itself).
- **`agent-runner/lib/build-agent-prompt.sh`** — updated to read the new
  `{schemaVersion, source, ticket, incident, approvedAgentContext,
  contextHash}` response shape instead of the old parsed-Jira-context
  shape.
- **`agent-runner/schemas/ticket-context.schema.json`** — replaces
  `jira-context.schema.json`, documenting the new n8n response shape.
- **`agent-runner/lib/fetch-jira-context.sh`,
  `agent-runner/lib/parse-jira-context.py`,
  `agent-runner/lib/validate-jira-context.sh`** — removed; superseded by
  the components above.
- **`infrastructure/n8n/workflows/03-queue-autofix-candidates.json`** —
  the Policy Gate now stamps `agent_context_source = 'N8N_JIRA_PROXY'`
  (was `'JIRA_REST'`) when promoting an incident to `AGENT_PENDING`.
- No new PostgreSQL migration was needed: the columns Stage 6B relies on
  (`agent_context_source`, `jira_context_fetched_at`, `jira_context_hash`,
  `agent_next_attempt_at`) were already added by Stage 6's
  `004-jira-agent-context.sql`. Only the *value* written to
  `agent_context_source` changed.

### Configuration additions

| Variable | Purpose |
|---|---|
| `N8N_TICKET_CONTEXT_WEBHOOK_URL` | Local n8n webhook URL for Workflow 05 (`http://localhost:5678/webhook/autofix/ticket-context`) |
| `AUTOFIX_RUNNER_WEBHOOK_TOKEN` | Shared secret between the Agent Runner and n8n Workflow 05 (sent as `X-AutoFix-Runner-Token`); generate with `openssl rand -hex 32`. Must match `infrastructure/.env`'s copy exactly. **Not a Jira credential.** |
| `N8N_CONNECT_TIMEOUT_SECONDS` / `N8N_REQUEST_TIMEOUT_SECONDS` / `N8N_MAX_RETRIES` | Transient-failure retry tuning for `fetch-ticket-context.sh` |

`agent-runner/.env` no longer contains (and must never contain again)
`JIRA_BASE_URL`, `JIRA_USER_EMAIL`, or `JIRA_API_TOKEN`. See
`agent-runner/.env.example` for the full list.

### Test results

See
[`docs/stage6-n8n-jira-context-test-report.md`](docs/stage6-n8n-jira-context-test-report.md)
for the Stage 6B test report.

## Scope of Stage 6B

Not included at this stage: rotating the shared webhook token
automatically, rate-limiting the webhook beyond n8n's defaults, and any
change to Stage 5's no-auto-merge / human-review guarantees.

## Stage 7: Containerized AutoFix Agent

Stages 5/6/6B ran the Agent Runner as a Bash script directly on a
developer machine, which meant the pipeline could only run when that
machine was on, and every host needed its own local Copilot CLI/`gh`
login and Postgres/Jira network access. Stage 7 replaces the host script
with a **persistent, containerized `autofix-agent` service** running
alongside the rest of the stack in `docker compose`, dispatched over
HTTP from n8n instead of invoked from a terminal. `agent-runner/` has
been removed; all of its responsibilities now live in either
`autofix-agent/` (the container) or directly inside n8n Workflows 03/04
(which already hold the only Postgres/Jira credentials in the system).

```
Jira ticket (JIRA_CREATED)
        ↓
Policy Gate (Workflow 03) → AGENT_PENDING
        ↓
Claim job (Workflow 03, atomic UPDATE ... FOR UPDATE SKIP LOCKED,
           increments agent_attempt_count, computes agent_job_id)
        ↓
Fetch ticket context (Workflow 03 → Workflow 05 → Jira, unchanged from
                       Stage 6B)
        ↓
POST /api/jobs  (Workflow 03 → autofix-agent container, bearer-token
                 auth, single-job lock, 202/409/4xx)
        ↓
autofix-agent: clone → branch → Copilot CLI → Validation Gate →
               commit + push → find-or-create Draft PR
        ↓
POST /webhook/autofix/agent-result  (autofix-agent → Workflow 04,
                                      bearer-token auth)
        ↓
Workflow 04: Jira comment + transition to REVIEW, or retry/backoff on
             failure, or terminal HUMAN_REQUIRED
        ↓
Human code review
```

### Why containerize the runner

- **No dependency on a developer machine being on.** The agent runs as
  a long-lived Docker service next to Elasticsearch/Kibana/Logstash/
  Postgres/n8n; the whole pipeline survives a reboot with `docker
  compose up -d` and no manual script invocation.
- **Smaller credential surface per host.** The container has **no**
  Postgres, Jira, or Elasticsearch credentials and no Docker socket — it
  only holds a GitHub/Copilot token and a bearer token for its own HTTP
  API. Every database write (claiming jobs, retry/backoff bookkeeping,
  transitioning to `REVIEW`/`HUMAN_REQUIRED`) now happens from n8n
  Workflows 03/04, which already held the Postgres and Jira credentials.
- **Portable to any orchestrator.** Because dispatch is a plain HTTP
  `POST` with a JSON body and callback, the same container image can run
  under plain `docker compose`, a single VM, or later be moved to
  Kubernetes (Deployment + Service + Secret) without changing the n8n
  workflows at all — n8n only needs the container's HTTP endpoint to be
  reachable.
- **Single-job concurrency, enforced in the container.** `server.py`
  keeps an in-process lock plus a `/workspace/agent.lock` file, so a
  second dispatch while a job is running gets an immediate `409` instead
  of two Copilot CLI processes fighting over the same worktree.

### New components

- **`autofix-agent/`** — the container replacing `agent-runner/`:
  - `Dockerfile` — `eclipse-temurin:21-jdk-jammy` base (JDK for
    `./gradlew test`) + Node.js 20 + pinned GitHub CLI + pinned
    `@github/copilot` npm package + Python 3/FastAPI, running as a
    non-root user, exposing port 8090, with a `/health` healthcheck.
  - `server.py` — the HTTP front door: `POST /api/jobs` (bearer-token
    auth, JSON-schema validation, single-job lock, dispatches
    `execute-job.sh` in the background, replies `202`/`409`/`400`/`401`),
    `GET /api/jobs/{jobId}`, `GET /health`.
  - `execute-job.sh` — the pipeline orchestrator, calling each
    `lib/*.sh` step in sequence: validate job → prepare workspace →
    clone repository → prepare branch → (short-circuit if a PR already
    exists for that branch) → build prompt → run Copilot CLI → Validation
    Gate → commit + push → find-or-create Draft PR → report result to
    n8n → clean up the workspace unconditionally.
  - `lib/run-copilot.sh` and `lib/validate-diff.sh` are unchanged
    ports of the Stage 5 logic (same sandboxed Copilot CLI invocation,
    same Validation Gate rules). The other `lib/*.sh` scripts are new,
    rewritten to have zero Postgres/Jira access.
  - `schemas/agent-job.schema.json` — the job envelope n8n sends
    (flat `ticketContext`, replacing the old nested
    `{ticket, incident}` shape from Workflow 05's raw response — Workflow
    03 flattens it before dispatch).
- **`infrastructure/postgres/init/005-container-agent.sql`** — adds
  `agent_job_id` (plus a unique partial index) so a Workflow 04 callback
  can be matched back to exactly the incident/attempt that produced it.
- **`infrastructure/n8n/workflows/03-queue-autofix-candidates.json`**
  (rewritten) — keeps the original Policy Gate branch unchanged, and adds
  a second branch that reclaims stuck `AGENT_RUNNING` incidents, claims
  one `AGENT_PENDING` job atomically, fetches ticket context via
  Workflow 05, flattens it into the agent's job shape, and dispatches it
  to `autofix-agent` over HTTP — reverting to `AGENT_PENDING` on a `409`
  (agent busy) or to `HUMAN_REQUIRED` on any other dispatch failure.
- **`infrastructure/n8n/workflows/04-finalize-autofix-review.json`**
  (rewritten) — new webhook path `/webhook/autofix/agent-result` with
  bearer-token auth, replacing the old `/webhook/autofix/pr-ready` path.
  Looks the incident up by `agent_job_id` (rejecting stale/duplicate
  callbacks with `409`), then branches on the reported status:
  `PR_READY` (Jira comment + transition to `REVIEW`, same idempotent
  logic as before), `HUMAN_REQUIRED` (terminal), or `AGENT_FAILED`
  (retry with backoff — 1/5/15 minutes by attempt count, terminal at
  attempt ≥ 3 — logic ported from the old `mark-incident-failed.sh`,
  now living in n8n since it owns the Postgres credential).
- **`infrastructure/docker-compose.yml`** — new `autofix-agent` service
  (built from `../autofix-agent`, port 8090, `autofix-agent-workspace`
  volume) plus the two new bearer tokens added to the `n8n` service's
  environment.

Workflow 05 ("Get AutoFix Ticket Context") required **no changes** —
Workflow 03's job-payload step flattens its existing nested response
into the shape the agent expects.

### Configuration additions

| Variable | Purpose |
|---|---|
| `AUTOFIX_AGENT_API_TOKEN` | Bearer token n8n Workflow 03 sends to `autofix-agent`'s `POST /api/jobs` |
| `AUTOFIX_CALLBACK_TOKEN` | Bearer token `autofix-agent` sends back to n8n Workflow 04's `/webhook/autofix/agent-result` |
| `AUTOFIX_GITHUB_TOKEN` | Token used by `gh`/`git` inside the container to clone, push, and open Draft PRs |
| `AUTOFIX_COPILOT_TOKEN` | Token mapped to `COPILOT_GITHUB_TOKEN` inside the container for non-interactive Copilot CLI auth (takes precedence over `GH_TOKEN`/`GITHUB_TOKEN`) |
| `AUTOFIX_REPOSITORY_URL` / `AUTOFIX_REPOSITORY_OWNER` / `AUTOFIX_REPOSITORY_NAME` | The only repository the container is allowed to clone — never accepted from the job request itself |
| `AUTOFIX_BASE_BRANCH` | Base branch for branches/PRs (default `main`) |

See `infrastructure/.env.example` for the full list. `infrastructure/.env`
itself is gitignored and must be recreated manually on any new machine —
see the "Rebuilding after a fresh machine/OS" note below.

### Running it locally

```bash
cd infrastructure
docker compose up -d --build autofix-agent
curl http://localhost:8090/health
```

No manual script invocation is needed afterward — n8n Workflow 03
dispatches jobs to the running container automatically every schedule
tick.

## Scope of Stage 7

Not included at this stage: moving the container to Kubernetes (the
image and HTTP contract are designed to allow it, but no manifests exist
yet), concurrent multi-job processing (still one job at a time, enforced
by the container's own lock), and any change to the Validation Gate
rules or the no-auto-merge / human-review guarantee.

## Stage 8: Incident lifecycle refinements

Two smaller, independent refinements on top of Stage 7's containerized
pipeline, both driven by gaps found while exercising the live system.

### Jira visibility while the agent is working

Previously a Jira ticket sat in "To Do" for the entire duration of the
agent's work and only moved once a Draft PR was ready (straight to
`REVIEW`), giving no visibility that anything was happening in between.

**Workflow 03** now transitions the ticket to an "in development" status
(matched by name/alias, exactly like Workflow 04's existing `REVIEW`
transition) at the one point where we know work has genuinely started:
right after `autofix-agent` responds `202 Accepted` to the job dispatch
— not at claim time, since a claim can still bounce back to
`AGENT_PENDING` on a `409`/dispatch failure, which would otherwise cause
the ticket to flip back and forth for no reason.

- **New nodes in `infrastructure/n8n/workflows/03-queue-autofix-candidates.json`**
  (added after `Dispatch Accepted?`'s true branch): `Get Jira Issue (In Dev)`
  → `Read Jira Transitions (In Dev)` → `Evaluate Jira Transition (In Dev)`
  (Code node matching the current status/transition names against the
  aliases `in progress`, `in development`, `development`, `in dev`,
  `в разработке`, case-insensitively) → `In Dev Transition Available?`
  → `Execute Jira Transition (In Dev)`.
- No hard-coded Jira transition ID is used — the same "ask Jira what
  transitions are available from the current status, match by name"
  pattern as Workflow 04's `REVIEW` transition.
- Best-effort and non-blocking: if no matching transition is available
  from the ticket's current status (e.g. a human already moved it
  further manually), the branch is simply skipped — it does not fail
  the dispatch or change the incident's own `AGENT_RUNNING` status in
  PostgreSQL.

### Reopening a recurring incident instead of silently reusing a closed ticket

`fingerprint` previously had a plain `UNIQUE` constraint on
`autofix.incident`, so **any** later recurrence of the exact same error
-- even long after its incident had reached `REVIEW` (fix proposed,
possibly since merged and the Jira ticket closed by a human),
`HUMAN_REQUIRED`, or `AGENT_FAILED` -- would just silently bump that old
row's `last_seen_at`/`occurrence_count`. No new Jira ticket, no new
AutoFix attempt, regardless of whether the original ticket had long
since been resolved and closed.

- **`infrastructure/postgres/init/006-reopen-recurring-incidents.sql`**
  replaces the plain `UNIQUE(fingerprint)` constraint with a **partial
  unique index**:
  ```sql
  CREATE UNIQUE INDEX idx_incident_fingerprint_active
      ON autofix.incident (fingerprint)
      WHERE status NOT IN (
          'REVIEW', 'HUMAN_REQUIRED', 'AGENT_FAILED', 'COMPLETED', 'FAILED'
      );
  ```
  Uniqueness is now enforced only among *active* (still in-flight)
  incidents. Once an incident reaches one of the terminal statuses
  above, it stops participating in the uniqueness check, so it no
  longer blocks a fresh row for the same fingerprint.
- **Workflow 01**'s upsert (`Claim & Upsert Incident`) changed its
  `ON CONFLICT (fingerprint)` target to
  `ON CONFLICT (fingerprint) WHERE status NOT IN (...)`, matching the
  new partial index's predicate exactly (required by Postgres to pick
  it as the conflict arbiter). A recurrence that no longer conflicts
  with an old terminal row inserts as a **brand-new incident** (new
  `id`, `occurrence_count = 1`, fresh `status = 'DETECTED'`) instead of
  updating the old one. Recurrences while the existing incident is
  still active are unaffected — they still just bump the same row, exactly
  as before.
- **Workflow 02**'s crash-recovery idempotency check (`Search Jira by
  Fingerprint` — re-links an incident to an already-created Jira ticket
  if a previous run created the ticket but crashed before writing
  `jira_key` back to Postgres) searched only by the `autofix-fp-<hash>`
  label, so it would incorrectly match and re-link a reopened incident
  to the **old**, already-resolved ticket (Jira labels are never removed
  from closed tickets). Fixed by adding a second, per-incident label
  (`autofix-incident-<id>`, set in `Prepare Jira Payload`) and requiring
  **both** labels in the recovery JQL:
  ```
  project = AUTO AND labels = "autofix-fp-<hash>" AND labels = "autofix-incident-<id>" ORDER BY created ASC
  ```
  This scopes the recovery search to this exact incident row's own
  prior (crashed) attempt, never to an older incident sharing the same
  fingerprint.

Verified live: triggering the same NPE again after its original
incident (13, `AUTO-10`) reached `REVIEW` produced a new, independent
incident row with its own distinct Jira ticket (`AUTO-12`) and its own
full AutoFix cycle, rather than re-linking to the closed `AUTO-10`
ticket.

## Scope of Stage 8

Not included at this stage: syncing PostgreSQL's `status` back from
Jira's real-world status (there is still no polling of Jira after a
ticket reaches `REVIEW`, so "terminal" here means "this system's
automated lifecycle for the incident concluded", not "a human
confirmed it in Jira"); any cross-linking between a reopened incident
and its predecessor's ticket (each is fully independent, with no
back-reference); and de-duplicating *concurrently active* recurrences
beyond the existing partial-unique-index guarantee.
