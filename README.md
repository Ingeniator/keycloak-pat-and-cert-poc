# Keycloak X.509 Certificate Authentication Demo

A demonstration project showing X.509 certificate authentication with Keycloak behind an Nginx reverse proxy. Features GitHub-style certificate management (users register public certificates via API, authenticate with private keys), personal access tokens, fine-grained authorization with OpenFGA, and a phantom token pattern for stateless API access.

## Features

- **X.509 Certificate Authentication** - Register public certificates, authenticate via TLS handshake (like GitHub SSH keys)
- **Personal Access Tokens (PAT)** - GitHub-style long-lived tokens for non-interactive API access
- **Fine-Grained Authorization** - OpenFGA integration with hierarchical permissions (workspace/document model)
- **Phantom Token Pattern** - Nginx introspects opaque tokens and injects JWT claims into backend requests
- **OIDC Gateway** - Nginx + njs handles login, callback, logout, and token resolution
- **Configuration as Code** - Versioned YAML migrations applied automatically via keycloak-config-cli
- **Self-Signed Certificate Support** - Users generate certs like SSH keys, no CA required
- **React UI** - Web interface for certificate management, PAT management, and API testing
- **Comprehensive Test Suite** - Shell-based API tests, Playwright E2E tests, and health checks

## Architecture

```
┌─────────────┐     HTTPS + Client Cert      ┌──────────────────┐
│   Browser   │ ────────────────────────────▶ │      Nginx       │
│             │                               │    (v1.27)       │
└─────────────┘                               │  - TLS termination│
                                              │  - OIDC (njs)    │
┌─────────────┐     Bearer pat_xxx            │  - PAT exchange  │
│  API Client │ ────────────────────────────▶ │  - Phantom token │
│  (curl/SDK) │                               └────┬───┬───┬─────┘
                                                   │   │   │
                          ┌────────────────────────┘   │   └────────────────────┐
                          │                            │                        │
                   ┌──────▼──────┐              ┌──────▼──────┐          ┌──────▼──────┐
                   │  Keycloak   │              │   Backend   │          │     UI      │
                   │   (v24)     │              │ (Express.js)│          │ (React+Vite)│
                   └──────┬──────┘              └──────┬──────┘          └─────────────┘
                          │                            │
                   ┌──────▼──────┐              ┌──────▼──────┐
                   │ PostgreSQL  │              │   OpenFGA   │
                   │   (v15)     │              │  (AuthZ)    │
                   └─────────────┘              └──────┬──────┘
                                                       │
                                                ┌──────▼──────┐
                                                │ PostgreSQL  │
                                                │   (v15)     │
                                                └─────────────┘
```

## Feature Layers

The project is structured as composable layers, each building on the one below. You can run any subset:

```
Layer 4: OpenFGA          Fine-grained authorization (workspaces, documents)
Layer 3: PAT              Personal access tokens for API automation
Layer 2: Gateway + App    Nginx OIDC gateway, React UI, Express backend
Layer 1: X.509 Auth       Certificate authentication flow + migrations
Layer 0: Core             Keycloak + PostgreSQL + baseline realm
```

### Running Individual Layers

```bash
make start-core     # Just Keycloak + PostgreSQL
make start-x509     # + X.509 auth flow
make start-gateway  # + Nginx, UI, backend (no OpenFGA)
make start-pat      # + PAT support
make start-full     # + OpenFGA (everything)
make start          # Full stack (same as start-full, default)
```

Each layer includes all layers below it. The layered compose files live in `docker/` and are merged via `-f` flags. The top-level `docker-compose.yml` is the full stack for `docker compose up -d` compatibility.

You can also compose layers directly:
```bash
docker compose -f docker/compose.base.yml -f docker/compose.x509.yml up -d
```

## Project Structure

