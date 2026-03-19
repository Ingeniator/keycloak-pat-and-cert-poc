# Phantom Token Architecture

## Overview

The project uses the phantom token pattern to keep JWT tokens invisible to the frontend. Authentication is handled entirely at the nginx layer using the njs module, and backends receive pre-introspected claims — no JWT libraries or OIDC code required.

Nginx is fully stateless — tokens are stored in the browser cookie (not server memory), so multiple nginx pods work without sticky sessions or shared storage.

## Components

```
Browser (cookie only, no JWT visible)
  │
  ├── /auth/login      → njs: redirect to Keycloak
  ├── /auth/callback   → njs: exchange code → store tokens in cookie → redirect to UI
  ├── /auth/me         → njs: read cookie → introspect → return user claims as JSON
  ├── /auth/logout     → njs: clear cookie → redirect to Keycloak logout
  │
  ├── /api/*           → nginx auth_request → njs reads cookie → introspects
  │                      → injects Authorization + X-Token-Claims headers
  │                      → proxy to backend
  │
  └── /ui/*            → static React SPA
```

### nginx + njs (`gateway/njs/oidc.js`)

Handles the full OIDC lifecycle:

- **Login**: Redirects browser to Keycloak's authorization endpoint
- **Callback**: Exchanges authorization code for tokens using the confidential `ui-bff` client, stores tokens in a base64-encoded HttpOnly cookie
- **Token resolution**: On `/api/*` requests, reads tokens from the cookie, refreshes if expired, introspects the lightweight token via Keycloak, and injects two headers for the backend:
  - `Authorization: Bearer <lightweight-jwt>` — for Keycloak API calls on behalf of the user
  - `X-Token-Claims: <json>` — filtered introspected claims (sub, email, roles, etc.)
- **Introspection cache**: Results are cached in shared memory (`js_shared_dict_zone cache:2m`) for 30 seconds (or until token expiry) to avoid hitting Keycloak on every request
- **Claim filtering**: Only selected claims are passed to backends, keeping the `X-Token-Claims` header compact regardless of how many roles/clients exist in Keycloak

### Cookie format

Tokens are stored in a single `__token` cookie as base64-encoded JSON:

```json
{"a": "<access_token>", "r": "<refresh_token>", "i": "<id_token>", "e": <expires_at_ms>}
```

- With lightweight access tokens, the cookie is ~1KB total (well within the 4KB cookie limit)
- The tokens are signed by Keycloak — no additional HMAC signing needed
- Cookie flags: `HttpOnly; Secure; SameSite=Lax; Max-Age=1800`

### Keycloak client (`ui-bff`)

- Confidential client (server-side secret, not exposed to browser)
- Lightweight access tokens enabled (`access.token.lightweight: "true"`) — the JWT issued by Keycloak contains only `sub`, `iss`, `exp`, `aud` (~500 bytes instead of 3-5KB)
- Full claims are available only via the introspection endpoint

### Backend (`backend/`)

A plain Express server with no JWT libraries:

- Reads user info from the `X-Token-Claims` header (pre-parsed JSON)
- Uses the `Authorization` header to proxy requests to Keycloak APIs (e.g., Account API)
- Rejects direct access (requests that bypass nginx)

### UI (`ui/`)

A React SPA with no OIDC client libraries:

- Login/logout via plain `<a href="/auth/login">` links
- Session check via `fetch("/auth/me")` with `credentials: "include"`
- API calls via `fetch("/api/...")` with `credentials: "include"`
- Never handles, stores, or sees any token

## Adding a new backend

1. Add the service to `docker-compose.yml`
2. Add an upstream in `gateway/nginx.conf`:
   ```nginx
   upstream my-service {
       server my-service:3000;
   }
   ```
3. Add a location block in `gateway/conf.d/keycloak.conf`:
   ```nginx
   location /my-service/ {
       auth_request /_auth;
       auth_request_set $access_token $upstream_http_x_access_token;
       auth_request_set $token_claims $upstream_http_x_token_claims;

       proxy_pass http://my-service/;
       proxy_set_header Authorization "Bearer $access_token";
       proxy_set_header X-Token-Claims $token_claims;
       error_page 401 = @unauthorized;
   }
   ```

The new backend reads `X-Token-Claims` — no OIDC integration needed.

## Lightweight access tokens

Keycloak's lightweight access token feature (24+) reduces the JWT size by stripping all claims except the essentials.

| | Standard JWT | Lightweight JWT |
|---|---|---|
| **Size** | 3-5 KB (roles, groups, claims) | ~500 bytes |
| **Contains** | Everything | `sub`, `iss`, `exp`, `aud`, `azp` |
| **Full claims** | Decode the JWT | Call introspection endpoint |
| **Use case** | Direct backend validation | Gateway-mediated architecture |

The `X-Token-Claims` header is kept small by filtering at the nginx layer — only selected claims (sub, email, roles, scope) are passed to backends, not the full introspection response.

## Scaling

Nginx is stateless — no server-side session store. Tokens live in the browser cookie, so any nginx pod can handle any request.

The only shared memory is the introspection cache (`js_shared_dict_zone cache:2m`), which is per-pod and optional — a cache miss just means an extra introspection call to Keycloak. No data is lost if a pod restarts.

## Security properties

- **Frontend never sees JWT** — only an HttpOnly cookie containing base64-encoded tokens
- **Tokens are Keycloak-signed** — cannot be forged without Keycloak's private key
- **CSRF protection** — `SameSite=Lax` prevents cross-site request attachment
- **XSS protection** — `HttpOnly` prevents JavaScript access to the cookie
- **Introspection validates liveness** — revoked tokens are caught within the cache TTL (30s default)
- **Lightweight token limits exposure** — even if the cookie is somehow read, the token contains no meaningful claims
