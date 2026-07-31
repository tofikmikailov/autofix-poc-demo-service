#!/usr/bin/env bash
#
# Section 18: build the sanitized Copilot prompt from a job payload
# that has already passed validate-job.sh. Adapted from the local Agent
# Runner's build-agent-prompt.sh -- same placeholder set, same
# UNTRUSTED_JIRA_CONTEXT wrapping in the template -- just reading the
# flatter `ticketContext` shape n8n sends in the job envelope instead of
# the nested `{ticket, incident}` shape Workflow 05 used to return
# directly to the host script.
#
# Never includes: any Jira credential, the raw Jira REST response,
# unapproved comments, or any workflow/database metadata.
#
# Usage:
#   build-agent-prompt.sh <job.json> <prompt-template> <output-prompt-file>

set -euo pipefail

JOB_FILE="${1:?usage: build-agent-prompt.sh <job.json> <prompt-template> <output-prompt-file>}"
TEMPLATE_FILE="${2:?missing prompt-template}"
OUTPUT_FILE="${3:?missing output-prompt-file}"

if [[ ! -f "$JOB_FILE" ]]; then
  echo "Job file not found: $JOB_FILE" >&2
  exit 1
fi
if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Prompt template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

python3 - "$JOB_FILE" "$TEMPLATE_FILE" "$OUTPUT_FILE" <<'PYEOF'
import json
import sys

job_path, template_path, output_path = sys.argv[1:4]

with open(job_path, "r", encoding="utf-8") as f:
    job = json.load(f)

ctx = job.get("ticketContext") or {}
approved_comments = ctx.get("approvedAgentContext") or []

if approved_comments:
    approved_text = "\n\n".join(f"- {c}" for c in approved_comments)
else:
    approved_text = "(none)"

replacements = {
    "{{JIRA_KEY}}": job.get("jiraKey", ""),
    "{{SUMMARY}}": ctx.get("summary", ""),
    "{{EXCEPTION_TYPE}}": ctx.get("exceptionType", "unknown"),
    "{{NORMALIZED_MESSAGE}}": ctx.get("normalizedMessage", "n/a"),
    "{{APPLICATION_FRAME}}": ctx.get("applicationFrame", "n/a"),
    "{{HTTP_METHOD}}": ctx.get("httpMethod", "n/a"),
    "{{REQUEST_PATH}}": ctx.get("requestPath", "n/a"),
    "{{STACK_TRACE}}": ctx.get("stackTrace", "n/a"),
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
