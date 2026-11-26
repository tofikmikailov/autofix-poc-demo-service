#!/usr/bin/env bash
# Import all workflows from infrastructure/n8n/workflows/ into a running n8n container.
# Prereq: `docker compose up -d` is running and the same N8N_ENCRYPTION_KEY is set in .env.
# After import, re-create the Jira credential in the n8n UI (credentials are not in git)
# and activate the workflows.
set -euo pipefail

CONTAINER="${N8N_CONTAINER:-autofix-n8n}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflows"
TMP="/tmp/n8n-import"

docker exec "$CONTAINER" rm -rf "$TMP"
docker exec "$CONTAINER" mkdir -p "$TMP"
docker cp "$DIR/." "$CONTAINER:$TMP/"
for f in "$DIR"/*.json; do
  docker exec "$CONTAINER" n8n import:workflow --input="$TMP/$(basename "$f")"
done
echo "Imported workflows. Re-create credentials in the UI, then activate workflows."