```
keycloak_x509_demo/
├── docker-compose.yml              # Full stack (includes all layers)
├── docker/                         # Layered compose files
│   ├── compose.base.yml            # Layer 0: Keycloak + PostgreSQL
│   ├── compose.x509.yml            # Layer 1: X.509 auth migrations
│   ├── compose.gateway.yml         # Layer 2: Nginx + UI + backend
│   ├── compose.pat.yml             # Layer 3: PAT migrations
│   ├── compose.openfga.yml         # Layer 4: OpenFGA stack
│   └── compose.bench.yml           # Benchmarking (k6)
├── .env.example                    # Environment variables template
├── Makefile                        # Build, test, and utility commands
├── keycloak/
│   ├── providers/                  # Custom Keycloak extensions
│   │   ├── x509-cert-api/          # Certificate management API (Maven)
│   │   └── pat-api/                # Personal Access Token API (Maven)
│   ├── migrations/                 # Realm configuration as code
│   │   ├── config-cli/
│   │   │   ├── core/               # Baseline realm, roles, users, clients
│   │   │   ├── x509/              # X.509 auth flow + client mappers
│   │   │   └── pat/               # PAT realm + token support
│   │   └── scripts/                # Migration & admin scripts
│   └── conf/
│       └── quarkus.properties      # Keycloak Quarkus settings
├── gateway/                        # OIDC gateway (Nginx + njs)
│   ├── nginx.conf                  # Upstreams, rate limiting, shared cache
│   ├── conf.d/keycloak.conf        # Reverse proxy, TLS, security headers
│   └── njs/
│       ├── oidc.js                 # Phantom token OIDC handler
│       └── pat.js                  # PAT exchange handler
├── backend/                        # Protected API (Express.js)
│   ├── server.js                   # Endpoints (hello, workspaces, mock OpenAI)
│   └── authz.js                    # OpenFGA authorization middleware
├── ui/                             # Web interface (React + Vite)
│   └── src/
│       ├── App.jsx                 # Main app with auth state
│       ├── PatManager.jsx          # PAT create/list/revoke
│       ├── PublicKeyForm.jsx       # Certificate upload
│       ├── HelloApi.jsx            # API testing
│       └── TokenInfo.jsx           # Token/user display
├── openfga/                        # Fine-grained authorization
│   ├── model.json                  # Relation model (workspace, document)
│   └── seed.mjs                    # Initialize store, model, and tuples
├── certs/                          # Generated PKI
│   ├── ca/                         # Certificate Authority
│   ├── server/                     # Server certificates (Nginx)
│   ├── client/                     # Client certificates (testuser, admin)
│   └── truststore.jks              # Java truststore for Keycloak
├── scripts/
│   ├── setup.sh                    # Full setup (prereqs, certs, build, start)
│   ├── generate-certs.sh           # PKI generation (CA, server, client)
│   ├── generate-client-cert.sh     # New CA-signed client certificate
│   ├── generate-self-signed-cert.sh # Self-signed cert (like ssh-keygen)
│   ├── build-provider.sh           # Build X.509 provider
│   └── build-pat-provider.sh       # Build PAT provider
├── tests/
│   ├── test-all.sh                 # Run all test suites
│   ├── test-health.sh              # Infrastructure health (10 tests)
│   ├── test-api.sh                 # Certificate API (10 tests)
│   ├── test-cert-auth.sh           # Certificate authentication (6 tests)
│   ├── test-pat.sh                 # Personal access token tests
│   ├── test-openfga.sh             # OpenFGA authorization tests
│   └── e2e/                        # Playwright browser tests
│       ├── login.spec.js
│       └── pat.spec.js
└── docs/
    ├── authentication-flow.md      # X.509 auth explained
    ├── personal-access-tokens.md   # PAT feature docs
    ├── PAT-quick-start.md
    ├── phantom-token-architecture.md
    └── migration-guide.md
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenSSL
- Java JDK 17+ (for keytool and building providers)
- Maven (for building custom providers)

### Setup

```bash
# Copy and customize environment variables (optional - defaults work out of the box)
cp .env.example .env

# Complete setup (generates certs, builds providers, starts services)
make setup

# Or step by step:
make certs      # Generate certificates
make build      # Build custom providers (x509 + pat)
make start      # Start Docker services
```

### Access Points

| URL | Description |
|-----|-------------|
| https://localhost/ui/ | Web UI (certificate & PAT management) |
| https://localhost/admin | Keycloak Admin Console |
| https://localhost/api/hello | Backend API (requires auth) |
| https://localhost/realms/x509-demo/account | User Account Console |
| https://localhost/realms/x509-demo/x509-cert-api/certificates | Certificate API |

### Credentials

| User | Password | Roles |
|------|----------|-------|
| admin | admin | Keycloak administrator |
| testuser | testuser123 | user (with test certificate) |

Client certificate password (for .p12 files): `changeit`

## Makefile Commands

```bash
# Setup & Build
make setup           # Complete setup (certs + build + start)
make certs           # Generate certificates only
make build           # Build both custom providers (x509 + pat)
make build-pat       # Build PAT provider only

# Feature Layers (each includes all layers below it)
make start-core      # Layer 0: Keycloak + PostgreSQL
make start-x509      # Layer 1: + X.509 certificate auth
make start-gateway   # Layer 2: + Nginx gateway, UI, backend
make start-pat       # Layer 3: + Personal access tokens
make start-full      # Layer 4: + OpenFGA authorization
make start           # Full stack (all layers, default)

# Service Management
make stop            # Stop Docker services
make restart         # Restart Docker services
make clean           # Remove all generated files

