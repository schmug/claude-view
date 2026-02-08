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

// --- Session class ---

class Session {
  constructor(id) {
    this.id = id;
    this.store = new MessageStore();
    this.inbox = [];
    this.instructionWaiter = null; // { resolve, timer }
    this.pendingQuestion = null;   // { id, resolve, timer }
    this.status = "";
    this.meta = {};                // { repoPath, repoName, branch }
    this.lastActivity = Date.now();
  }

  touch() {
    this.lastActivity = Date.now();
  }
}

// --- Session management ---

const sessions = new Map();
const SESSION_EXPIRY_MS = 2 * 60 * 60 * 1000; // 2 hours
const DEFAULT_SESSION = "_default";

function getSession(id) {
  const sessionId = id || DEFAULT_SESSION;
  let session = sessions.get(sessionId);
  if (!session) {
    session = new Session(sessionId);
    sessions.set(sessionId, session);
  }
  session.touch();
  return session;
}

function getSessionList() {
  return Array.from(sessions.values()).map((s) => ({
    id: s.id,
    meta: s.meta,
    status: s.status,
    hasPendingQuestion: !!s.pendingQuestion,
    lastActivity: s.lastActivity,
    messageCount: s.store.messages.length,
  }));
}

// Auto-expire inactive sessions every 10 minutes
setInterval(() => {
  const now = Date.now();
  for (const [id, session] of sessions) {
    if (now - session.lastActivity > SESSION_EXPIRY_MS) {
      // Clean up any pending waiters
      if (session.instructionWaiter) {
        clearTimeout(session.instructionWaiter.timer);
        session.instructionWaiter.resolve({ instruction: null, timedOut: true });
      }
      if (session.pendingQuestion) {
        clearTimeout(session.pendingQuestion.timer);
        session.pendingQuestion.resolve({ answer: null, timedOut: true });
      }
      sessions.delete(id);
      io.emit("sessions-changed", getSessionList());
      console.log(`Session expired: ${id}`);
    }
  }
}, 10 * 60 * 1000);

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

function broadcast(sessionId, entry) {
  io.emit("message", { ...entry, sessionId });
}

// --- API Endpoints ---

// GET /api/sessions - list active sessions
app.get("/api/sessions", auth, (req, res) => {
  res.json({ sessions: getSessionList() });
});

// POST /api/session/register - register/update session metadata
app.post("/api/session/register", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { repoPath, repoName, branch } = req.body;
  if (repoPath) session.meta.repoPath = repoPath;
  if (repoName) session.meta.repoName = repoName;
  if (branch) session.meta.branch = branch;
  io.emit("sessions-changed", getSessionList());
  res.json({ ok: true, sessionId: session.id });
});

// POST /api/activity - from PostToolUse hook (non-blocking)
app.post("/api/activity", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { tool, summary } = req.body;
  const entry = session.store.add({ type: "activity", tool, summary });
  broadcast(sessionId, entry);
  res.json({ ok: true, id: entry.id });
});

// POST /api/message - from MCP notify (non-blocking)
app.post("/api/message", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { message, level } = req.body;
  const entry = session.store.add({
    type: "notification",
    message,
    level: level || "info",
  });
  broadcast(sessionId, entry);
  res.json({ ok: true, id: entry.id });
});

// POST /api/ask - from MCP ask (long-polls until user responds)
app.post("/api/ask", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { question, options } = req.body;

  // Cancel any existing pending question for this session
  if (session.pendingQuestion) {
    clearTimeout(session.pendingQuestion.timer);
    session.pendingQuestion.resolve({ answer: null, timedOut: true });
  }

  const questionId = session.store.nextId;
  const entry = session.store.add({
    type: "question",
    question,
    options: options || [],
    answered: false,
  });
  broadcast(sessionId, entry);
  io.emit("sessions-changed", getSessionList());

  const timeout = 5 * 60 * 1000; // 5 minutes

  const promise = new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (session.pendingQuestion?.id === questionId) {
        session.pendingQuestion = null;
        entry.answered = true;
        entry.timedOutAt = Date.now();
        broadcast(sessionId, { ...entry, timedOut: true });
        io.emit("sessions-changed", getSessionList());
        resolve({ answer: null, timedOut: true });
      }
    }, timeout);

    session.pendingQuestion = { id: questionId, resolve, timer };
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
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { status } = req.body;
  session.status = status || "";
  const entry = session.store.add({ type: "status", status: session.status });
  broadcast(sessionId, entry);
  io.emit("session-status", { sessionId, status: session.status });
  res.json({ ok: true });
});

// GET /api/inbox - from MCP inbox (drain queue)
app.get("/api/inbox", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const messages = [...session.inbox];
  session.inbox = [];
  res.json({ messages });
});

// GET /api/wait-for-instruction - from Stop hook (long-poll)
app.get("/api/wait-for-instruction", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const timeout = parseInt(req.query.timeout || "590000", 10);

  // If there are already queued messages, return immediately
  if (session.inbox.length > 0) {
    const instruction = session.inbox.shift();
    return res.json({ instruction, timedOut: false });
  }

  // Cancel any existing waiter for this session
  if (session.instructionWaiter) {
    clearTimeout(session.instructionWaiter.timer);
    session.instructionWaiter.resolve({ instruction: null, timedOut: true });
  }

  const promise = new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (session.instructionWaiter?.resolve === resolve) {
        session.instructionWaiter = null;
        resolve({ instruction: null, timedOut: true });
      }
    }, timeout);

    session.instructionWaiter = { resolve, timer };
  });

  promise.then((result) => {
    res.json(result);
  });
});

// POST /api/respond - from browser (resolve pending question)
app.post("/api/respond", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { answer } = req.body;
  if (!session.pendingQuestion) {
    return res.status(404).json({ error: "No pending question" });
  }

  clearTimeout(session.pendingQuestion.timer);
  const qId = session.pendingQuestion.id;
  session.pendingQuestion.resolve({ answer, timedOut: false });
  session.pendingQuestion = null;

  // Store user's response
  const entry = session.store.add({
    type: "user",
    message: answer,
    inReplyTo: qId,
  });
  broadcast(sessionId, entry);
  io.emit("sessions-changed", getSessionList());

  // Mark question as answered in store
  const original = session.store.messages.find((m) => m.id === qId);
  if (original) original.answered = true;

  res.json({ ok: true });
});

// POST /api/send - from browser (add to inbox or resolve waiter)
app.post("/api/send", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  const { message } = req.body;
  if (!message) return res.status(400).json({ error: "No message" });

  // Store user message
  const entry = session.store.add({ type: "user", message });
  broadcast(sessionId, entry);

  // If there's a waiting stop hook, resolve it immediately
  if (session.instructionWaiter) {
    clearTimeout(session.instructionWaiter.timer);
    session.instructionWaiter.resolve({ instruction: message, timedOut: false });
    session.instructionWaiter = null;
  } else {
    // Queue it for MCP inbox
    session.inbox.push(message);
  }

  res.json({ ok: true, id: entry.id });
});

// GET /api/state - initial state for browser (per-session)
app.get("/api/state", auth, (req, res) => {
  const sessionId = req.query.session || DEFAULT_SESSION;
  const session = getSession(sessionId);
  res.json({
    messages: session.store.all(),
    status: session.status,
    hasPendingQuestion: !!session.pendingQuestion,
    pendingQuestionId: session.pendingQuestion?.id || null,
  });
});

// --- Socket.IO ---

io.on("connection", (socket) => {
  console.log(`Client connected: ${socket.id}`);
  // Send session list and default session state
  socket.emit("init", {
    sessions: getSessionList(),
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
