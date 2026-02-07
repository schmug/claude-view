import express from "express";
import { createServer } from "http";
import { Server } from "socket.io";
import { readFileSync, existsSync } from "fs";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.CLAUDE_VIEW_PORT || "3456", 10);
const TOKEN =
  process.env.CLAUDE_VIEW_TOKEN ||
  (() => {
    const tokenFile = join(__dirname, ".claude-view-token");
    if (existsSync(tokenFile))
      return readFileSync(tokenFile, "utf-8").trim();
    return null;
  })();

if (!TOKEN) {
  console.error(
    "No auth token set. Set CLAUDE_VIEW_TOKEN or create .claude-view-token"
  );
  process.exit(1);
}

// --- Message Store (ring buffer) ---

class MessageStore {
  constructor(capacity = 200) {
    this.capacity = capacity;
    this.messages = [];
    this.nextId = 1;
  }

  add(msg) {
    const entry = { id: this.nextId++, ts: Date.now(), ...msg };
    this.messages.push(entry);
    if (this.messages.length > this.capacity) {
      this.messages.shift();
    }
    return entry;
  }

  since(afterId = 0) {
    return this.messages.filter((m) => m.id > afterId);
  }

  all() {
    return this.messages;
  }
}

const store = new MessageStore();

// --- Pending state ---

let pendingQuestion = null; // { id, resolve, timer }
let inbox = [];
let instructionWaiter = null; // { resolve, timer }
let currentStatus = "";

// --- Express + Socket.IO ---

const app = express();
const httpServer = createServer(app);
const io = new Server(httpServer, {
  cors: { origin: "*" },
});

app.use(express.json());
app.use(express.static(join(__dirname, "public")));

// --- Auth middleware ---

function auth(req, res, next) {
  const token =
    req.headers["x-auth-token"] ||
    req.query.token;
  if (token === TOKEN) return next();
  res.status(401).json({ error: "Unauthorized" });
}

// Socket.IO auth
io.use((socket, next) => {
  const token =
    socket.handshake.auth?.token ||
    socket.handshake.query?.token;
  if (token === TOKEN) return next();
  next(new Error("Unauthorized"));
});

// --- Helper ---

function broadcast(entry) {
  io.emit("message", entry);
}

// --- API Endpoints ---

// POST /api/activity - from PostToolUse hook (non-blocking)
app.post("/api/activity", auth, (req, res) => {
  const { tool, summary } = req.body;
  const entry = store.add({ type: "activity", tool, summary });
  broadcast(entry);
  res.json({ ok: true, id: entry.id });
});

// POST /api/message - from MCP notify (non-blocking)
app.post("/api/message", auth, (req, res) => {
  const { message, level } = req.body;
  const entry = store.add({
    type: "notification",
    message,
    level: level || "info",
  });
  broadcast(entry);
  res.json({ ok: true, id: entry.id });
});

// POST /api/ask - from MCP ask (long-polls until user responds)
app.post("/api/ask", auth, (req, res) => {
  const { question, options } = req.body;

  // Cancel any existing pending question
  if (pendingQuestion) {
    clearTimeout(pendingQuestion.timer);
    pendingQuestion.resolve({ answer: null, timedOut: true });
  }

  const questionId = store.nextId;
  const entry = store.add({
    type: "question",
    question,
    options: options || [],
    answered: false,
  });
  broadcast(entry);

  const timeout = 5 * 60 * 1000; // 5 minutes

  const promise = new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (pendingQuestion?.id === questionId) {
        pendingQuestion = null;
        // Mark question as timed out
        entry.answered = true;
        entry.timedOutAt = Date.now();
        broadcast({ ...entry, timedOut: true });
        resolve({ answer: null, timedOut: true });
      }
    }, timeout);

    pendingQuestion = { id: questionId, resolve, timer };
  });

  promise.then((result) => {
    if (result.timedOut) {
      res.json({
        answer:
          "No response received within 5 minutes. Proceed with your best judgment.",
        timedOut: true,
      });
    } else {
      res.json({ answer: result.answer, timedOut: false });
    }
  });
});

