# Personal Access Tokens (PATs)

GitHub-like personal access tokens for script and CI/CD authentication — no OAuth dance required.

## Overview

Personal Access Tokens are opaque, long-lived credentials tied to a user account. They provide a simple `Authorization: Bearer pat_...` header for non-interactive API access, replacing the need for OAuth2 flows in scripts, CLI tools, and CI/CD pipelines.

```
Script                          Nginx                           Keycloak
  |                               |                               |
  |  Authorization: Bearer pat_…  |                               |
  |------------------------------>|                               |
  |                               |  POST /pat-api/tokens/exchange|
  |                               |------------------------------>|
  |                               |  { access_token: "eyJ..." }  |
  |                               |<------------------------------|
  |                               |                               |
  |                               |  POST /token/introspect       |
  |                               |------------------------------>|
  |                               |  { active: true, sub: ... }   |
  |                               |<------------------------------|
  |                               |                               |
  |  X-Token-Claims: {...}        |                               |
  |  (proxied to backend)         |                               |
  |<------------------------------|                               |
```

The PAT is exchanged for a real Keycloak access token at the nginx layer. From that point, the existing phantom token pattern takes over. **The backend requires no changes** — it still reads `X-Token-Claims` headers as before.

## Quick Start

### 1. Create a token (UI)

1. Sign in at `https://localhost/ui/`
2. Find the **Personal Access Tokens** section
3. Enter a name, pick an expiration, click **Generate token**
4. Copy the `pat_...` token immediately — it's shown only once

### 2. Create a token (API)

```bash
# Get a session token first (one-time)
TOKEN=$(curl -sk -X POST 'https://localhost/realms/public/protocol/openid-connect/token' \
  -d 'grant_type=password&client_id=ui-bff&client_secret=bff-secret&username=testuser&password=testuser123' \
  | jq -r .access_token)

# Create a PAT
curl -sk -X POST 'https://localhost/realms/public/pat-api/tokens' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name": "CI Pipeline", "expiresInDays": 90}'
```

Response:
```json
{
  "token": "pat_7kQm9xR2...",
  "id": "a1b2c3d4e5f67890",
  "name": "CI Pipeline",
  "scopes": "openid profile email",
  "created_at": "2026-03-17T10:00:00Z",
  "expires_at": "2026-06-15T10:00:00Z"
}
```

### 3. Use the token

```bash
# That's it — one header, one call
curl -sk -H "Authorization: Bearer pat_7kQm9xR2..." https://localhost/api/hello
```

No token endpoint. No client credentials. No refresh flow. No callback URL.

## API Reference

All endpoints are at `/realms/{realm}/pat-api/` and require a valid Bearer token (session-based).

### List tokens

```
GET /realms/public/pat-api/tokens
Authorization: Bearer <session-token>
```

Returns all PATs for the authenticated user. Never returns the raw token or hash.

```json
{
  "tokens": [
    {
      "id": "a1b2c3d4e5f67890",
      "name": "CI Pipeline",
      "scopes": "openid profile email",
      "created_at": "2026-03-17T10:00:00Z",
      "expires_at": "2026-06-15T10:00:00Z",
      "last_used_at": "2026-03-17T14:30:00Z"
    }
  ],
  "count": 1
}
```

### Create token

```
POST /realms/public/pat-api/tokens
Authorization: Bearer <session-token>
Content-Type: application/json

{
  "name": "CI Pipeline",        // required
  "scopes": "openid profile",   // optional, defaults to "openid profile email"
  "expiresInDays": 90           // optional, null = never expires
}
```

Returns the raw token **once**. Store it securely.

### Delete token

```
DELETE /realms/public/pat-api/tokens/{id}
Authorization: Bearer <session-token>
```

Immediately revokes the token. Any in-flight cached exchanges will expire within 60 seconds.

## Architecture

### Token Format

```
pat_<base62-encoded-32-random-bytes>
```

Example: `pat_7kQm9xR2vBnL3pYdFwXcA8mEjH5sT1gN6qKoUiZ4`

- `pat_` prefix — allows nginx to detect PATs vs regular JWTs
- 32 bytes of `SecureRandom` — 256 bits of entropy
- Base62 encoding — URL-safe, no special characters

### Storage

PATs are stored as **SHA-256 hashes** in Keycloak user attributes (parallel multi-valued lists):

