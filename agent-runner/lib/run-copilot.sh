#!/usr/bin/env bash
#
# Stage 5E: Invoke Copilot CLI non-interactively, inside the isolated
# worktree, with the minimum permissions needed to reproduce-and-fix the
# defect -- and nothing else.
#
# Copilot is given:
#   - read/search access to the worktree (--add-dir, view/grep/glob)
#   - write access to edit/create files (write)
#   - permission to run ./gradlew (and nothing else via shell)
#
# Copilot is explicitly denied:
#   - git, gh, curl, ssh, kubectl, helm, docker, psql (shell)
#   - all built-in MCP servers (--disable-builtin-mcps) -- no GitHub MCP,
#     no Jira access of any kind
#   - all URLs (no --allow-url is ever passed)
#   - the ask_user tool (nothing interactive can happen; --no-ask-user)
#
# Usage:
#   run-copilot.sh <worktree-dir> <prompt-file> <log-file>
#
# Exit codes:
#   Passes through the Copilot CLI's own exit code. A non-zero exit here
#   is not fatal to the pipeline -- validate-diff.sh independently judges
#   whatever diff (if any) Copilot left behind.

set -uo pipefail

WORKTREE_DIR="${1:?usage: run-copilot.sh <worktree-dir> <prompt-file> <log-file>}"
PROMPT_FILE="${2:?missing prompt-file}"
LOG_FILE="${3:?missing log-file}"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

cd "$WORKTREE_DIR"

echo "Running Copilot CLI in $WORKTREE_DIR (log: $LOG_FILE)" >&2

copilot -p "$(cat "$PROMPT_FILE")" \
  --add-dir "$WORKTREE_DIR" \
  --allow-tool 'shell(./gradlew:*)' \
  --allow-tool 'write' \
  --allow-tool 'view' \
  --allow-tool 'grep' \
  --allow-tool 'glob' \
  --deny-tool 'shell(git:*)' \
  --deny-tool 'shell(gh:*)' \
  --deny-tool 'shell(curl:*)' \
  --deny-tool 'shell(wget:*)' \
  --deny-tool 'shell(ssh:*)' \
  --deny-tool 'shell(scp:*)' \
  --deny-tool 'shell(kubectl:*)' \
  --deny-tool 'shell(helm:*)' \
  --deny-tool 'shell(docker:*)' \
  --deny-tool 'shell(psql:*)' \
  --deny-tool 'shell(rm:*)' \
  --disable-builtin-mcps \
  --no-ask-user \
  --no-color \
  --log-level info \
  --log-dir "$(dirname "$LOG_FILE")" \
  > "$LOG_FILE" 2>&1

EXIT_CODE=$?
echo "Copilot CLI exited with code $EXIT_CODE (log: $LOG_FILE)" >&2
exit "$EXIT_CODE"
