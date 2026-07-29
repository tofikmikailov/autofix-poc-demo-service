#!/usr/bin/env bash
#
# Stage 5F: Independent Validation Gate
#
# Never trust Copilot CLI's own "tests passed" claim. This script is the
# Agent Runner's independent judge of whether a Copilot-produced diff is
# safe to commit/push/open as a Draft PR. It re-derives everything from
# the actual working-tree state and its own test run — it does not read
# any Copilot output/report.
#
# Usage:
#   validate.sh <worktree-dir> [--allow-readme]
#
# Exit codes:
#   0  - PASS  (safe to commit/push/open PR); JSON verdict on stdout
#   10 - FAIL, category=AGENT_FAILED   (retryable: Copilot made no changes at all)
#   20 - FAIL, category=HUMAN_REQUIRED (not retryable: policy/size/forbidden-construct
#        violation, or the independent test run failed -- a failing test means
#        Copilot's fix itself is wrong/incomplete, which a blind re-run is
#        unlikely to fix, so it must not be silently retried -- see Stage 5I)
#
# A single JSON object is always printed to stdout as the final line,
# whether PASS or FAIL, so callers (the Agent Runner) can parse the
# verdict without scraping human-readable log output.

set -euo pipefail

WORKTREE_DIR="${1:?usage: validate.sh <worktree-dir> [--allow-readme]}"
ALLOW_README="false"
if [[ "${2:-}" == "--allow-readme" ]]; then
  ALLOW_README="true"
fi

# Gradle 8.10.2 (this project's wrapper version) does not support the
# system JDK (25) on some hosts -- class file major version 69 is rejected.
# JDK 17 is the known-good baseline (see Stage 5A verification). Resolution
# order: explicit env override -> macOS java_home helper -> fall back to
# whatever JAVA_HOME/PATH already resolves to (gradlew will fail loudly if
# that JDK is incompatible, which is preferable to silently guessing a
# machine-specific path).
if [[ -n "${JAVA_HOME_17:-}" ]]; then
  : # explicit override wins
elif command -v /usr/libexec/java_home >/dev/null 2>&1 && JAVA_HOME_17="$(/usr/libexec/java_home -v 17 2>/dev/null)"; then
  : # resolved via macOS java_home helper
else
  JAVA_HOME_17="${JAVA_HOME:-}"
fi

MAX_FILES=5
MAX_CHANGED_LINES=300
MAX_PRODUCTION_CLASSES=1

FORBIDDEN_PATH_PATTERNS=(
  '^infrastructure/'
  '^\.github/workflows/'
  '^gradle/'
  '^gradlew$'
  '^gradlew\.bat$'
  '^build\.gradle$'
  '^settings\.gradle$'
  '^Dockerfile$'
  '^application\.yml$'
  '^logback-spring\.xml$'
)

# Grep patterns checked against *added* diff lines only (see check 5).
FORBIDDEN_CONSTRUCTS=(
  '@Disabled'
  'skipTests'
  '(^|[^-])-x test'
  'TODO disable'
  'catch \(Exception ignored\)'
  'System\.exit'
  'Thread\.sleep'
)

cd "$WORKTREE_DIR"

fail() {
  local category="$1"
  local reason="$2"
  jq -n --arg category "$category" --arg reason "$reason" \
    '{result: "FAIL", category: $category, reason: $reason}'
  if [[ "$category" == "AGENT_FAILED" ]]; then
    exit 10
  else
    exit 20
  fi
}

# --- Check 1: changes exist ---------------------------------------------
# `git diff --exit-code` alone only covers already-tracked files; Copilot
# is expected to *create* a new regression test file, so untracked new
# files must count as "changes" too. Staging everything first and
# checking `git diff --cached` covers both modified and newly-added files
# with a single, consistent diff for every later check.
git add -A
if git diff --cached --quiet; then
  fail "AGENT_FAILED" "NO_CHANGES: git diff is empty, Copilot made no changes"
fi

CHANGED_FILES="$(git diff --cached --name-only)"
NUM_FILES="$(printf '%s\n' "$CHANGED_FILES" | grep -c . || true)"

# --- Check 2: allowed files only -----------------------------------------
# Reason strings are prefixed with a stable machine-readable code
# (POLICY_VIOLATION: prohibited file <path>) so the Agent Runner can copy
# them verbatim into incident.agent_last_error (see Stage 5I).
FORBIDDEN=()
NOT_ALLOWLISTED=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  IS_FORBIDDEN="false"
  for pat in "${FORBIDDEN_PATH_PATTERNS[@]}"; do
    if [[ "$f" =~ $pat ]]; then
      FORBIDDEN+=("$f")
      IS_FORBIDDEN="true"
    fi
  done
  [[ "$IS_FORBIDDEN" == "true" ]] && continue

  if [[ "$f" =~ ^src/main/java/ || "$f" =~ ^src/test/java/ ]]; then
    continue
  fi
  if [[ "$f" == "README.md" && "$ALLOW_README" == "true" ]]; then
    continue
  fi
  NOT_ALLOWLISTED+=("$f")
