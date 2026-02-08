#!/usr/bin/env bash
set -euo pipefail

CLAUDE_VIEW_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:-.}"
TARGET="$(cd "$TARGET" && pwd)"

# Validate
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required (apt install jq)"; exit 1; }

echo "Uninstalling claude-view from $TARGET"
echo ""

# 1. .mcp.json - remove claude-view key
MCP_FILE="$TARGET/.mcp.json"
if [ -f "$MCP_FILE" ]; then
  jq 'del(.mcpServers["claude-view"])' "$MCP_FILE" > "$MCP_FILE.tmp" && mv "$MCP_FILE.tmp" "$MCP_FILE"
  # Remove file if it's now empty
  if [ "$(jq '.mcpServers | length' "$MCP_FILE")" = "0" ]; then
    rm "$MCP_FILE"
    echo "  .mcp.json - removed (was empty)"
  else
    echo "  .mcp.json - claude-view entry removed"
  fi
else
  echo "  .mcp.json - not found, skipping"
fi

# 2. .claude/settings.local.json - remove claude-view hooks and permissions
SETTINGS="$TARGET/.claude/settings.local.json"
if [ -f "$SETTINGS" ]; then
  jq '
    # Remove claude-view hooks
    (if .hooks.PostToolUse then
      .hooks.PostToolUse = [.hooks.PostToolUse[] |
        select((.hooks[0].command // "") | test("claude-view") | not)]
    else . end) |
    (if .hooks.Stop then
      .hooks.Stop = [.hooks.Stop[] |
        select((.hooks[0].command // "") | test("claude-view") | not)]
    else . end) |
    # Remove empty hook arrays
    (if (.hooks.PostToolUse // []) | length == 0 then del(.hooks.PostToolUse) else . end) |
    (if (.hooks.Stop // []) | length == 0 then del(.hooks.Stop) else . end) |
    (if (.hooks // {}) | length == 0 then del(.hooks) else . end) |
    # Remove claude-view permissions
    (if .permissions.allow then
      .permissions.allow = [.permissions.allow[] |
        select(startswith("mcp__claude-view__") | not)]
    else . end) |
    (if (.permissions.allow // []) | length == 0 then del(.permissions.allow) else . end) |
    (if (.permissions // {}) | length == 0 then del(.permissions) else . end)
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

  # Remove file if it's now empty
  if [ "$(jq 'length' "$SETTINGS")" = "0" ]; then
    rm "$SETTINGS"
    # Remove .claude dir if empty
    rmdir "$TARGET/.claude" 2>/dev/null || true
    echo "  .claude/settings.local.json - removed (was empty)"
  else
    echo "  .claude/settings.local.json - claude-view entries removed"
  fi
else
  echo "  .claude/settings.local.json - not found, skipping"
fi

# 3. CLAUDE.md - remove marked section
CLAUDE_MD="$TARGET/CLAUDE.md"
MARKER_START="<!-- claude-view-start -->"
MARKER_END="<!-- claude-view-end -->"
if [ -f "$CLAUDE_MD" ]; then
  if grep -q "$MARKER_START" "$CLAUDE_MD"; then
    sed -i "/$MARKER_START/,/$MARKER_END/d" "$CLAUDE_MD"
    # Remove trailing blank lines
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CLAUDE_MD"
    # Remove file if empty
    if [ ! -s "$CLAUDE_MD" ]; then
      rm "$CLAUDE_MD"
      echo "  CLAUDE.md - removed (was empty)"
    else
      echo "  CLAUDE.md - claude-view section removed"
    fi
  else
    echo "  CLAUDE.md - no claude-view section found, skipping"
  fi
else
  echo "  CLAUDE.md - not found, skipping"
fi

echo ""
echo "claude-view uninstalled from $TARGET"
