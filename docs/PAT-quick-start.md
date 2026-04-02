# PAT Production Deployment Guide

Deploy Personal Access Tokens to an existing Keycloak 26.x stand behind nginx.

## Prerequisites

- Keycloak 26.x running with an existing realm
- Nginx with `ngx_http_js_module` (njs) in front of Keycloak
- Maven 3.8+ and JDK 21 for building the provider
- `keycloak-config-cli` (optional, for automated realm config)

## Architecture

```
CLI / SDK                    Browser
  │                            │
  │ Authorization:             │ Cookie: __token
  │ Bearer pat_xxx             │
  │         ┌──────────────────┘
  ▼         ▼
┌─────────────────────┐
│     Nginx Gateway   │
│  ┌───────────────┐  │
│  │   pat.js      │  │  ← exchanges PAT → JWT, caches result
│  │   oidc.js     │  │  ← delegates PAT to pat.js, handles sessions
│  └───────┬───────┘  │
│          │ internal  │
└──────────┼──────────┘
           ▼
┌─────────────────────┐
│   Keycloak 26.x     │
│  ┌───────────────┐  │
│  │  pat-api SPI  │  │  ← CRUD + exchange endpoint
│  │  (pat-api.jar)│  │
│  └───────────────┘  │
└─────────────────────┘
```

## Step 1: Build the Provider JAR

Bump the Keycloak version to match your production instance:

```bash
cd keycloak/providers/pat-api
```

Edit `pom.xml`:
```xml
<keycloak.version>26.0.7</keycloak.version>  <!-- match your exact KC version -->
<maven.compiler.source>21</maven.compiler.source>
<maven.compiler.target>21</maven.compiler.target>
```

### Fix `createUserSession` for KC 26.x

In `PatResource.java`, the `exchangeToken()` method creates a user session. KC 26.x changed the method signature — the first `null` (session ID) parameter was removed:

```java
// KC 24 (current demo code):
session.sessions().createUserSession(
    null, realm, user, user.getUsername(),
    "127.0.0.1", "pat-exchange", false, null, null,
    UserSessionModel.SessionPersistenceState.PERSISTENT);

// KC 26 — remove the first null:
session.sessions().createUserSession(
    realm, user, user.getUsername(),
    "127.0.0.1", "pat-exchange", false, null, null,
    UserSessionModel.SessionPersistenceState.PERSISTENT);
```

If `SessionPersistenceState` no longer exists in your KC 26.x version (all sessions are persistent by default), use the overload without it:

```java
session.sessions().createUserSession(
    realm, user, user.getUsername(),
    "127.0.0.1", "pat-exchange", false, null, null);
```

Build:
```bash
mvn clean package -DskipTests
```

The output JAR is `target/pat-api.jar`.

## Step 2: Configure Keycloak Realm

### Option A: Using keycloak-config-cli (recommended)

Copy the migration file and run:
```bash
cp keycloak/migrations/config-cli/005_pat-production.yaml /path/to/your/config/

# Set environment variables
export REALM_NAME=your-realm
export PAT_CLIENT_ID=pat-exchange
export PAT_CLIENT_SECRET=$(openssl rand -hex 32)

# Run keycloak-config-cli
docker run --rm \
  -e KEYCLOAK_URL=http://keycloak:8080 \
  -e KEYCLOAK_USER=admin \
  -e KEYCLOAK_PASSWORD=<admin-password> \
  -e IMPORT_VARSUBSTITUTION_ENABLED=true \
  -e REALM_NAME=$REALM_NAME \
  -e PAT_CLIENT_ID=$PAT_CLIENT_ID \
  -e PAT_CLIENT_SECRET=$PAT_CLIENT_SECRET \
  -v /path/to/your/config:/config:ro \
  adorsys/keycloak-config-cli:6.5.0-26.0.0
```

### Option B: Manual setup via Admin Console

**1. User Profile Attributes**

Go to Realm Settings → User Profile and add these multivalued attributes:

| Attribute | View permission | Edit permission |
|-----------|----------------|-----------------|
| `pat_id` | admin, user | admin |
| `pat_name` | admin, user | admin |
| `pat_hash` | admin | admin |
| `pat_scopes` | admin, user | admin |
| `pat_created_at` | admin, user | admin |
| `pat_expires_at` | admin, user | admin |
| `pat_last_used_at` | admin, user | admin |

