#!/usr/bin/env bash
# Stop hook: keeps Claude running by long-polling for new instructions
# When user sends instruction via phone, Claude continues with that instruction
# On timeout, sends a keepalive to keep the autonomous loop alive

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

# Read stdin JSON (required by hook protocol)
cat > /dev/null

# Idle keepalive tracking - stop after MAX_IDLE consecutive keepalives (~30min)
IDLE_FILE="/tmp/claude-view-idle-count"
MAX_IDLE=3

# Long-poll for new instruction (590s, just under the 600s hook timeout)
RESPONSE="$(curl -s -m 600 \
  "$URL/api/wait-for-instruction?timeout=590000&token=$TOKEN" \
  2>/dev/null || echo '{"timedOut":true}')"

# Check if we got an instruction
TIMED_OUT="$(echo "$RESPONSE" | grep -o '"timedOut":true' || true)"

if [ -n "$TIMED_OUT" ]; then
  # No instruction - send keepalive to keep the loop alive
  COUNT="$(cat "$IDLE_FILE" 2>/dev/null || echo 0)"
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$IDLE_FILE"

  if [ "$COUNT" -ge "$MAX_IDLE" ]; then
    # Been idle too long (~30min) - let Claude actually stop
    rm -f "$IDLE_FILE"
    exit 0
  fi

  printf '{"decision":"block","reason":"[KEEPALIVE] Waiting for instructions from phone (%d/%d idle checks)"}' \
    "$COUNT" "$MAX_IDLE"
  exit 0
fi

# Got a real instruction - reset idle counter
rm -f "$IDLE_FILE"

# Extract instruction
INSTRUCTION="$(echo "$RESPONSE" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("instruction",""))' 2>/dev/null || true)"

if [ -z "$INSTRUCTION" ]; then
  exit 0
fi

# Block Claude from stopping, provide the new instruction
printf '{"decision":"block","reason":"New instruction from user: %s"}' \
  "$(printf '%s' "$INSTRUCTION" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')"