done <<< "$CHANGED_FILES"

if [[ ${#FORBIDDEN[@]} -gt 0 ]]; then
  fail "HUMAN_REQUIRED" "POLICY_VIOLATION: prohibited file $(printf '%s, ' "${FORBIDDEN[@]}" | sed 's/, $//')"
fi
if [[ ${#NOT_ALLOWLISTED[@]} -gt 0 ]]; then
  fail "HUMAN_REQUIRED" "POLICY_VIOLATION: file not in allow-list $(printf '%s, ' "${NOT_ALLOWLISTED[@]}" | sed 's/, $//')"
fi

# --- Check 3: diff size limits -------------------------------------------
if [[ "$NUM_FILES" -gt "$MAX_FILES" ]]; then
  fail "HUMAN_REQUIRED" "too many files changed: $NUM_FILES > $MAX_FILES"
fi

STAT="$(git diff --cached --shortstat)"
ADDED="$(printf '%s' "$STAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || true)"
DELETED="$(printf '%s' "$STAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || true)"
ADDED="${ADDED:-0}"
DELETED="${DELETED:-0}"
TOTAL_CHANGED=$((ADDED + DELETED))
if [[ "$TOTAL_CHANGED" -gt "$MAX_CHANGED_LINES" ]]; then
  fail "HUMAN_REQUIRED" "diff too large: $TOTAL_CHANGED changed lines > $MAX_CHANGED_LINES"
fi

PRODUCTION_CLASSES="$(printf '%s\n' "$CHANGED_FILES" | grep -cE '^src/main/java/.*\.java$' || true)"
if [[ "$PRODUCTION_CLASSES" -gt "$MAX_PRODUCTION_CLASSES" ]]; then
  fail "HUMAN_REQUIRED" "too many production classes changed: $PRODUCTION_CLASSES > $MAX_PRODUCTION_CLASSES"
fi

# --- Check 4: mandatory regression test ----------------------------------
TEST_FILES="$(printf '%s\n' "$CHANGED_FILES" | grep -cE '^src/test/' || true)"
if [[ "$TEST_FILES" -lt 1 ]]; then
  fail "HUMAN_REQUIRED" "no regression test found in diff (src/test/** required)"
fi

# --- Check 5: forbidden constructs ---------------------------------------
# Only inspect *added* lines (diff lines starting with a single '+', not
# the '+++' file header) so removing a forbidden construct never trips
# the gate.
ADDED_LINES="$(git diff --cached | grep -E '^\+[^+]' || true)"
for pattern in "${FORBIDDEN_CONSTRUCTS[@]}"; do
  if printf '%s\n' "$ADDED_LINES" | grep -qE "$pattern"; then
    fail "HUMAN_REQUIRED" "forbidden construct introduced in diff: $pattern"
  fi
done

# --- Check 6: independent test run ---------------------------------------
export JAVA_HOME="$JAVA_HOME_17"
export PATH="$JAVA_HOME/bin:$PATH"
TEST_LOG="$(mktemp -t agent-runner-test-XXXXXX.log)"
if ! ./gradlew clean test --console=plain > "$TEST_LOG" 2>&1; then
  # HUMAN_REQUIRED (not AGENT_FAILED / retryable): a failing test means
  # Copilot's own fix is wrong or incomplete, not that the environment
  # glitched -- a blind automatic retry is unlikely to produce a
  # different, correct outcome, so this must stop for human review
  # rather than silently re-attempt (see Stage 5I).
  fail "HUMAN_REQUIRED" "TESTS_FAILED: ./gradlew clean test failed (log: $TEST_LOG)"
fi

DIFF_CHECK_LOG="$(mktemp -t agent-runner-diffcheck-XXXXXX.log)"
if ! git diff --cached --check > "$DIFF_CHECK_LOG" 2>&1; then
  fail "HUMAN_REQUIRED" "TESTS_FAILED: git diff --check found whitespace/conflict-marker issues (log: $DIFF_CHECK_LOG)"
fi

jq -n \
  --argjson files "$NUM_FILES" \
  --argjson added "$ADDED" \
  --argjson deleted "$DELETED" \
  '{
    result: "PASS",
    changedFiles: $files,
    addedLines: $added,
    deletedLines: $deleted
  }'
exit 0
