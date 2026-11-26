#!/usr/bin/env bash
# Export all n8n workflows from the running container into infrastructure/n8n/workflows/.
# Credentials are NOT exported here (they are secrets; see backup-credentials.sh).
set -euo pipefail

CONTAINER="${N8N_CONTAINER:-autofix-n8n}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflows"
TMP="/tmp/n8n-export"

docker exec "$CONTAINER" rm -rf "$TMP"
docker exec "$CONTAINER" mkdir -p "$TMP"
docker exec "$CONTAINER" n8n export:workflow --backup --output="$TMP/"
mkdir -p "$DIR"
docker cp "$CONTAINER:$TMP/." "$DIR/"
echo "Exported workflows to $DIR"
