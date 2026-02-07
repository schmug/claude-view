# Claude View

Mobile web remote control for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Manage autonomous coding sessions from your phone via Cloudflare Tunnel.

```
Phone (anywhere)  ──>  Cloudflare Tunnel  ──>  Web Server  <──  Claude Code (your machine)
```

Once running, you never need to touch the terminal again. Claude works independently and communicates through a mobile-friendly chat UI when it needs you.

## How It Works

Three components connect through a central web server:

```
┌──────────────┐  stdio   ┌──────────────┐  HTTP    ┌──────────────┐
│  Claude Code │◄────────►│  MCP Server  │────────►│              │
│    (CLI)     │          │ (mcp-server) │         │  Web Server  │
└──────────────┘          └──────────────┘         │  (Express +  │
                                                    │  Socket.IO)  │  WebSocket
┌──────────────┐  HTTP (curl)                      │  port 3456   │◄────────►  Phone
│    Hooks     │──────────────────────────────────►│              │          (via Tunnel)
│ (stop, post) │                                   └──────────────┘
└──────────────┘
```

- **Web Server** (`server.js`) — Long-lived Express + Socket.IO process. Stores messages, manages question/answer flows, and bridges all components.
- **MCP Server** (`mcp-server.js`) — Gives Claude 4 tools (`notify`, `ask`, `inbox`, `status`) to communicate with your phone. Runs as a stdio subprocess of Claude Code.
- **Stop Hook** (`hooks/stop.sh`) — When Claude finishes a task, it long-polls the server for your next instruction. You send it from your phone, Claude picks it up and keeps working.
- **Post-Tool-Use Hook** (`hooks/post-tool-use.sh`) — Streams Claude's activity (edits, commands, tasks) to your phone as a live feed.
- **Web UI** (`public/index.html`) — Single-file dark-theme mobile interface with real-time updates via Socket.IO.

## Prerequisites

- **Node.js** v23+
- **Claude Code** CLI installed and authenticated
- **cloudflared** ([install guide](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/)) — for remote access from your phone
- Optional: `qrencode` for QR code display (`sudo apt install qrencode`)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/schmug/claude-view.git
cd claude-view

# Start everything (server + tunnel)
bash start.sh
```

This will:
1. Generate an auth token (saved to `.claude-view-token`)
2. Install npm dependencies
3. Start the web server on port 3456
4. Start a Cloudflare tunnel for remote access
5. Display your local URL, tunnel URL, and auth token

You'll see something like this:

```
============================================
  Claude View is running
============================================

  Local:  http://localhost:3456/#a1b2c3d4e5f6a1b2
  Remote: https://example-tunnel.trycloudflare.com/#a1b2c3d4e5f6a1b2

  Token:  a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4

  Scan to open on phone:

  █████████████████████████████
  ██ ▄▄▄▄▄ █▄ █▄▀█ ▄▄▄▄▄ ██
  ██ █   █ █▀▄▀▀██ █   █ ██
  ██ █▄▄▄█ █ ▄▀▄██ █▄▄▄█ ██
  ██▄▄▄▄▄▄▄█ ▀ ▀ █▄▄▄▄▄▄▄██
  ██▄▀▄ █▀▄▀▄█▀▄█▀▀ ▀▄█▀▄██
  ██▄▄▄▄▄▄▄█▄███▄█▄▄█▄▄████
  █████████████████████████████

============================================
  Press Ctrl+C to stop
============================================
```

Open the tunnel URL on your phone (scan the QR code or copy the link).

Then in another terminal:

```bash
cd claude-view
claude
```

Give Claude an initial prompt to activate the autonomous loop:

```
Read CLAUDE.md and follow its instructions. Load the claude-view MCP tools
(notify, ask, inbox, status) and send a test notification. Then wait for instructions.
```

From now on, send instructions from your phone. Claude will work autonomously and report back through the UI.

## Example Session

**Your phone (Chat tab):**

```
┌─────────────────────────────────┐
│ 🟢 Claude View    Building auth │
├─────────────────────────────────┤
│                                 │
│ ┌─ info ──────────────────────┐ │
│ │ Got it! Working on auth.    │ │
│ └─────────────────────────────┘ │
│                                 │
│  Edited: auth.js         14:02  │
│  Ran: npm test           14:03  │
│                                 │
│ ┌─ success ───────────────────┐ │
│ │ Auth module complete! Added │ │
│ │ JWT login & middleware.     │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─── question ────────────────┐ │
│ │ Should I add refresh tokens │ │
│ │ or is basic JWT enough?     │ │
│ │                             │ │
│ │ [Basic JWT]  [Add refresh]  │ │
│ └─────────────────────────────┘ │
│                                 │
│              Add a login page ▶ │
│                       You 14:01 │
│                                 │
├─────────────────────────────────┤
│  [Reply to question...]    [▶]  │
└─────────────────────────────────┘
```

**Your terminal (you never need to look at this):**

```
$ claude
╭──────────────────────────────────────╮
│ Claude Code                    v1.0  │
╰──────────────────────────────────────╯

