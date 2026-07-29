# AutoFix Task: {{JIRA_KEY}}

You are operating non-interactively inside an isolated git worktree. You
have **no** access to Jira, GitHub, or any network service, and you must
never attempt to reach them.

## Incident details

- Jira key: {{JIRA_KEY}}
- Exception type: {{EXCEPTION_TYPE}}
- Normalized exception message: {{NORMALIZED_MESSAGE}}
- Application stack frame: {{APPLICATION_STACK_FRAME}}
- Sample request path: {{SAMPLE_HTTP_METHOD}} {{SAMPLE_REQUEST_PATH}}
- Sample correlation ID: {{SAMPLE_CORRELATION_ID}}

Full sample stack trace:

```
{{SAMPLE_STACK_TRACE}}
```

## Instructions

1. Reproduce the defect with a regression test.
2. Implement the smallest safe fix.
3. Do not change public API contracts.
4. Do not modify infrastructure or configuration.
5. Do not disable or remove tests.
6. Run `./gradlew clean test`.
7. Do not commit, push, or create a pull request.
8. Do not access Jira or GitHub.

## Allowed directories

- `src/main/java/**` (production code -- keep changes minimal, ideally a
  single class)
- `src/test/java/**` (a new or updated regression test is mandatory)

## Test command

```
./gradlew clean test
```

## Forbidden

- Any file outside `src/main/java/**` and `src/test/java/**`
  (infrastructure/**, .github/workflows/**, gradle/**, gradlew,
  build.gradle, settings.gradle, Dockerfile, application.yml,
  logback-spring.xml are all off-limits).
- `git`, `gh`, `curl`, `ssh`, `kubectl`, `helm`, `docker`, `psql`, or any
  network/MCP access.
- Disabling, skipping, or deleting existing tests (`@Disabled`,
  `skipTests`, `-x test`, etc.).

When you are done, stop -- do not commit, push, or open a pull request.
An independent validation gate outside this session will review your
diff and run the full test suite itself.