# Logs
make logs            # View all logs
make logs-keycloak   # View Keycloak logs
make logs-gateway    # View Gateway (Nginx) logs
make logs-openfga    # View OpenFGA logs

# Testing
make test            # Run all tests
make test-health     # Infrastructure health checks
make test-setup      # Register test certificates
make test-api        # Certificate management API tests
make test-cert       # Certificate authentication tests
make test-pat        # Personal access token tests
make test-openfga    # OpenFGA authorization tests
make test-e2e        # Playwright browser tests

# Certificates
make gen-cert        # Generate self-signed certificate (like ssh-keygen)
make new-client      # Generate new CA-signed client cert
make register-cert   # Register ~/.x509/certificate.pem for testuser
make import-certs    # Import certs to macOS Keychain
make remove-certs    # Remove certs from macOS Keychain

# Utilities
make export-realm    # Export realm from running Keycloak
make shell-keycloak  # Open shell in Keycloak container
make shell-gateway   # Open shell in Gateway container
make seed-openfga    # Re-run OpenFGA initialization
make help            # Show all available commands
```

## Certificate Authentication Flow

For a detailed explanation, see [docs/authentication-flow.md](docs/authentication-flow.md).

### How It Works

1. **Register certificate** (one-time setup):
   - Authenticate with password
   - Upload **public certificate** (private key stays on your machine)
   - Keycloak stores SHA-256 fingerprint in user attributes

2. **Authenticate with certificate**:
   - Browser presents client certificate during TLS handshake
   - Browser proves private key ownership via cryptographic signature
   - Nginx forwards public cert to Keycloak via headers
   - Custom authenticator looks up user by fingerprint
   - User authenticated without password

### Key Security Points

- **Private key never leaves your machine** - only used for TLS signatures
- **Server stores only public certificate and fingerprint** - no secrets to steal
- **Self-signed certificates supported** - like GitHub SSH keys, no CA required
- TLS handshake cryptographically proves private key ownership

## Generating Your Own Certificate

Users can generate self-signed certificates like SSH keys:

```bash
# Generate certificate (like ssh-keygen)
make gen-cert

# Or specify output directory and identity
./scripts/generate-self-signed-cert.sh ~/.x509 "John Doe" "john@example.com"
```

This creates:
- `private.key.pem` - Keep secret (like `~/.ssh/id_rsa`)
- `certificate.pem` - Upload to API (like `~/.ssh/id_rsa.pub`)
- `certificate.p12` - Import to browser

Then register with Keycloak and import to your browser (see script output for commands).

## Certificate Management API

REST API for managing X.509 certificates, similar to GitHub SSH key management.

### Base URL
```
https://localhost/realms/x509-demo/x509-cert-api/
```

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/certificates` | List all registered certificates |
| POST | `/certificates` | Add a new certificate |
| DELETE | `/certificates/{fingerprint}` | Remove a certificate |
| POST | `/certificates/verify` | Verify if a certificate is registered |

### Example: Add a Certificate

```bash
# Get access token
TOKEN=$(curl -sk -X POST "https://localhost/realms/x509-demo/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=x509-demo-app" \
    -d "client_secret=demo-app-secret" \
    -d "username=testuser" \
    -d "password=testuser123" | jq -r '.access_token')

# Add certificate
curl -sk -X POST "https://localhost/realms/x509-demo/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----",
        "title": "My Laptop Certificate"
    }'
```

## Personal Access Tokens

GitHub-style long-lived tokens for non-interactive API access. See [docs/personal-access-tokens.md](docs/personal-access-tokens.md) for full documentation.

### Quick Start

```bash
# Create a PAT via API
curl -sk -X POST "https://localhost/api/pat/tokens" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name": "my-script", "expiresIn": "30d"}'

# Use PAT to call API
curl -sk "https://localhost/api/hello" \
    -H "Authorization: Bearer pat_xxxxx"
```

### PAT API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/pat/tokens` | Create a new PAT |
| GET | `/api/pat/tokens` | List all PATs |
| DELETE | `/api/pat/tokens/{id}` | Revoke a PAT |

Token format: `pat_<random_base62>`. Configurable expiration from 7 days to 1 year. PATs are exchanged for JWTs at the Nginx layer and cached in shared memory.

## Phantom Token Pattern

Nginx acts as a security gateway, resolving opaque tokens (session cookies or PATs) into JWTs before forwarding to the backend. See [docs/phantom-token-architecture.md](docs/phantom-token-architecture.md).

- All API requests pass through `/_auth` subrequest
- Nginx introspects tokens via Keycloak
- Backend receives `Authorization: Bearer <jwt>` and `X-Token-Claims: <json>` headers
- Results cached in shared memory for performance
- Backend never validates JWT signatures - trusts Nginx