> Read CLAUDE.md and follow its instructions...

● Reading CLAUDE.md
● Loading MCP tools (notify, ask, inbox, status)
● Sent test notification

Stop hook feedback: New instruction from user: Add a login page

● Using notify: "Got it! Working on auth."
● Using status: "Building auth"
● Editing auth.js
● Running npm test
● Using notify (success): "Auth module complete!"
● Using ask: "Should I add refresh tokens?"
  Waiting for response...
```

## What You See on Your Phone

**Two tabs:**
- **Chat** — full conversation: notifications, questions, your messages, and activity
- **Activity** — tool activity only (edits, commands, tasks) with unread badge

**Message types:**
- **Activity** — dimmed entries showing what Claude is doing (editing files, running commands)
- **Notifications** — color-coded messages from Claude (blue=info, green=success, amber=warning, red=error)
- **Questions** — purple cards with tap-to-answer buttons when Claude needs your input
- **Your messages** — right-aligned green bubbles
- **Status bar** — current task shown at the top

**Alerts:**
- Audio beep + title flash when Claude asks a question
- Optional push notifications (prompted on first visit) for questions, completions, and errors

## MCP Tools

Claude gets these 4 tools via the MCP server:

| Tool | Blocking? | Purpose |
|------|-----------|---------|
| `notify` | No | Send a message to your phone (info/warning/error/success) |
| `ask` | Yes | Ask a question, wait up to 5 min for your response |
| `inbox` | No | Check for queued instructions you've sent |
| `status` | No | Update the status bar on your phone |

## The Autonomous Loop

```
1. Claude finishes a task
2. Stop hook fires, long-polls the server
3. You send an instruction from your phone
4. Stop hook delivers it to Claude as: "New instruction from user: ..."
5. Claude reads CLAUDE.md, acknowledges via notify, does the work
6. Back to step 1
```

The stop hook has loop prevention: if `stop_hook_active` is true (re-entry), it uses a 30-second timeout instead of 590 seconds.

## Configuration

### Server Port

```bash
CLAUDE_VIEW_PORT=4000 bash start.sh
```

### Files

| File | Purpose |
|------|---------|
| `server.js` | Web server (Express + Socket.IO, port 3456) |
| `mcp-server.js` | MCP stdio server with 4 tools |
| `public/index.html` | Mobile web UI (single file, all inline) |
| `hooks/stop.sh` | Autonomous continuation hook |
| `hooks/post-tool-use.sh` | Activity feed hook |
| `start.sh` | Startup orchestration |
| `.mcp.json` | MCP server registration for Claude Code |
| `.claude/settings.local.json` | Hook config + MCP tool permissions |
| `CLAUDE.md` | Instructions Claude follows for autonomous behavior |
| `.claude-view-token` | Generated auth token (gitignored) |

### Auth

All endpoints require authentication via:
- `X-Auth-Token` header, or
- `?token=` query parameter

The browser receives the token from the URL hash (`#TOKEN`). The token is auto-generated by `start.sh` and saved to `.claude-view-token`.

## API Endpoints

| Endpoint | Caller | Purpose |
|----------|--------|---------|
| `POST /api/activity` | Post-tool-use hook | Log tool activity |
| `POST /api/message` | MCP `notify` | Send notification |
| `POST /api/ask` | MCP `ask` | Ask question (long-poll) |
| `POST /api/status` | MCP `status` | Update status bar |
| `GET /api/inbox` | MCP `inbox` | Drain message queue |
| `GET /api/wait-for-instruction` | Stop hook | Long-poll for next instruction |
| `POST /api/respond` | Browser | Answer a pending question |
| `POST /api/send` | Browser | Send instruction to Claude |
| `GET /api/state` | Browser | Get full current state |

## Troubleshooting

**Claude doesn't respond to phone messages**
- Make sure you gave Claude an initial prompt that loads the MCP tools
- Check that `.claude/settings.local.json` has the hook configuration
- Only one Claude session can poll for instructions at a time

**"No auth token" warning in the browser**
- The URL must include `#TOKEN` at the end (start.sh shows the full URL)

**MCP server warning about missing env vars**
- The MCP server reads the token from `.claude-view-token` directly, so this warning is harmless

**Stop hook not firing**
- Verify `.claude/settings.local.json` has the Stop hook configured without a `matcher` field
- Stop hooks don't support matchers — they always fire

**Multiple Claude sessions**
- Only one session can long-poll at a time. Close other sessions to avoid conflicts.

## License

MIT
