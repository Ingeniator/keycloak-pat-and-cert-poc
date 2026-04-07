import express from "express";
import { requirePermission, batchCheckPermissions } from "./authz.js";

const PORT = process.env.PORT || 3001;
const KEYCLOAK_URL = process.env.KEYCLOAK_URL || "http://keycloak:8080";
const REALM = process.env.REALM || "public";

const app = express();
app.use(express.json({ limit: "1mb" }));

// Auth middleware — reads full claims injected by nginx (from introspection)
// Falls back to Authorization header for direct access
function requireAuth(req, res, next) {
  const claimsHeader = req.headers["x-token-claims"];
  if (claimsHeader) {
    try {
      req.user = JSON.parse(claimsHeader);
      return next();
    } catch (e) {
      return res.status(400).json({ error: "Invalid X-Token-Claims header" });
    }
  }

  return res.status(401).json({ error: "Not authenticated — request must go through the gateway" });
}

// Protected endpoint
app.get("/hello", requireAuth, (req, res) => {
  res.json({
    message: `Hello, ${req.user.preferred_username || req.user.sub}!`,
    sub: req.user.sub,
    email: req.user.email,
    roles: req.user.realm_access?.roles,
    issued_at: new Date(req.user.iat * 1000).toISOString(),
  });
});

// Proxy Keycloak Account API
app.get("/account", requireAuth, async (req, res) => {
  try {
    const kcRes = await fetch(`${KEYCLOAK_URL}/realms/${REALM}/account`, {
      headers: {
        Authorization: req.headers.authorization,
        Accept: "application/json",
      },
      signal: AbortSignal.timeout(10000),
    });
    if (!kcRes.ok) {
      return res.status(kcRes.status).json({ error: `Keycloak returned ${kcRes.status}` });
    }
    res.json(await kcRes.json());
  } catch (e) {
    res.status(502).json({ error: "Failed to reach Keycloak", details: e.message });
  }
});

app.post("/account", requireAuth, async (req, res) => {
  try {
    const kcRes = await fetch(`${KEYCLOAK_URL}/realms/${REALM}/account`, {
      method: "POST",
      headers: {
        Authorization: req.headers.authorization,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(req.body),
      signal: AbortSignal.timeout(10000),
    });
    if (kcRes.status === 204) return res.status(204).end();
    if (!kcRes.ok) {
      return res.status(kcRes.status).json({ error: `Keycloak returned ${kcRes.status}` });
    }
    res.json(await kcRes.json());
  } catch (e) {
    res.status(502).json({ error: "Failed to reach Keycloak", details: e.message });
  }
});

// Workspace routes (OpenFGA authz)
app.get("/workspaces/:workspaceId", requireAuth, requirePermission("workspace", "workspaceId", "viewer"), (req, res) => {
  res.json({ workspace: req.params.workspaceId });
});

app.post("/workspaces/:workspaceId/settings", requireAuth, requirePermission("workspace", "workspaceId", "admin"), (req, res) => {
  res.json({ workspace: req.params.workspaceId, settings: req.body });
});

// Document routes (OpenFGA authz)
app.get("/workspaces/:workspaceId/documents/:documentId", requireAuth, requirePermission("document", "documentId", "viewer"), (req, res) => {
  res.json({ workspace: req.params.workspaceId, document: req.params.documentId });
});

app.put("/workspaces/:workspaceId/documents/:documentId", requireAuth, requirePermission("document", "documentId", "editor"), (req, res) => {
  res.json({ workspace: req.params.workspaceId, document: req.params.documentId, updated: true });
});

// Batch permission check — single HTTP call to OpenFGA for multiple tuples
app.post("/check-permissions", requireAuth, async (req, res) => {
  const userId = req.user?.preferred_username || req.user?.sub;
  if (!userId) return res.status(401).json({ error: "Not authenticated" });

  const { checks } = req.body;
  if (!Array.isArray(checks) || checks.length === 0) {
    return res.status(400).json({ error: "checks array required" });
  }

  try {
    const results = await Promise.race([
      batchCheckPermissions(userId, checks),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error("Batch check timed out")), 5000)
      ),
    ]);
    res.json({ results: checks.map((c, i) => ({ ...c, allowed: results[i] })) });
  } catch (err) {
    console.error("Batch OpenFGA check failed:", err.message);
    res.status(500).json({ error: "Authorization check failed" });
  }
});

// OpenAI-compatible chat completions (hardcoded response)
app.post("/v1/chat/completions", requireAuth, (req, res) => {
  const model = req.body?.model || "mock-gpt";
  const now = Math.floor(Date.now() / 1000);
  const id = `chatcmpl-${now}-${Math.random().toString(36).slice(2, 10)}`;
  const lastMsg = req.body?.messages?.at(-1)?.content || "";
  const content = `Hello! You said: "${lastMsg}". This is a mock response from the OpenAI-compatible endpoint.`;

  const promptTokens = JSON.stringify(req.body?.messages || []).length;
  const completionTokens = content.length;

  // SSE streaming response
  if (req.body?.stream) {
    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");

    const chunk = {
      id,
      object: "chat.completion.chunk",
      created: now,
      model,
      choices: [{ index: 0, delta: { role: "assistant", content }, finish_reason: null }],
    };
    res.write(`data: ${JSON.stringify(chunk)}\n\n`);

    const done = {
      id,
      object: "chat.completion.chunk",
      created: now,
      model,
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: promptTokens, completion_tokens: completionTokens, total_tokens: promptTokens + completionTokens },
    };
    res.write(`data: ${JSON.stringify(done)}\n\n`);
    res.write("data: [DONE]\n\n");
    res.end();
    return;
  }

  res.json({
    id,
    object: "chat.completion",
    created: now,
    model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: {
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      total_tokens: promptTokens + completionTokens,
    },
  });
});

app.get("/v1/models", requireAuth, (req, res) => {
  res.json({
    object: "list",
    data: [
      {
        id: "mock-gpt",
        object: "model",
        created: 1700000000,
        owned_by: "demo",
      },
    ],
  });
});

app.listen(PORT, () => {
  console.log(`Backend listening on :${PORT}`);
});
