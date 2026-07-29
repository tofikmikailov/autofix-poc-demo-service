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

## Scope of this stage

Not included at this stage: database, Kafka, Kubernetes, authentication,
Jira client, Elasticsearch client, automated fixing, automated Pull Request
creation, and automated deployment. These will be added in later POC stages.
