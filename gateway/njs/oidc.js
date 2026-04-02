// Phantom Token module for nginx njs
// Handles OIDC login/callback/logout and injects introspected claims for backends.
// Stateless — tokens are stored in the cookie, not in server memory.
// The lightweight access token is small (~500 bytes), so cookies stay within limits.

var crypto = require("crypto");

const KEYCLOAK_INTERNAL = "${KEYCLOAK_INTERNAL}";
const KEYCLOAK_EXTERNAL = "${KEYCLOAK_EXTERNAL}";
const REALM = "${REALM}";
const CLIENT_ID = "${CLIENT_ID}";
const CLIENT_SECRET = "${CLIENT_SECRET}";
const BASE_URL = "${BASE_URL}";
const TOKEN_COOKIE = "${TOKEN_COOKIE}";
const INTROSPECTION_CACHE_SEC = parseInt("${INTROSPECTION_CACHE_SEC}");
const PAT_CACHE_SEC = parseInt("${PAT_CACHE_SEC}");

const OIDC_BASE = `${KEYCLOAK_INTERNAL}/realms/${REALM}/protocol/openid-connect`;
const OIDC_EXTERNAL = `${KEYCLOAK_EXTERNAL}/realms/${REALM}/protocol/openid-connect`;
const PAT_EXCHANGE_URL = `${KEYCLOAK_INTERNAL}/realms/${REALM}/pat-api/tokens/exchange`;

// ---------------------------------------------------------------------------
// Cookie helpers
// ---------------------------------------------------------------------------

function parseCookies(cookieHeader) {
  var cookies = {};
  if (!cookieHeader) return cookies;
  cookieHeader.split(";").forEach(function (pair) {
    var parts = pair.trim().split("=");
    if (parts.length >= 2) {
      cookies[parts[0]] = parts.slice(1).join("=");
    }
  });
  return cookies;
}

function getTokens(r) {
  var cookies = parseCookies(r.headersIn["Cookie"]);
  var raw = cookies[TOKEN_COOKIE];
  if (!raw) return null;

  try {
    var decoded = Buffer.from(decodeURIComponent(raw), "base64").toString();
    return JSON.parse(decoded);
  } catch (e) {
    return null;
  }
}

function setTokenCookie(r, tokens) {
  // Store lightweight access token + refresh token in a base64-encoded cookie.
  // The access token is already signed by Keycloak — no need for additional HMAC.
  // Only store access + refresh tokens. ID token is large and only used for
  // logout id_token_hint — skip it to keep cookie under the 4KB browser limit.
  var payload = JSON.stringify({
    a: tokens.access_token,
    r: tokens.refresh_token,
    e: Date.now() + tokens.expires_in * 1000,
  });
  var encoded = Buffer.from(payload).toString("base64");
  var cookie =
    TOKEN_COOKIE +
    "=" +
    encodeURIComponent(encoded) +
    "; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=1800";
  r.headersOut["Set-Cookie"] = cookie;
}

function clearTokenCookie(r) {
  r.headersOut["Set-Cookie"] =
    TOKEN_COOKIE + "=; Path=/; HttpOnly; Secure; Max-Age=0";
}

// ---------------------------------------------------------------------------
// Token introspection with cache
// ---------------------------------------------------------------------------

function tokenCacheKey(token) {
  var h = crypto.createHash("sha256");
  h.update(token);
  return "_ic_" + h.digest("hex").substring(0, 16);
}

async function introspect(token) {
  // Check cache
  var cacheKey = tokenCacheKey(token);
  var cached = ngx.shared.cache.get(cacheKey);
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

  var resp = await ngx.fetch(OIDC_BASE + "/token/introspect", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body,
  });

  if (resp.status !== 200) return null;

  var data = await resp.json();
  if (!data.active) return null;

  // Cache — expire at token expiry or TTL, whichever is sooner
  var ttl = INTROSPECTION_CACHE_SEC;
  if (data.exp) {
    var tokenTtl = data.exp - Math.floor(Date.now() / 1000);
    if (tokenTtl > 0 && tokenTtl < ttl) ttl = tokenTtl;
  }
  ngx.shared.cache.set(cacheKey, JSON.stringify(data), ttl);

  return data;
}

