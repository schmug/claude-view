import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import * as z from "zod/v4";

// All logging to stderr (stdout is MCP protocol)
const log = (...args) => console.error("[claude-view-mcp]", ...args);

const __dirname = dirname(fileURLToPath(import.meta.url));
const BASE_URL = process.env.CLAUDE_VIEW_URL || "http://localhost:3456";
const TOKEN =
  process.env.CLAUDE_VIEW_TOKEN ||
  (() => {
    const tokenFile = join(__dirname, ".claude-view-token");
    if (existsSync(tokenFile)) return readFileSync(tokenFile, "utf-8").trim();
    return "";
  })();

if (!TOKEN) {
  log("WARNING: No CLAUDE_VIEW_TOKEN found (env or .claude-view-token file)");
}

async function post(path, body) {
  const res = await fetch(`${BASE_URL}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Auth-Token": TOKEN,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  return res.json();
}

async function get(path) {
  const res = await fetch(`${BASE_URL}${path}`, {
    headers: { "X-Auth-Token": TOKEN },
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  return res.json();
}

const server = new McpServer({
  name: "claude-view",
  version: "1.0.0",
});

// --- notify: Send info/warning/success/error message (non-blocking) ---
server.tool(
  "notify",
  "Send a notification to the user's mobile web UI. Use for progress updates, warnings, and results.",
  {
    message: z.string().describe("The message to display"),
    level: z
      .enum(["info", "warning", "error", "success"])
      .default("info")
      .describe("Message severity level"),
  },
  async ({ message, level }) => {
    try {
      await post("/api/message", { message, level });
      return { content: [{ type: "text", text: `Notification sent (${level})` }] };
    } catch (err) {
      log("notify error:", err.message);
      return { content: [{ type: "text", text: `Failed to send: ${err.message}` }], isError: true };
    }
  }
);

// --- ask: Ask question, wait for response (blocking) ---
server.tool(
  "ask",
  "Ask the user a question and wait for their response via the mobile web UI. Blocks until the user responds or timeout (5 min). Use only when genuinely blocked and need user input.",
  {
    question: z.string().describe("The question to ask the user"),
    options: z
      .array(z.string())
      .default([])
      .describe("Optional quick-tap response options (keep short for mobile)"),
  },
  async ({ question, options }) => {
    try {
      log("Asking:", question);
      const result = await post("/api/ask", { question, options });
      if (result.timedOut) {
        return {
          content: [
            {
              type: "text",
              text: "No response received within 5 minutes. Proceed with your best judgment.",
            },
          ],
        };
      }
      return { content: [{ type: "text", text: result.answer }] };
    } catch (err) {
      log("ask error:", err.message);
      return {
        content: [{ type: "text", text: `Failed to ask: ${err.message}. Proceed with best judgment.` }],
        isError: true,
      };
    }
  }
);

// --- inbox: Check for new user messages (non-blocking) ---
server.tool(
  "inbox",
  "Check for new messages/instructions from the user. Returns any queued messages and clears the queue. Call between tasks or at milestones.",
  {},
  async () => {
    try {
      const result = await get("/api/inbox");
      if (result.messages.length === 0) {
        return { content: [{ type: "text", text: "No new messages." }] };
      }
      const text = result.messages
        .map((m, i) => `${i + 1}. ${m}`)
        .join("\n");
      return { content: [{ type: "text", text: `New messages:\n${text}` }] };
    } catch (err) {
      log("inbox error:", err.message);
      return { content: [{ type: "text", text: `Failed to check inbox: ${err.message}` }], isError: true };
    }
  }
);

// --- status: Update task status display (non-blocking) ---
server.tool(
  "status",
  "Update the task status shown in the top bar of the mobile web UI. Use to show current activity at a high level.",
  {
    status: z.string().describe("Short status text (e.g., 'Building auth module', 'Running tests')"),
  },
  async ({ status }) => {
    try {
      await post("/api/status", { status });
      return { content: [{ type: "text", text: `Status updated: ${status}` }] };
    } catch (err) {
      log("status error:", err.message);
      return { content: [{ type: "text", text: `Failed to update status: ${err.message}` }], isError: true };
    }
  }
);

// --- Start ---
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("MCP server connected via stdio");
}

main().catch((err) => {
  log("Fatal:", err);
  process.exit(1);
});
