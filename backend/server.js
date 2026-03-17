import express from "express";

const PORT = process.env.PORT || 3001;
const KEYCLOAK_URL = process.env.KEYCLOAK_URL || "http://keycloak:8080";
const REALM = process.env.REALM || "public";

const app = express();
app.use(express.json());

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
    });
    res.status(kcRes.status).json(await kcRes.json());
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
    });
    if (kcRes.status === 204) return res.status(204).end();
    res.status(kcRes.status).json(await kcRes.json());
  } catch (e) {
    res.status(502).json({ error: "Failed to reach Keycloak", details: e.message });
  }
});

app.listen(PORT, () => {
  console.log(`Backend listening on :${PORT}`);
});
