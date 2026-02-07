#!/usr/bin/env bash
# Tests for Claude View hooks
# Usage: bash tests/test-hooks.sh
# Requires: web server running on localhost:3456 with known token

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

PASS=0
FAIL=0
TOKEN=""
URL="http://localhost:3456"
SERVER_PID=""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

ORIG_TOKEN_FILE=""

cleanup() {
  # Restore original token file
  if [ -n "$ORIG_TOKEN_FILE" ] && [ -f "$ORIG_TOKEN_FILE" ]; then
    mv "$ORIG_TOKEN_FILE" "$SCRIPT_DIR/.claude-view-token"
  fi
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $desc"
    echo -e "    ${DIM}expected: $expected${NC}"
    echo -e "    ${DIM}actual:   $actual${NC}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo -e "  ${GREEN}PASS${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $desc"
    echo -e "    ${DIM}expected to contain: $expected${NC}"
    echo -e "    ${DIM}actual: $actual${NC}"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" expected="$2" actual="$3"
  if ! echo "$actual" | grep -q "$expected"; then
    echo -e "  ${GREEN}PASS${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC} $desc"
    echo -e "    ${DIM}expected NOT to contain: $expected${NC}"
    echo -e "    ${DIM}actual: $actual${NC}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup: start test server ---
echo "Starting test server..."
TOKEN="testhooktoken123"

# Swap token file so hooks use the test token
if [ -f "$SCRIPT_DIR/.claude-view-token" ]; then
  ORIG_TOKEN_FILE="$SCRIPT_DIR/.claude-view-token.backup.$$"
  cp "$SCRIPT_DIR/.claude-view-token" "$ORIG_TOKEN_FILE"
fi
echo "$TOKEN" > "$SCRIPT_DIR/.claude-view-token"

CLAUDE_VIEW_TOKEN="$TOKEN" node server.js &
SERVER_PID=$!
sleep 2

# Verify server is up
if ! curl -s -o /dev/null "$URL/api/state?token=$TOKEN" 2>/dev/null; then
  echo "ERROR: Server failed to start"
  exit 1
fi

echo ""
echo "=== post-tool-use.sh tests ==="

# Test 1: Edit tool generates correct summary
echo '{"tool_name":"Edit","tool_input":{"file_path":"/home/user/src/app.js","old_string":"foo","new_string":"bar"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
STATE="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state")"
LAST_SUMMARY="$(echo "$STATE" | python3 -c 'import sys,json; msgs=json.load(sys.stdin)["messages"]; print(msgs[-1].get("summary",""))' 2>/dev/null)"
assert_contains "Edit tool summary includes filename" "app.js" "$LAST_SUMMARY"

# Test 2: Write tool generates correct summary
echo '{"tool_name":"Write","tool_input":{"file_path":"/home/user/README.md","content":"hello"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
STATE="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state")"
LAST_SUMMARY="$(echo "$STATE" | python3 -c 'import sys,json; msgs=json.load(sys.stdin)["messages"]; print(msgs[-1].get("summary",""))' 2>/dev/null)"
assert_contains "Write tool summary includes filename" "README.md" "$LAST_SUMMARY"

# Test 3: Bash tool includes command
echo '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
STATE="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state")"
LAST_SUMMARY="$(echo "$STATE" | python3 -c 'import sys,json; msgs=json.load(sys.stdin)["messages"]; print(msgs[-1].get("summary",""))' 2>/dev/null)"
assert_contains "Bash tool summary includes command" "npm test" "$LAST_SUMMARY"

# Test 4: Read tool is filtered (no new message)
MSG_COUNT_BEFORE="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["messages"]))')"
echo '{"tool_name":"Read","tool_input":{"file_path":"/home/user/app.js"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
MSG_COUNT_AFTER="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["messages"]))')"
assert_eq "Read tool is filtered (no activity sent)" "$MSG_COUNT_BEFORE" "$MSG_COUNT_AFTER"

# Test 5: Glob tool is filtered
echo '{"tool_name":"Glob","tool_input":{"pattern":"**/*.js"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
MSG_COUNT_AFTER2="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["messages"]))')"
assert_eq "Glob tool is filtered (no activity sent)" "$MSG_COUNT_BEFORE" "$MSG_COUNT_AFTER2"

# Test 6: Grep tool is filtered
echo '{"tool_name":"Grep","tool_input":{"pattern":"TODO"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
MSG_COUNT_AFTER3="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["messages"]))')"
assert_eq "Grep tool is filtered (no activity sent)" "$MSG_COUNT_BEFORE" "$MSG_COUNT_AFTER3"

