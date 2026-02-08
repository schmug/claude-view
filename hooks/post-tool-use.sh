#!/usr/bin/env bash
# PostToolUse hook: sends activity to Claude View web server
# Reads JSON from stdin with tool_name, tool_input fields

set -euo pipefail

# Dev mode guard: skip hooks when developing claude-view itself
if [ "${CLAUDE_VIEW_DEV:-}" = "1" ]; then
  exit 0
fi

# Read token and URL
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOKEN_FILE="$SCRIPT_DIR/.claude-view-token"

if [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
else
  TOKEN="${CLAUDE_VIEW_TOKEN:-}"
fi

URL="${CLAUDE_VIEW_URL:-http://localhost:3456}"

if [ -z "$TOKEN" ]; then
  exit 0
fi

# Compute session ID: basename-sha256prefix
SESSION_ID="$(basename "$(pwd)")-$(printf '%s' "$(pwd)" | sha256sum | cut -c1-8)"

# Read stdin
INPUT="$(cat)"

TOOL_NAME="$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
TOOL_INPUT="$(echo "$INPUT" | grep -o '"tool_input":{[^}]*}' | head -1 || true)"

# Filter out noisy/read-only tools
case "$TOOL_NAME" in
  Read|Glob|Grep|WebSearch|WebFetch|LS|TaskList|TaskGet)
    exit 0
    ;;
esac

# Build summary
SUMMARY=""
case "$TOOL_NAME" in
  Edit)
    FILE="$(echo "$TOOL_INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    SUMMARY="Edited: ${FILE##*/}"
    ;;
  Write)
    FILE="$(echo "$TOOL_INPUT" | grep -o '"file_path":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    SUMMARY="Wrote: ${FILE##*/}"
    ;;
  Bash)
    CMD="$(echo "$TOOL_INPUT" | grep -o '"command":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    # Truncate long commands
    if [ ${#CMD} -gt 80 ]; then
      CMD="${CMD:0:77}..."
    fi
    SUMMARY="Ran: $CMD"
    ;;
  Task)
    DESC="$(echo "$TOOL_INPUT" | grep -o '"description":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    SUMMARY="Task: $DESC"
    ;;
  *)
    SUMMARY="$TOOL_NAME"
    ;;
esac

if [ -z "$SUMMARY" ]; then
  SUMMARY="$TOOL_NAME"
fi

# POST to web server (fire-and-forget, 5s timeout)
curl -s -m 5 -X POST "$URL/api/activity?session=$SESSION_ID" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: $TOKEN" \
  -d "{\"tool\":\"$TOOL_NAME\",\"summary\":$(printf '%s' "$SUMMARY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}" \
  > /dev/null 2>&1 || true

exit 0
