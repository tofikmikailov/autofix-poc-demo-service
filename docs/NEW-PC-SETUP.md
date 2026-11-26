# Moving the AutoFix system to a new PC

The repo contains the code, docker-compose, n8n workflow exports, Postgres init
scripts and agent-runner. Secrets, n8n credentials, tool installs and logins do not
travel with it.

## 1. Prerequisites
- Java 21 (Gradle 8.10.2 does not run on JDK 25)
- Docker, `jq`, `psql`, `git`, `gh`, Copilot CLI
- Free host ports: 5678 (n8n) and the Postgres port from `infrastructure/.env`

## 2. Logins
- `gh auth login` and Git push access
- Copilot CLI login
- Jira MCP configured for Copilot CLI

## 3. Clone and configure
```
git clone git@github.com:tofikmikailov/autofix-poc-demo-service.git
cd autofix-poc-demo-service
cp infrastructure/.env.example infrastructure/.env
cp agent-runner/.env.example agent-runner/.env
```
- Never commit either `.env` file.
- `AUTOFIX_RUNNER_WEBHOOK_TOKEN` must be identical in both files
  (generate with `openssl rand -hex 32`).
- Reuse the previous `N8N_ENCRYPTION_KEY`, otherwise existing n8n credentials
  cannot be decrypted.
- Set `AUTOFIX_REPO` (and `AUTOFIX_ROOT` if not `~/autofix-poc`) for the new machine.

## 4. Start infrastructure
```
cd infrastructure && docker compose up -d
```
Postgres is seeded from `infrastructure/postgres/init` on a fresh volume.
Old incident history is only needed if you copy the old Postgres volume or a dump.

## 5. n8n workflows
On the OLD PC, refresh the committed exports first (the UI may be newer than git):
```
./infrastructure/n8n/export-workflows.sh
```
On the NEW PC:
```
./infrastructure/n8n/import-workflows.sh
```
Then in the n8n UI (http://localhost:5678):
1. Create the Jira credential (used by Workflows 04 and 05; the runner holds none).
2. Activate all workflows. Imported workflows start inactive, so webhooks will not respond.

Credentials are never in git. To back them up privately (stays encrypted by the key):
```
docker exec autofix-n8n n8n export:credentials --all --output=/tmp/c.json
docker cp autofix-n8n:/tmp/c.json <private-location>
```

## 6. Verify
- `docker ps` shows postgres, elasticsearch, logstash, n8n healthy
- `./gradlew clean test` passes
- The ticket-context webhook responds with the runner token header
- `agent-runner/run-once.sh` exits 0 (no job, or a processed job)

## 7. Scheduling
Re-create whatever schedules `agent-runner/run-once.sh` (cron/launchd) on the new PC.

## Security
Rotate any secret that was ever printed in logs or shared terminals
(runner webhook token, Postgres password, Jira token).