// ---------------------------------------------------------------------------
// PAT exchange — convert personal access token to real Keycloak token
// ---------------------------------------------------------------------------

async function exchangePat(patToken) {
  // Check cache: PAT hash → access token
  var cacheKey = "_pat_" + tokenCacheKey(patToken);
  var cached = ngx.shared.cache.get(cacheKey);
  if (cached) {
    return cached;
  }

  var resp = await ngx.fetch(PAT_EXCHANGE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token: patToken }),
  });

  if (resp.status !== 200) {
    var errText = await resp.text();
    ngx.log(ngx.ERR, "PAT exchange HTTP " + resp.status + ": " + errText);
    return null;
  }

  var data = await resp.json();
  if (!data.access_token) return null;

  // Cache the access token
  var ttl = Math.min(data.expires_in || 300, PAT_CACHE_SEC);
  ngx.shared.cache.set(cacheKey, data.access_token, ttl);

  return data.access_token;
}

// ---------------------------------------------------------------------------
// Token refresh
// ---------------------------------------------------------------------------

async function refreshTokens(refreshToken) {
  var body = [
    "grant_type=refresh_token",
    "client_id=" + CLIENT_ID,
    "client_secret=" + CLIENT_SECRET,
    "refresh_token=" + refreshToken,
  ].join("&");

  var resp = await ngx.fetch(OIDC_BASE + "/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body,
  });

  if (resp.status !== 200) return null;
  return resp.json();
}

// ---------------------------------------------------------------------------
// Shared: filter introspection claims for backend headers
// ---------------------------------------------------------------------------

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
// OIDC Handlers
// ---------------------------------------------------------------------------

function login(r) {
  var redirectUri = BASE_URL + "/auth/callback";
  var params = [
    "client_id=" + CLIENT_ID,
    "response_type=code",
    "scope=openid%20profile%20email",
    "redirect_uri=" + encodeURIComponent(redirectUri),
  ].join("&");

  r.return(302, OIDC_EXTERNAL + "/auth?" + params);
}

async function callback(r) {
  var code = r.args.code;
  if (!code) {
    r.return(400, '{"error":"Missing authorization code"}');
    return;
  }

  var redirectUri = BASE_URL + "/auth/callback";
  var body = [
    "grant_type=authorization_code",
    "client_id=" + CLIENT_ID,
    "client_secret=" + CLIENT_SECRET,
    "code=" + encodeURIComponent(code),
    "redirect_uri=" + encodeURIComponent(redirectUri),
  ].join("&");

  try {
    var resp = await ngx.fetch(OIDC_BASE + "/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
    });

    if (resp.status !== 200) {
      var errBody = await resp.text();
      r.error("Token exchange failed: " + resp.status + " " + errBody);
      r.return(502, '{"error":"Token exchange failed"}');
      return;
    }

    var tokens = await resp.json();
    setTokenCookie(r, tokens);
    r.return(302, BASE_URL + "/ui/");
  } catch (e) {
    r.error("Callback error: " + e.message);
    r.return(500, '{"error":"Authentication failed"}');
  }
}

function logout(r) {
  var tokens = getTokens(r);
  clearTokenCookie(r);

  var params = [
    "client_id=" + CLIENT_ID,
    "post_logout_redirect_uri=" + encodeURIComponent(BASE_URL + "/ui/"),
  ];

  if (tokens && tokens.i) {
    params.push("id_token_hint=" + encodeURIComponent(tokens.i));
  }

  r.return(302, OIDC_EXTERNAL + "/logout?" + params.join("&"));
}

