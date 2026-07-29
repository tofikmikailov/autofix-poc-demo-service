#!/usr/bin/env bash
#
# Stage 6B: build the sanitized Copilot prompt from a *validated* n8n
# ticket-context response (validate-ticket-response.sh must have already
# returned PASS for the input file this reads). This is the only place
# PostgreSQL-derived data (the incident's fingerprint, used only for
# equality checks upstream) stops being relevant at all -- from here on,
# every field in the rendered prompt comes from n8n Workflow 05's
# sanitized response, which itself is the only thing in this whole
# pipeline that ever holds a Jira credential.
#
# Never includes: any Jira credential, the raw Jira REST response,
# unapproved comments, or any workflow/database metadata.
#
# Usage:
#   build-agent-prompt.sh <ticket-context.json> <prompt-template> <output-prompt-file>
#
# Exit codes:
#   0 - prompt written to <output-prompt-file>
#   1 - hard failure (missing input, template, or malformed context)

set -euo pipefail

CONTEXT_FILE="${1:?usage: build-agent-prompt.sh <parsed-context.json> <prompt-template> <output-prompt-file>}"
TEMPLATE_FILE="${2:?missing prompt-template}"
OUTPUT_FILE="${3:?missing output-prompt-file}"

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "Context file not found: $CONTEXT_FILE" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Prompt template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

python3 - "$CONTEXT_FILE" "$TEMPLATE_FILE" "$OUTPUT_FILE" <<'PYEOF'
import json
import sys

context_path, template_path, output_path = sys.argv[1:4]

with open(context_path, "r", encoding="utf-8") as f:
    ctx = json.load(f)

ticket = ctx.get("ticket") or {}
incident = ctx.get("incident") or {}
approved_comments = ctx.get("approvedAgentContext") or []

if approved_comments:
    approved_text = "\n\n".join(f"- {c}" for c in approved_comments)
else:
    approved_text = "(none)"

replacements = {
    "{{JIRA_KEY}}": ticket.get("key", ""),
    "{{SUMMARY}}": ticket.get("summary", ""),
    "{{EXCEPTION_TYPE}}": incident.get("exceptionType", "unknown"),
    "{{NORMALIZED_MESSAGE}}": incident.get("normalizedMessage", "n/a"),
    "{{APPLICATION_FRAME}}": incident.get("applicationFrame", "n/a"),
    "{{HTTP_METHOD}}": incident.get("httpMethod", "n/a"),
    "{{REQUEST_PATH}}": incident.get("requestPath", "n/a"),
    "{{STACK_TRACE}}": incident.get("stackTrace", "n/a"),
    "{{APPROVED_COMMENTS}}": approved_text,
}

with open(template_path, "r", encoding="utf-8") as f:
    text = f.read()

for placeholder, value in replacements.items():
    text = text.replace(placeholder, str(value))

with open(output_path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF

echo "[build-agent-prompt] wrote $OUTPUT_FILE" >&2