`pat_hash` must be **admin-only view** — this prevents users from reading token hashes via the Account API.

**2. PAT Client**

Create a new client:
- Client ID: `pat-exchange`
- Client authentication: ON (confidential)
- Standard flow: OFF
- Direct access grants: OFF
- Full scope allowed: ON
- Access token lifespan: 300 seconds (5 min)
- Under Advanced → token settings: set `access.token.lightweight` to `true`

Save the client secret — you'll need it for the SPI config.

## Step 3: Deploy the Provider

Copy the JAR and set the client ID:

```bash
# Copy JAR to Keycloak providers directory
cp pat-api.jar /opt/keycloak/providers/

# Set environment variables on Keycloak container:
KC_SPI_REALM_RESTAPI_EXTENSION_PAT_API_CLIENT_ID=pat-exchange
```

Restart Keycloak. Verify in startup logs:
```
Loaded SPI realm-restapi-extension ... provider pat-api
```

Test the endpoint is reachable (from inside the network):
```bash
curl http://keycloak:8080/realms/your-realm/pat-api/tokens
# Expected: 401 (no auth) — confirms the provider is loaded
```

## Step 4: Configure Nginx

### 4.1 Copy `pat.js` to your nginx njs directory

The file `gateway/njs/pat.js` is a standalone module. Copy it and substitute environment variables:

```bash
# If using envsubst (like the demo):
export PAT_EXCHANGE_URL="http://keycloak:8080/realms/your-realm/pat-api/tokens/exchange"
export PAT_CACHE_SEC=60
export OIDC_INTROSPECT_URL="http://keycloak:8080/realms/your-realm/protocol/openid-connect/token/introspect"
export CLIENT_ID=pat-exchange
export CLIENT_SECRET=<your-client-secret>
export INTROSPECTION_CACHE_SEC=30

envsubst '${PAT_EXCHANGE_URL} ${PAT_CACHE_SEC} ${OIDC_INTROSPECT_URL} ${CLIENT_ID} ${CLIENT_SECRET} ${INTROSPECTION_CACHE_SEC}' \
  < pat.js > /etc/nginx/njs/pat.js
```

Or hardcode the values directly in the file for simpler setups.

### 4.2 Add to nginx.conf (http block)

```nginx
# njs module
js_path /etc/nginx/njs/;
js_import pat from pat.js;

# Shared memory cache (if you don't already have one)
js_shared_dict_zone zone=cache:2m timeout=60s evict;

# Rate limiting for PAT endpoints
limit_req_zone $binary_remote_addr zone=pat_api:10m rate=10r/s;
```

### 4.3 Add location blocks (server block)

```nginx
# CRITICAL: Block direct access to the exchange endpoint.
# Only nginx (pat.js) should call it internally.
location = /realms/your-realm/pat-api/tokens/exchange {
    deny all;
    return 403 '{"error":"Direct access not allowed"}';
}

# PAT management API — requires an existing session (cookie-based auth)
location /api/pat/ {
    limit_req zone=pat_api burst=20 nodelay;
    limit_req_status 429;

    auth_request /_auth;
    auth_request_set $access_token $sent_http_x_access_token;

    proxy_pass http://keycloak/realms/your-realm/pat-api/;
    proxy_set_header Host $host;
    proxy_set_header Authorization "Bearer $access_token";
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# Backend API with PAT support — use pat.js as auth handler
# Option A: PAT-only auth (no session cookies)
location = /_pat_auth {
    internal;
    js_content pat.resolvePatAuth;
}

location /api/ {
    auth_request /_pat_auth;
    auth_request_set $access_token $sent_http_x_access_token;
    auth_request_set $token_claims $sent_http_x_token_claims;

    proxy_pass http://your-backend/;
    proxy_set_header Authorization "Bearer $access_token";
    proxy_set_header X-Token-Claims $token_claims;
}

# Option B: If you also have OIDC sessions (like the demo),
# import oidc.js too and use oidc.resolveToken which delegates to pat.js:
#   location = /_auth {
#       internal;
#       js_content oidc.resolveToken;
#   }
```

