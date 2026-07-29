#!/usr/bin/env python3
"""Stage 6: convert a raw Jira Cloud issue (Atlassian Document Format
description/comments) into the flat, plain-text context structure the
rest of the Agent Runner pipeline consumes.

Usage:
    parse-jira-context.py <raw-jira-issue.json> <output.json>

Input is the raw response of `GET /rest/api/3/issue/{key}` (as written by
fetch-jira-context.sh). Output is a normalized JSON document:

    {
      "key": "AUTO-3",
      "summary": "...",
      "descriptionText": "...",
      "labels": ["auto-generated", "autofix-candidate", "autofix-fp-..."],
      "status": "OPEN",
      "issueType": "Task",
      "projectKey": "AUTO",
      "priority": "Medium",
      "updatedAt": "2026-07-29T...",
      "approvedComments": ["..."],
      "autofixContext": { ... AUTOFIX_CONTEXT_V1 JSON, or null ... },
      "autofixContextError": "..." (present only if the block existed but
                                     failed to parse as JSON)
    }

ADF parsing never raises on unknown node types -- unknown nodes are
either recursed into (via `content`) or skipped with a warning on
stderr, so a Jira ticket edited by hand with an unusual node type never
crashes the pipeline (Copilot's task should degrade to
"context unavailable" -> validate-jira-context.sh rejects it -- not a
Python traceback).
"""
import json
import re
import sys

# Node types explicitly recognized. Anything else is treated as
# "unknown" -- we still recurse into its `content` (best-effort) but
# never fail because of it.
KNOWN_BLOCK_TYPES = {
    "doc", "paragraph", "heading", "bulletList", "orderedList", "listItem",
    "codeBlock", "blockquote", "rule", "panel", "table", "tableRow",
    "tableCell", "tableHeader",
}
KNOWN_INLINE_TYPES = {"text", "hardBreak", "mention", "inlineCard", "emoji"}

AUTOFIX_MARKER_RE = re.compile(
    r"AUTOFIX_CONTEXT_V1\s*```(?:json)?\s*(?P<json>.*?)```\s*AUTOFIX_CONTEXT_END",
    re.DOTALL,
)
APPROVED_COMMENT_MARKER = "[AUTOFIX_AGENT_CONTEXT]"


def adf_node_to_text(node, warnings):
    """Recursively render a single ADF node to plain text."""
    if not isinstance(node, dict):
        return ""

    node_type = node.get("type")
    content = node.get("content") or []

    if node_type == "text":
        return node.get("text", "")

    if node_type == "hardBreak":
        return "\n"

    if node_type == "rule":
        return "\n---\n"

    if node_type in ("mention",):
        attrs = node.get("attrs", {})
        return f"@{attrs.get('text') or attrs.get('id') or 'mention'}"

    if node_type in ("inlineCard",):
        attrs = node.get("attrs", {})
        return attrs.get("url", "")

    if node_type == "codeBlock":
        inner = "".join(adf_node_to_text(c, warnings) for c in content)
        return f"\n```\n{inner}\n```\n"

    if node_type == "listItem":
        inner = "".join(adf_node_to_text(c, warnings) for c in content)
        return f"- {inner.strip()}\n"

    if node_type in ("bulletList", "orderedList"):
        return "".join(adf_node_to_text(c, warnings) for c in content)

    if node_type in ("paragraph", "heading", "blockquote", "panel"):
        inner = "".join(adf_node_to_text(c, warnings) for c in content)
        return inner + "\n"

    if node_type in ("table", "tableRow", "tableCell", "tableHeader"):
        return "".join(adf_node_to_text(c, warnings) for c in content)

    if node_type == "doc":
        return "".join(adf_node_to_text(c, warnings) for c in content)

    # Unknown node type: best-effort recurse into content, warn once.
    if node_type not in KNOWN_BLOCK_TYPES | KNOWN_INLINE_TYPES:
        warnings.append(f"unknown ADF node type skipped-into: {node_type!r}")
    return "".join(adf_node_to_text(c, warnings) for c in content)


def adf_to_text(adf_doc, warnings):
    """Convert a full ADF document (or a plain string, for tolerance) to
    plain text."""
    if adf_doc is None:
        return ""
    if isinstance(adf_doc, str):
        return adf_doc
    if not isinstance(adf_doc, dict):
        return ""
    text = adf_node_to_text(adf_doc, warnings)
    # Collapse 3+ blank lines down to a single blank line for readability.
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def extract_autofix_context(description_text):
    """Extract and parse the AUTOFIX_CONTEXT_V1 JSON block, if present.

    Returns (context_dict_or_None, error_message_or_None).
    """
    match = AUTOFIX_MARKER_RE.search(description_text)
    if not match:
        return None, None
    raw_json = match.group("json").strip()
    try:
        return json.loads(raw_json), None
    except json.JSONDecodeError as exc:
        return None, f"AUTOFIX_CONTEXT_V1 block found but is not valid JSON: {exc}"


def extract_approved_comments(raw_comments, warnings):
    """Stage 6 Section 12: only comments beginning with the
    [AUTOFIX_AGENT_CONTEXT] marker are trusted informational context for
    Copilot. All other comments are discarded here -- they never reach
    the prompt."""
    approved = []
    comments = (raw_comments or {}).get("comments", [])
    for c in comments:
        body_text = adf_to_text(c.get("body"), warnings).strip()
        if body_text.startswith(APPROVED_COMMENT_MARKER):
            # Strip the marker itself from what's forwarded to Copilot.
            trimmed = body_text[len(APPROVED_COMMENT_MARKER):].strip()
            if trimmed:
                approved.append(trimmed)
    return approved


def main():
    if len(sys.argv) != 3:
        print(
            "usage: parse-jira-context.py <raw-jira-issue.json> <output.json>",
            file=sys.stderr,
        )
        return 1

    input_path, output_path = sys.argv[1], sys.argv[2]

    with open(input_path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    warnings = []
    fields = raw.get("fields", {})

    key = raw.get("key", "")
    summary = fields.get("summary") or ""
    description_text = adf_to_text(fields.get("description"), warnings)
    labels = fields.get("labels") or []
    status = ((fields.get("status") or {}).get("name")) or ""
    issue_type = ((fields.get("issuetype") or {}).get("name")) or ""
    project_key = ((fields.get("project") or {}).get("key")) or ""
    priority = ((fields.get("priority") or {}).get("name")) or ""
    updated_at = fields.get("updated") or ""

    autofix_context, autofix_context_error = extract_autofix_context(description_text)
    approved_comments = extract_approved_comments(fields.get("comment"), warnings)

    result = {
        "key": key,
        "summary": summary,
        "descriptionText": description_text,
        "labels": labels,
        "status": status,
        "issueType": issue_type,
        "projectKey": project_key,
        "priority": priority,
        "updatedAt": updated_at,
        "approvedComments": approved_comments,
        "autofixContext": autofix_context,
    }
    if autofix_context_error:
        result["autofixContextError"] = autofix_context_error

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

    for w in warnings:
        print(f"[parse-jira-context] {w}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