## OpenFGA Authorization

Fine-grained authorization using [OpenFGA](https://openfga.dev/) for hierarchical permission checks.

### Authorization Model

```
workspace
  ├── owner   → user
  ├── admin   → user | workspace:owner
  ├── member  → user | workspace:admin
  └── viewer  → user | workspace:member

document
  ├── workspace → workspace
  ├── owner     → user
  ├── editor    → user | document:owner | workspace:admin
  └── viewer    → user | document:editor | workspace:member
```

### Protected Endpoints

| Endpoint | Required Relation |
|----------|-------------------|
| `GET /api/workspaces/:id` | viewer |
| `POST /api/workspaces/:id/settings` | admin |
| `GET /api/workspaces/:id/documents/:docId` | viewer |
| `PUT /api/workspaces/:id/documents/:docId` | editor |

## Configuration as Code

Realm configuration is defined as versioned YAML migrations in `keycloak/migrations/config-cli/`, organized by feature layer and applied automatically by keycloak-config-cli on startup:

| Layer | Directory | Migrations |
|-------|-----------|------------|
| Core | `config-cli/core/` | `000_baseline.yaml` — Realm, roles, users, clients |
| X.509 | `config-cli/x509/` | `001_x509-authentication-flow.yaml` — Custom X.509 browser flow |
| | | `002_x509-client-mappers.yaml` — Certificate attributes in tokens |
| PAT | `config-cli/pat/` | `003_public-realm.yaml` — Public realm for PAT/OpenFGA |
| | | `004_pat-support.yaml` — PAT client configuration |
| | | `005_pat-production.yaml` — PAT production settings |

When running a subset of layers (e.g. `make start-x509`), only the migrations for that layer and below are applied.

### Modifying Configuration

Add a new numbered YAML file to the appropriate feature subdirectory under `keycloak/migrations/config-cli/` and restart:
```bash
make restart
```

Or export the current realm from a running instance:
```bash
make export-realm
```

## Browser Setup for Certificate Authentication

### macOS

```bash
# Import certificates to Keychain (recommended)
make import-certs

# Or manually:
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca/ca.crt.pem
security import certs/client/testuser/client.p12 -k ~/Library/Keychains/login.keychain-db -P changeit -A
```

### Other Systems

1. Import CA certificate (`certs/ca/ca.crt.pem`) as trusted root
2. Import client certificate (`certs/client/testuser/client.p12`, password: `changeit`)

### Test Authentication

1. Visit https://localhost/realms/x509-demo/account
2. Browser prompts for certificate selection
3. Select your imported certificate
4. Logged in automatically (no password)

## Custom Provider Development

Two Keycloak SPI (Service Provider Interface) extensions:

### X.509 Certificate API (`keycloak/providers/x509-cert-api/`)

| File | Purpose |
|------|---------|
| `X509CertificateResource.java` | REST endpoints for certificate CRUD |
| `X509UserAttributeAuthenticator.java` | Authenticator that looks up users by cert fingerprint |
| `X509UserAttributeAuthenticatorFactory.java` | Authenticator factory |

### PAT API (`keycloak/providers/pat-api/`)

| File | Purpose |
|------|---------|
| `PatResource.java` | REST endpoints for PAT create/list/revoke/exchange |
| `PatResourceProvider.java` | Provider implementation |
| `PatResourceProviderFactory.java` | Factory for Keycloak |

### Building

```bash
make build      # Build both providers
make restart    # Restart to load
```

## Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Identity Provider | Keycloak | 24.0 |
| Gateway / Proxy | Nginx + njs | 1.27 |
| Backend API | Express.js | Node 20 |
| Frontend | React + Vite | Node 20 |
| Authorization | OpenFGA | latest |
| Database | PostgreSQL | 15 |
| E2E Testing | Playwright | latest |
| Provider Build | Maven | latest |
| Containers | Docker Compose | latest |

## Troubleshooting

### Certificate not being passed to Keycloak

```bash
make logs-gateway
```
Look for `ssl_client_verify="SUCCESS"` in the logs.

### Keycloak not starting

```bash
make logs-keycloak
```
Common issues: truststore not found, invalid configuration, provider JAR build issues.

### Cannot authenticate with certificate

1. Run tests: `make test`
2. Verify certificate is registered in Keycloak admin (user attributes)
3. Check certificate fingerprint matches
4. Ensure X.509 browser flow is active

### macOS Keychain import fails

If you see "MAC verification failed":
```bash
make import-certs   # Regenerates PKCS12 with compatible algorithms
```

### Tests failing

```bash
make logs       # Check service logs
make restart    # Restart services
make test       # Re-run tests
```

## License

MIT License - See LICENSE file for details.