// POST /api/status - from MCP status (non-blocking)
app.post("/api/status", auth, (req, res) => {
  const { status } = req.body;
  currentStatus = status || "";
  const entry = store.add({ type: "status", status: currentStatus });
  broadcast(entry);
  io.emit("status", currentStatus);
  res.json({ ok: true });
});

// GET /api/inbox - from MCP inbox (drain queue)
app.get("/api/inbox", auth, (req, res) => {
  const messages = [...inbox];
  inbox = [];
  res.json({ messages });
});

// GET /api/wait-for-instruction - from Stop hook (long-poll)
app.get("/api/wait-for-instruction", auth, (req, res) => {
  const timeout = parseInt(req.query.timeout || "590000", 10);

  // If there are already queued messages, return immediately
  if (inbox.length > 0) {
    const instruction = inbox.shift();
    return res.json({ instruction, timedOut: false });
  }

  // Cancel any existing waiter
  if (instructionWaiter) {
    clearTimeout(instructionWaiter.timer);
    instructionWaiter.resolve({ instruction: null, timedOut: true });
  }

  const promise = new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (instructionWaiter?.resolve === resolve) {
        instructionWaiter = null;
        resolve({ instruction: null, timedOut: true });
      }
    }, timeout);

    instructionWaiter = { resolve, timer };
  });

  promise.then((result) => {
    res.json(result);
  });
});

// POST /api/respond - from browser (resolve pending question)
app.post("/api/respond", auth, (req, res) => {
  const { answer } = req.body;
  if (!pendingQuestion) {
    return res.status(404).json({ error: "No pending question" });
  }

  clearTimeout(pendingQuestion.timer);
  const qId = pendingQuestion.id;
  pendingQuestion.resolve({ answer, timedOut: false });
  pendingQuestion = null;

  // Store user's response
  const entry = store.add({
    type: "user",
    message: answer,
    inReplyTo: qId,
  });
  broadcast(entry);

  // Mark question as answered in store
  const original = store.messages.find((m) => m.id === qId);
  if (original) original.answered = true;

  res.json({ ok: true });
});

// POST /api/send - from browser (add to inbox or resolve waiter)
app.post("/api/send", auth, (req, res) => {
  const { message } = req.body;
  if (!message) return res.status(400).json({ error: "No message" });

  // Store user message
  const entry = store.add({ type: "user", message });
  broadcast(entry);

  // If there's a waiting stop hook, resolve it immediately
  if (instructionWaiter) {
    clearTimeout(instructionWaiter.timer);
    instructionWaiter.resolve({ instruction: message, timedOut: false });
    instructionWaiter = null;
  } else {
    // Queue it for MCP inbox
    inbox.push(message);
  }

  res.json({ ok: true, id: entry.id });
});

// GET /api/state - initial state for browser
app.get("/api/state", auth, (req, res) => {
  res.json({
    messages: store.all(),
    status: currentStatus,
    hasPendingQuestion: !!pendingQuestion,
    pendingQuestionId: pendingQuestion?.id || null,
  });
});

// --- Socket.IO ---

io.on("connection", (socket) => {
  console.log(`Client connected: ${socket.id}`);
  // Send current state
  socket.emit("init", {
    messages: store.all(),
    status: currentStatus,
    hasPendingQuestion: !!pendingQuestion,
    pendingQuestionId: pendingQuestion?.id || null,
  });

  socket.on("disconnect", () => {
    console.log(`Client disconnected: ${socket.id}`);
  });
});

// --- Start ---

httpServer.listen(PORT, () => {
  console.log(`Claude View server running on http://localhost:${PORT}`);
  console.log(`Auth token: ${TOKEN.slice(0, 8)}...`);
});
