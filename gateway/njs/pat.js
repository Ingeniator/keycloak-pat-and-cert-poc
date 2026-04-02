// PAT (Personal Access Token) module for nginx njs
// Handles PAT-based authentication: exchanges PAT tokens for Keycloak JWTs,
// supports Bearer and Basic auth schemes.
//
// Standalone module — can be used independently of the OIDC session flow.
// Requires: ngx.shared.cache zone and token introspection function.
//
// Usage in nginx.conf:
//   js_import pat from pat.js;
//   In your auth handler, call: pat.resolvePatAuth(r)
//
// Environment variables (substituted by envsubst at container startup):
//   PAT_EXCHANGE_URL     — internal Keycloak PAT exchange endpoint
//   PAT_CACHE_SEC        — cache TTL for exchanged tokens (default: 60)
//   OIDC_INTROSPECT_URL  — Keycloak token introspection endpoint
//   CLIENT_ID            — OIDC client ID (for introspection)
//   CLIENT_SECRET        — OIDC client secret (for introspection)
//   INTROSPECTION_CACHE_SEC — cache TTL for introspection results (default: 30)

var crypto = require("crypto");

// ---------------------------------------------------------------------------
// Configuration (envsubst placeholders — replaced at container startup)
// ---------------------------------------------------------------------------

const PAT_EXCHANGE_URL = "${PAT_EXCHANGE_URL}";
const PAT_CACHE_SEC = parseInt("${PAT_CACHE_SEC}") || 60;
const OIDC_INTROSPECT_URL = "${OIDC_INTROSPECT_URL}";
const CLIENT_ID = "${CLIENT_ID}";
const CLIENT_SECRET = "${CLIENT_SECRET}";
const INTROSPECTION_CACHE_SEC = parseInt("${INTROSPECTION_CACHE_SEC}") || 30;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function cacheKey(prefix, token) {
  var h = crypto.createHash("sha256");
  h.update(token);
  return prefix + h.digest("hex").substring(0, 16);
}

function filterClaims(claims) {
  return {
    sub: claims.sub,
    preferred_username: claims.preferred_username,
    email: claims.email,
    email_verified: claims.email_verified,
    given_name: claims.given_name,
    family_name: claims.family_name,
    realm_access: claims.realm_access,
    scope: claims.scope,
    iss: claims.iss,
    exp: claims.exp,
    iat: claims.iat,
  };
}

// ---------------------------------------------------------------------------
// Token introspection with cache
// ---------------------------------------------------------------------------

async function introspect(token) {
  var key = cacheKey("_ic_", token);
  var cached = ngx.shared.cache.get(key);
  if (cached) {
    try {
      return JSON.parse(cached);
    } catch (e) {
      // fall through
    }
  }

  var body = [
    "token=" + encodeURIComponent(token),
    "client_id=" + CLIENT_ID,
    "client_secret=" + CLIENT_SECRET,
  ].join("&");

  var resp = await ngx.fetch(OIDC_INTROSPECT_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body,
  });

  if (resp.status !== 200) return null;

  var data = await resp.json();
  if (!data.active) return null;

  var ttl = INTROSPECTION_CACHE_SEC;
  if (data.exp) {
    var tokenTtl = data.exp - Math.floor(Date.now() / 1000);
    if (tokenTtl > 0 && tokenTtl < ttl) ttl = tokenTtl;
  }
  ngx.shared.cache.set(key, JSON.stringify(data), ttl);

  return data;
}

// ---------------------------------------------------------------------------
// PAT exchange — convert personal access token to real Keycloak JWT
// ---------------------------------------------------------------------------

async function exchangePat(patToken) {
  var key = cacheKey("_pat_", patToken);
  var cached = ngx.shared.cache.get(key);
  if (cached) {
    return cached;
  }

  var resp = await ngx.fetch(PAT_EXCHANGE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token: patToken }),
  });

  if (resp.status !== 200) {
    ngx.log(ngx.ERR, "PAT exchange failed with HTTP " + resp.status);
    return null;
  }

  var data = await resp.json();
  if (!data.access_token) return null;

  var ttl = Math.min(data.expires_in || 300, PAT_CACHE_SEC);
  ngx.shared.cache.set(key, data.access_token, ttl);

  return data.access_token;
}

// ---------------------------------------------------------------------------
// Resolve PAT from request — extracts PAT from Bearer or Basic auth header,
// exchanges it for a JWT, introspects, and sets response headers.
//
// Returns true if PAT was found and resolved, false if no PAT in request.
// On auth failure (invalid PAT), sends 401 and returns true.
// ---------------------------------------------------------------------------

async function resolvePatFromRequest(r) {
  var authHeader = r.headersIn["Authorization"];
  if (!authHeader) return false;

  var patToken = null;

  // Bearer pat_xxx
  if (authHeader.startsWith("Bearer pat_")) {
    patToken = authHeader.substring(7);
  }

  // Basic base64(token:pat_xxx) — SDK compatibility (e.g. Langfuse)
  if (!patToken && authHeader.startsWith("Basic ")) {
    try {
      var decoded = Buffer.from(authHeader.substring(6), "base64").toString();
      var sep = decoded.indexOf(":");
      if (sep > 0) {
        var publicKey = decoded.substring(0, sep);
        var secretKey = decoded.substring(sep + 1);
        if (publicKey === "token" && secretKey.startsWith("pat_")) {
          patToken = secretKey;
        }
      }
    } catch (e) {
      // not a valid Basic auth PAT
    }
  }

  if (!patToken) return false;

  // Exchange PAT for access token
  try {
    var accessToken = await exchangePat(patToken);
    if (!accessToken) {
      r.return(401, '{"error":"Invalid or expired PAT"}');
      return true;
    }

    var claims = await introspect(accessToken);
    if (!claims) {
      r.return(401, '{"error":"Token introspection failed"}');
      return true;
    }

    r.headersOut["X-Access-Token"] = accessToken;
    r.headersOut["X-Token-Claims"] = JSON.stringify(filterClaims(claims));
    r.return(200);
    return true;
  } catch (e) {
    r.error("PAT auth failed: " + e.message);
    r.return(401, '{"error":"PAT authentication failed"}');
    return true;
  }
}

// ---------------------------------------------------------------------------
// Standalone auth handler — use as js_content for /_pat_auth location
// Only handles PAT auth. Returns 401 if no PAT found.
// ---------------------------------------------------------------------------

async function resolvePatAuth(r) {
  var handled = await resolvePatFromRequest(r);
  if (!handled) {
    r.return(401, '{"error":"PAT required"}');
  }
}

export default { resolvePatAuth, resolvePatFromRequest, exchangePat, introspect, filterClaims };
