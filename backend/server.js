import express from "express";
import jwt from "jsonwebtoken";
import jwksClient from "jwks-rsa";

const PORT = process.env.PORT || 3001;
const KEYCLOAK_URL = process.env.KEYCLOAK_URL || "http://keycloak:8080";
const KEYCLOAK_EXTERNAL_URL = process.env.KEYCLOAK_EXTERNAL_URL || "https://localhost";
const REALM = process.env.REALM || "public";

const app = express();

// JWKS client — fetches Keycloak's public keys to verify tokens
const client = jwksClient({
  jwksUri: `${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/certs`,
  cache: true,
  rateLimit: true,
});

function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) return callback(err);
    callback(null, key.getPublicKey());
  });
}

// Auth middleware — verifies Bearer token against Keycloak
function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid Authorization header" });
  }

  const token = authHeader.slice(7);

  jwt.verify(
    token,
    getKey,
    {
      issuer: [
        `${KEYCLOAK_URL}/realms/${REALM}`,
        `${KEYCLOAK_EXTERNAL_URL}/realms/${REALM}`,
      ],
      algorithms: ["RS256"],
    },
    (err, decoded) => {
      if (err) {
        return res.status(401).json({ error: "Invalid token", details: err.message });
      }
      req.user = decoded;
      next();
    }
  );
}

// Protected endpoint
app.get("/hello", requireAuth, (req, res) => {
  res.json({
    message: `Hello, ${req.user.preferred_username || req.user.sub}!`,
    sub: req.user.sub,
    email: req.user.email,
    issued_at: new Date(req.user.iat * 1000).toISOString(),
  });
});

app.listen(PORT, () => {
  console.log(`Backend listening on :${PORT}`);
});