// ---------------------------------------------------------------------------
// Auth check — called via auth_request for /api/* routes
// Supports both cookie-based sessions and PAT-based auth
// ---------------------------------------------------------------------------

async function resolveToken(r) {
  // Check for PAT in Authorization header
  var authHeader = r.headersIn["Authorization"];
  if (authHeader && authHeader.startsWith("Bearer pat_")) {
    var patToken = authHeader.substring(7); // strip "Bearer "
    try {
      var accessToken = await exchangePat(patToken);
      if (!accessToken) {
        r.return(401);
        return;
      }

      var claims = await introspect(accessToken);
      if (!claims) {
        r.return(401);
        return;
      }

      r.headersOut["X-Access-Token"] = accessToken;
      r.headersOut["X-Token-Claims"] = JSON.stringify(filterClaims(claims));
      r.return(200);
      return;
    } catch (e) {
      r.error("PAT exchange failed: " + e.message);
      r.return(401);
      return;
    }
  }

  // Check for PAT in Basic auth (e.g. Langfuse SDK: Basic base64(token:pat_xxx))
  if (authHeader && authHeader.startsWith("Basic ")) {
    try {
      var decoded = Buffer.from(authHeader.substring(6), "base64").toString();
      var sep = decoded.indexOf(":");
      if (sep > 0) {
        var publicKey = decoded.substring(0, sep);
        var secretKey = decoded.substring(sep + 1);
        if (publicKey === "token" && secretKey.startsWith("pat_")) {
          var accessToken = await exchangePat(secretKey);
          if (!accessToken) {
            r.return(401);
            return;
          }
          var claims = await introspect(accessToken);
          if (!claims) {
            r.return(401);
            return;
          }
          r.headersOut["X-Access-Token"] = accessToken;
          r.headersOut["X-Token-Claims"] = JSON.stringify(filterClaims(claims));
          r.return(200);
          return;
        }
      }
    } catch (e) {
      r.error("Basic auth PAT exchange failed: " + e.message);
      r.return(401);
      return;
    }
  }

  // Cookie-based session flow
  var tokens = getTokens(r);
  if (!tokens) {
    r.return(401);
    return;
  }

  var accessToken = tokens.a;

  // Refresh if expired
  if (Date.now() > tokens.e) {
    try {
      var newTokens = await refreshTokens(tokens.r);
      if (!newTokens) {
        r.return(401);
        return;
      }
      accessToken = newTokens.access_token;
      setTokenCookie(r, newTokens);
    } catch (e) {
      r.error("Token refresh failed: " + e.message);
      r.return(401);
      return;
    }
  }

  // Introspect and filter claims
  try {
    var claims = await introspect(accessToken);
    if (!claims) {
      r.return(401);
      return;
    }

    r.headersOut["X-Access-Token"] = accessToken;
    r.headersOut["X-Token-Claims"] = JSON.stringify(filterClaims(claims));
    r.return(200);
  } catch (e) {
    r.error("Introspection failed: " + e.message);
    r.return(401);
  }
}

// ---------------------------------------------------------------------------
// Session info endpoint for the UI
// ---------------------------------------------------------------------------

async function me(r) {
  var tokens = getTokens(r);
  if (!tokens) {
    r.return(401, '{"error":"Not authenticated"}');
    return;
  }

  try {
    var claims = await introspect(tokens.a);
    if (!claims) {
      r.return(401, '{"error":"Token no longer valid"}');
      return;
    }

    r.headersOut["Content-Type"] = "application/json";
    r.return(
      200,
      JSON.stringify({
        sub: claims.sub,
        preferred_username: claims.preferred_username,
        email: claims.email,
        email_verified: claims.email_verified,
        given_name: claims.given_name,
        family_name: claims.family_name,
        iss: claims.iss,
        exp: claims.exp,
      })
    );
  } catch (e) {
    r.error("Introspection failed: " + e.message);
    r.return(500, '{"error":"Failed to resolve token"}');
  }
}

export default { login, callback, logout, resolveToken, me };
