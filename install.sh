#!/usr/bin/env bash
set -euo pipefail

CLAUDE_VIEW_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

# Validate
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required (apt install jq)"; exit 1; }
[ -f "$CLAUDE_VIEW_DIR/mcp-server.js" ] || { echo "ERROR: mcp-server.js not found in $CLAUDE_VIEW_DIR"; exit 1; }

echo "Installing claude-view in $TARGET"
echo "  (claude-view dir: $CLAUDE_VIEW_DIR)"
echo ""

# 1. .mcp.json
MCP_FILE="$TARGET/.mcp.json"
if [ ! -f "$MCP_FILE" ]; then
  echo '{"mcpServers":{}}' > "$MCP_FILE"
fi
jq --arg dir "$CLAUDE_VIEW_DIR" \
  '.mcpServers["claude-view"] = {
    "command":"node",
    "args":[($dir + "/mcp-server.js")],
    "env":{"CLAUDE_VIEW_URL":"http://localhost:3456"}
  }' "$MCP_FILE" > "$MCP_FILE.tmp" && mv "$MCP_FILE.tmp" "$MCP_FILE"
echo "  .mcp.json - MCP server registered"

# 2. .claude/settings.local.json
mkdir -p "$TARGET/.claude"
SETTINGS="$TARGET/.claude/settings.local.json"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

STOP_CMD="bash $CLAUDE_VIEW_DIR/hooks/stop.sh"
POST_CMD="bash $CLAUDE_VIEW_DIR/hooks/post-tool-use.sh"

jq --arg stop "$STOP_CMD" --arg post "$POST_CMD" '
  # Remove existing claude-view hooks, then re-add (idempotent)
  .hooks.PostToolUse = [(.hooks.PostToolUse // [])[] |
    select((.hooks[0].command // "") | test("claude-view") | not)] +
    [{"hooks":[{"type":"command","command":$post,"timeout":10000}]}] |
  .hooks.Stop = [(.hooks.Stop // [])[] |
    select((.hooks[0].command // "") | test("claude-view") | not)] +
    [{"hooks":[{"type":"command","command":$stop,"timeout":600000}]}] |
  # Add permissions (dedup first)
  .permissions.allow = ([(.permissions.allow // [])[] |
    select(startswith("mcp__claude-view__") | not)] +
    ["mcp__claude-view__notify","mcp__claude-view__ask",
     "mcp__claude-view__inbox","mcp__claude-view__status"])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "  .claude/settings.local.json - hooks + permissions added"

# 3. CLAUDE.md
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER_START="<!-- claude-view-start -->"
MARKER_END="<!-- claude-view-end -->"
INSTRUCTIONS="$(cat "$CLAUDE_VIEW_DIR/CLAUDE.md")"

if [ -f "$CLAUDE_MD" ]; then
  # Remove existing marked section if present (idempotent)
  if grep -q "$MARKER_START" "$CLAUDE_MD"; then
    sed -i "/$MARKER_START/,/$MARKER_END/d" "$CLAUDE_MD"
  fi
fi

# Append instructions with markers
cat >> "$CLAUDE_MD" << EOF

$MARKER_START
$INSTRUCTIONS
$MARKER_END
EOF
echo "  CLAUDE.md - autonomous instructions appended"

echo ""
echo "Done! To use claude-view from $TARGET:"
echo "  1. Start the server:  bash $CLAUDE_VIEW_DIR/start.sh"
echo "  2. Open Claude in:    cd $TARGET && claude"
