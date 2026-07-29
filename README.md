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

## Scope of this stage

Not included at this stage: database, Kafka, Kubernetes, authentication,
Jira client, Elasticsearch client, automated fixing, automated Pull Request
creation, and automated deployment. These will be added in later POC stages.
