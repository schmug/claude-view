#!/usr/bin/env bash
# Stop hook: keeps Claude running by long-polling for new instructions
# When user sends instruction via phone, Claude continues with that instruction

set -euo pipefail

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
  # No token means no web server - let Claude stop normally
  exit 0
fi

# Read stdin JSON
INPUT="$(cat)"

# Check stop_hook_active to prevent re-entry loops
STOP_HOOK_ACTIVE="$(echo "$INPUT" | grep -o '"stop_hook_active":true' || true)"

if [ -n "$STOP_HOOK_ACTIVE" ]; then
  # We're in a re-entry - use short timeout to avoid infinite loops
  TIMEOUT=30000
else
  TIMEOUT=590000
fi

# Long-poll for new instruction
RESPONSE="$(curl -s -m 600 \
  "$URL/api/wait-for-instruction?timeout=$TIMEOUT&token=$TOKEN" \
  2>/dev/null || echo '{"timedOut":true}')"

# Check if we got an instruction
TIMED_OUT="$(echo "$RESPONSE" | grep -o '"timedOut":true' || true)"

if [ -n "$TIMED_OUT" ]; then
  # No instruction came in - let Claude actually stop
  exit 0
fi

# Extract instruction
INSTRUCTION="$(echo "$RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("instruction",""))' 2>/dev/null || true)"

if [ -z "$INSTRUCTION" ]; then
  exit 0
fi

# Block Claude from stopping, provide the new instruction
# The JSON output tells Claude Code to continue with this instruction
printf '{"decision":"block","reason":"New instruction from user: %s"}' \
  "$(printf '%s' "$INSTRUCTION" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')"