| Attribute | Description |
|---|---|
| `pat_id` | First 16 hex chars of the hash (for identification) |
| `pat_name` | User-friendly name |
| `pat_hash` | Full SHA-256 hex hash of the raw token |
| `pat_scopes` | Space-separated scope list |
| `pat_created_at` | ISO-8601 creation timestamp |
| `pat_expires_at` | ISO-8601 expiry or `"never"` |
| `pat_last_used_at` | ISO-8601 last use or `"never"` |

Raw tokens are **never stored**. If the hash store is compromised, tokens cannot be recovered.

### Exchange Flow

Nginx recognizes PATs in two header formats:

- **Bearer**: `Authorization: Bearer pat_xxx` — standard for OpenAI-compatible clients (aider, Cline, curl)
- **Basic**: `Authorization: Basic base64(token:pat_xxx)` — for SDKs that require Basic auth (e.g. Langfuse)

In the Basic auth case, the public key must be the literal string `token` and the secret key must be a PAT starting with `pat_`.

When nginx sees a PAT (via either format):

1. **njs** calls the Keycloak PAT exchange endpoint (internal only)
2. Keycloak hashes the token, finds the user by `pat_hash` attribute
3. Checks expiration, updates `last_used_at`
4. Creates a real short-lived user session + access token via `TokenManager`
5. Returns the access token to nginx
6. **njs** introspects the access token (with caching)
7. Injects `Authorization` and `X-Token-Claims` headers for the backend

### Caching

Two cache layers prevent excessive Keycloak calls:

- **PAT exchange cache** (60s TTL): maps PAT hash to access token
- **Introspection cache** (30s TTL): maps access token to claims

For a frequently-used PAT, Keycloak is called at most once per 60 seconds.

## Security

### What's stored where

| Layer | What it sees |
|---|---|
| Script/CI | Raw `pat_...` token (stored in env var / secret) |
| Nginx (njs) | Raw token (in memory only, for exchange call) |
| Keycloak DB | SHA-256 hash only — raw token never persisted |
| Backend | Nothing about PATs — only `X-Token-Claims` headers |

### Protections

- **Hash-only storage**: Even a full database breach doesn't expose usable tokens
- **Exchange endpoint blocked**: `/realms/public/pat-api/tokens/exchange` returns 403 if accessed directly — only nginx njs calls it internally
- **Expiration**: Configurable TTL, checked on every exchange
- **Per-user limit**: Maximum 10 PATs per user
- **Revocation**: Delete via API or UI, cached exchanges expire within 60s
- **Audit trail**: `last_used_at` tracks token activity
- **Transient sessions**: PAT exchanges create transient (non-persistent) user sessions

### Comparison with alternatives

| Method | Interactive? | Token lifetime | Revocable? | Setup complexity |
|---|---|---|---|---|
| **PAT** | No | Configurable | Yes | One API call |
| OAuth2 password grant | No | Short (5 min) | Via session | Requires client_id + secret |
| OAuth2 client credentials | No | Short (5 min) | Via client | Requires dedicated client per script |
| Service account | No | Short (5 min) | Via client | Admin setup per account |

## Examples

### curl

```bash
export PAT="pat_7kQm9xR2..."
curl -H "Authorization: Bearer $PAT" https://localhost/api/hello
```

### Python

```python
import requests

PAT = "pat_7kQm9xR2..."
resp = requests.get(
    "https://localhost/api/hello",
    headers={"Authorization": f"Bearer {PAT}"},
    verify=False,
)
print(resp.json())
```

### Langfuse SDK

```python
from langfuse import Langfuse

langfuse = Langfuse(
    public_key="token",
    secret_key="pat_7kQm9xR2...",
    host="https://localhost/api",
)
```

### Aider (OpenAI-compatible)

```yaml
# .aider.conf.yml
openai-api-base: https://localhost/api/v1
openai-api-key: pat_7kQm9xR2...
model: openai/mock-gpt
no-stream: true
no-verify-ssl: true
env-file: .aider.env
```

### GitHub Actions

```yaml
jobs:
  deploy:
    steps:
      - name: Call API
        run: |
          curl -H "Authorization: Bearer ${{ secrets.KEYCLOAK_PAT }}" \
            https://example.com/api/hello
```

## Limitations

- PATs inherit the user's full permissions (no per-token scope restriction yet)
- Maximum 10 tokens per user
- Cached exchange results live up to 60s after revocation
- PATs cannot be used to create other PATs (requires a session-based token)