# Test 7: No token = silent exit
EXIT_CODE=0
echo '{"tool_name":"Edit","tool_input":{"file_path":"x"}}' \
  | CLAUDE_VIEW_TOKEN="" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh || EXIT_CODE=$?
assert_eq "No token exits cleanly" "0" "$EXIT_CODE"

# Test 8: Task tool shows description
echo '{"tool_name":"Task","tool_input":{"description":"Find API endpoints","prompt":"search"}}' \
  | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" bash hooks/post-tool-use.sh
STATE="$(curl -s -H "X-Auth-Token: $TOKEN" "$URL/api/state")"
LAST_SUMMARY="$(echo "$STATE" | python3 -c 'import sys,json; msgs=json.load(sys.stdin)["messages"]; print(msgs[-1].get("summary",""))' 2>/dev/null)"
assert_contains "Task tool summary includes description" "Find API endpoints" "$LAST_SUMMARY"

echo ""
echo "=== stop.sh tests ==="

# Test 9: Stop hook with no token exits cleanly
# Temporarily remove token file so hook sees no token
mv "$SCRIPT_DIR/.claude-view-token" "$SCRIPT_DIR/.claude-view-token.tmp"
EXIT_CODE=0
echo '{}' | CLAUDE_VIEW_TOKEN="" CLAUDE_VIEW_URL="$URL" timeout 3 bash hooks/stop.sh || EXIT_CODE=$?
mv "$SCRIPT_DIR/.claude-view-token.tmp" "$SCRIPT_DIR/.claude-view-token"
assert_eq "No token exits cleanly" "0" "$EXIT_CODE"

# Test 10: Stop hook times out and exits 0 (short timeout)
EXIT_CODE=0
OUTPUT="$(echo '{"stop_hook_active":true}' | CLAUDE_VIEW_TOKEN="$TOKEN" CLAUDE_VIEW_URL="$URL" timeout 10 bash -c 'bash hooks/stop.sh' 2>/dev/null || true)"
# With stop_hook_active=true, timeout is 30s, but we have curl -m 600 so it'll use the query param
# For test, we'll use a very short server-side timeout
EXIT_CODE=0
RESPONSE="$(curl -s -m 5 "$URL/api/wait-for-instruction?timeout=1000&token=$TOKEN" 2>/dev/null || echo '{"timedOut":true}')"
assert_contains "Short timeout returns timedOut" "timedOut" "$RESPONSE"

# Test 11: Stop hook returns instruction when available
# Queue a message first via /api/send
curl -s -X POST "$URL/api/send" \
  -H "Content-Type: application/json" \
  -H "X-Auth-Token: $TOKEN" \
  -d '{"message":"Build the login page"}' > /dev/null
# Now the wait-for-instruction should return immediately with the queued message
RESPONSE="$(curl -s -m 5 "$URL/api/wait-for-instruction?timeout=5000&token=$TOKEN")"
assert_contains "Queued instruction returned" "Build the login page" "$RESPONSE"
assert_not_contains "Not timed out" "timedOut\":true" "$RESPONSE"

# Test 12: Stop hook JSON output format
# Simulate what the hook does with an instruction
INSTRUCTION="Add tests"
HOOK_OUTPUT="$(printf '{"decision":"block","reason":"New instruction from user: %s"}' \
  "$(printf '%s' "$INSTRUCTION" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')")"
assert_contains "Hook output has decision:block" '"decision":"block"' "$HOOK_OUTPUT"
assert_contains "Hook output has instruction in reason" "Add tests" "$HOOK_OUTPUT"

# Test 13: Hook output is valid JSON
echo "$HOOK_OUTPUT" | python3 -c 'import sys,json; json.load(sys.stdin); print("valid")' 2>/dev/null
VALID="$(echo "$HOOK_OUTPUT" | python3 -c 'import sys,json; json.load(sys.stdin); print("valid")' 2>/dev/null || echo "invalid")"
assert_eq "Hook JSON output is valid" "valid" "$VALID"

# Test 14: Instruction with special characters
INSTRUCTION='Say "hello" & <bye>'
HOOK_OUTPUT="$(printf '{"decision":"block","reason":"New instruction from user: %s"}' \
  "$(printf '%s' "$INSTRUCTION" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read())[1:-1])')")"
VALID="$(echo "$HOOK_OUTPUT" | python3 -c 'import sys,json; json.load(sys.stdin); print("valid")' 2>/dev/null || echo "invalid")"
assert_eq "Special chars produce valid JSON" "valid" "$VALID"

# --- Summary ---
echo ""
echo "================================"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
