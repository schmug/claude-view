#!/usr/bin/env bash
# Claude View - Startup Orchestration
# Starts the web server and Cloudflare tunnel, displays connection info

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PORT="${CLAUDE_VIEW_PORT:-3456}"
TOKEN_FILE=".claude-view-token"
SERVER_PID=""
TUNNEL_PID=""

cleanup() {
  echo ""
  echo "Shutting down..."
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  echo "Done."
}

trap cleanup EXIT INT TERM

# 1. Generate auth token
if [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(cat "$TOKEN_FILE")"
  echo "Using existing token from $TOKEN_FILE"
else
  TOKEN="$(openssl rand -hex 16)"
  echo "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "Generated new auth token"
fi

export CLAUDE_VIEW_TOKEN="$TOKEN"
export CLAUDE_VIEW_PORT="$PORT"

# 2. Install dependencies if needed
if [ ! -d "node_modules" ]; then
  echo "Installing dependencies..."
  npm install
fi

# 3. Start web server
echo "Starting web server on port $PORT..."
node server.js &
SERVER_PID=$!

# Wait for server to be ready
for i in $(seq 1 30); do
  if curl -s -o /dev/null "http://localhost:$PORT/api/state?token=$TOKEN" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

echo "Web server running (PID $SERVER_PID)"

# 4. Start Cloudflare tunnel
TUNNEL_URL=""
if command -v cloudflared &>/dev/null; then
  echo "Starting Cloudflare tunnel..."

  TUNNEL_LOG="$(mktemp)"
  cloudflared tunnel --url "http://localhost:$PORT" >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!

  # Wait for tunnel URL (up to 15 seconds)
  for i in $(seq 1 30); do
    TUNNEL_URL="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1 || true)"
    if [ -n "$TUNNEL_URL" ]; then
      break
    fi
    sleep 0.5
  done

  rm -f "$TUNNEL_LOG"

  if [ -n "$TUNNEL_URL" ]; then
    echo "Tunnel running (PID $TUNNEL_PID)"
  else
    echo "WARNING: Could not detect tunnel URL (tunnel may still be starting)"
  fi
else
  echo "cloudflared not found - skipping tunnel (install: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/)"
fi

# 5. Display connection info
echo ""
echo "============================================"
echo "  Claude View is running"
echo "============================================"
echo ""
echo "  Local:  http://localhost:${PORT}/#${TOKEN}"
echo ""
if [ -n "$TUNNEL_URL" ]; then
  echo "  Remote: ${TUNNEL_URL}/#${TOKEN}"
  echo ""
fi
echo "  Token:  ${TOKEN}"
echo ""

# 6. Generate QR code if available
if [ -n "$TUNNEL_URL" ] && command -v qrencode &>/dev/null; then
  echo "  Scan to open on phone:"
  echo ""
  qrencode -t ANSIUTF8 "${TUNNEL_URL}/#${TOKEN}" 2>/dev/null || true
  echo ""
elif [ -n "$TUNNEL_URL" ]; then
  echo "  (Install qrencode for QR code: sudo apt install qrencode)"
  echo ""
fi

echo "============================================"
echo "  Press Ctrl+C to stop"
echo "============================================"
echo ""

# Keep running
wait "$SERVER_PID"