Reload nginx:
```bash
nginx -t && nginx -s reload
```

## Step 5: Verify

```bash
# 1. Get a session token (for PAT management)
TOKEN=$(curl -sk -X POST \
  "https://your-host/realms/your-realm/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=your-client&client_secret=secret&username=user&password=pass" \
  | jq -r .access_token)

# 2. Create a PAT
PAT=$(curl -sk -X POST "https://your-host/api/pat/tokens" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-first-pat","expiresInDays":30}' \
  | jq -r .token)

echo "PAT: $PAT"

# 3. Verify exchange endpoint is blocked externally
curl -sk -X POST "https://your-host/realms/your-realm/pat-api/tokens/exchange" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$PAT\"}"
# Expected: 403

# 4. Use PAT with Bearer auth
curl -sk "https://your-host/api/hello" \
  -H "Authorization: Bearer $PAT"
# Expected: 200

# 5. Use PAT with Basic auth (SDK compatibility)
curl -sk "https://your-host/api/hello" \
  -u "token:$PAT"
# Expected: 200

# 6. List PATs
curl -sk "https://your-host/api/pat/tokens" \
  -H "Authorization: Bearer $TOKEN" | jq

# 7. Delete PAT
PAT_ID=$(curl -sk "https://your-host/api/pat/tokens" \
  -H "Authorization: Bearer $TOKEN" | jq -r '.tokens[0].id')

curl -sk -X DELETE "https://your-host/api/pat/tokens/$PAT_ID" \
  -H "Authorization: Bearer $TOKEN"

# 8. Verify deleted PAT no longer works
curl -sk "https://your-host/api/hello" \
  -H "Authorization: Bearer $PAT"
# Expected: 401
```

## Rollback

Order matters — rollback nginx first, then Keycloak:

**1. Nginx** (immediate, zero-downtime):
```bash
# Remove PAT location blocks and pat.js import from nginx config
nginx -t && nginx -s reload
# PAT auth stops; cookie-based sessions continue working
```

**2. Keycloak provider**:
```bash
rm /opt/keycloak/providers/pat-api.jar
# Restart Keycloak
# PAT endpoints return 404
```

**3. Data** (optional): PAT user attributes (`pat_*`) are inert without the provider. They can stay or be cleaned up later via Admin API:
```bash
# For each user, clear PAT attributes:
curl -X PUT "http://keycloak:8080/admin/realms/your-realm/users/{userId}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"attributes":{"pat_id":[],"pat_name":[],"pat_hash":[],"pat_scopes":[],"pat_created_at":[],"pat_expires_at":[],"pat_last_used_at":[]}}'
```

## Configuration Reference

### Keycloak Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `KC_SPI_REALM_RESTAPI_EXTENSION_PAT_API_CLIENT_ID` | Client ID for token minting | `pat-exchange` |

### Nginx Environment Variables (for envsubst)

| Variable | Description | Default |
|----------|-------------|---------|
| `PAT_EXCHANGE_URL` | Internal KC exchange endpoint | (derived from KEYCLOAK_INTERNAL + REALM) |
| `PAT_CACHE_SEC` | Cache TTL for exchanged tokens | `60` |
| `OIDC_INTROSPECT_URL` | KC introspection endpoint | (derived from KEYCLOAK_INTERNAL + REALM) |
| `CLIENT_ID` | Client ID for introspection | `ui-bff` |
| `CLIENT_SECRET` | Client secret for introspection | — |
| `INTROSPECTION_CACHE_SEC` | Cache TTL for introspection | `30` |

### PAT API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/api/pat/tokens` | Session (cookie) | List user's PATs |
| `POST` | `/api/pat/tokens` | Session (cookie) | Create PAT |
| `DELETE` | `/api/pat/tokens/{id}` | Session (cookie) | Revoke PAT |
| `POST` | `/realms/{realm}/pat-api/tokens/exchange` | **Internal only** | Exchange PAT for JWT |

### Limits

- Max 10 PATs per user (configurable in `PatResource.java`)
- Expired PATs are cleaned up lazily on `listTokens()` calls
- Exchange endpoint rate-limited at nginx level (10 req/s per IP)
