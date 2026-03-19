# Keycloak X.509 Certificate Authentication Demo

A demonstration project showing how to configure Keycloak v24 with X.509 certificate authentication behind Nginx v1.25 reverse proxy. Features GitHub-style certificate management where users can register their certificates via API.

## Features

- **Keycloak v24** with X.509 client certificate authentication
- **Nginx v1.25** reverse proxy with SSL termination and client certificate forwarding
- **Configuration as Code** - realm, clients, roles, and authentication flows defined in JSON
- **Custom Certificate API** - REST API for users to manage their X.509 certificates (similar to GitHub SSH keys)
- **Custom Authenticator** - Looks up users by certificate fingerprint stored in user attributes
- **Self-signed certificates** - Complete PKI setup with CA, server, and client certificates
- **Comprehensive test suite** - Automated tests for API, authentication, and infrastructure

## Architecture

```
┌─────────────┐     HTTPS + Client Cert      ┌─────────────┐
│   Browser   │ ──────────────────────────▶  │    Nginx    │
│  (User)     │                              │   (v1.25)   │
└─────────────┘                              └──────┬──────┘
                                                   │
                                            HTTP + Headers
                                                   │
                                            ┌──────▼──────┐
                                            │  Keycloak   │
                                            │   (v24)     │
                                            └──────┬──────┘
                                                   │
                                            ┌──────▼──────┐
                                            │ PostgreSQL  │
                                            │   (v15)     │
                                            └─────────────┘
```

## Project Structure

```
keycloak_x509_demo/
├── docker-compose.yml          # Main orchestration file
├── .env.example                # Environment variables template
├── Makefile                    # Build and test commands
├── keycloak/
│   ├── providers/              # Custom Keycloak extensions
│   │   ├── x509-cert-api/      # Certificate management API (Maven project)
│   │   └── pat-api/            # Personal Access Token API (Maven project)
│   ├── migrations/             # Realm configuration as code
│   │   ├── config-cli/         # Versioned YAML migrations
│   │   └── scripts/            # Migration & admin scripts
│   └── conf/                   # Additional configuration
│       └── quarkus.properties  # Keycloak Quarkus settings
├── gateway/                    # OIDC gateway (nginx + njs)
│   ├── nginx.conf              # Main Nginx configuration
│   ├── conf.d/
│   │   └── keycloak.conf       # Reverse proxy configuration
│   └── njs/
│       └── oidc.js             # Phantom token OIDC handler
├── certs/                      # Generated certificates
│   ├── ca/                     # Certificate Authority
│   ├── server/                 # Server certificates
│   ├── client/                 # Client certificates
│   └── truststore.jks          # Java truststore for Keycloak
├── scripts/
│   ├── setup.sh                # Main setup script
│   ├── generate-certs.sh       # Certificate generation
│   └── build-provider.sh       # Build custom provider
└── tests/
    ├── package.json            # Playwright dependency
    ├── playwright.config.js    # Playwright configuration
    ├── test-all.sh             # Run all tests
    ├── test-health.sh          # Infrastructure health tests
    ├── test-setup.sh           # Test setup (register certificates)
    ├── test-api.sh             # Certificate API tests
    ├── test-cert-auth.sh       # Certificate authentication tests
    ├── test-pat.sh             # Personal Access Token tests
    └── e2e/                    # Playwright end-to-end tests
        ├── helpers.js
        ├── login.spec.js
        └── pat.spec.js
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenSSL
- Java JDK 17+ (for keytool and building provider)
- Maven (for building custom provider)

### Setup

```bash
# Copy and customize environment variables (optional — defaults work out of the box)
cp .env.example .env

# Complete setup (generates certs, builds provider, starts services)
make setup

# Or step by step:
make certs      # Generate certificates
make build      # Build custom provider
make start      # Start Docker services
```

### Access Points

| URL | Description |
|-----|-------------|
| https://localhost/admin | Keycloak Admin Console |
| https://localhost/realms/x509-demo/account | User Account Console |
| https://localhost/realms/x509-demo/x509-cert-api/certificates | Certificate API |

### Credentials

| User | Password | Description |
|------|----------|-------------|
| admin | admin | Keycloak admin |
| testuser | testuser123 | Test user with certificate |

## Makefile Commands

```bash
make setup          # Complete setup (certs + build + start)
make certs          # Generate certificates only
make build          # Build custom Keycloak provider
make start          # Start Docker services
make stop           # Stop Docker services
make restart        # Restart Docker services
make logs           # View all logs
make logs-keycloak  # View Keycloak logs
make logs-gateway   # View Gateway (nginx) logs
make clean          # Remove all generated files

# Testing
make test           # Run all tests
make test-health    # Test infrastructure health
make test-setup     # Register test certificates
make test-api       # Test certificate management API
make test-cert      # Test certificate authentication

# Browser testing (macOS)
make import-certs   # Import certs to macOS Keychain
make remove-certs   # Remove certs from macOS Keychain

# Utilities
make export-realm   # Export realm from running Keycloak
make shell-keycloak # Open shell in Keycloak container
make shell-gateway  # Open shell in Gateway (nginx) container
make new-client     # Generate new client certificate
make help           # Show all available commands
```

## Testing

Run the complete test suite:

```bash
make test
```

The test suite includes:

### Infrastructure Health Tests (10 tests)
- Keycloak accessibility
- Realm configuration
- OIDC endpoints
- Nginx SSL termination
- Custom X509 API provider
- Database connectivity
- OAuth client configuration
- Test user existence
- X.509 browser flow
- Certificate files

### Certificate API Tests (10 tests)
- Authentication and token retrieval
- List certificates endpoint
- Unauthorized access rejection
- Add certificate
- Verify certificate
- Invalid certificate handling
- Empty certificate rejection
- Duplicate certificate rejection
- Certificate info in response
- Token x509 claims

### Certificate Authentication Tests (6 tests)
- TLS connection with client certificate
- Nginx certificate forwarding
- Authentication flow with certificate
- Keycloak certificate processing
- Login page without certificate
- Unregistered certificate handling

## Certificate Management API

The custom API allows users to manage their X.509 certificates, similar to GitHub's SSH key management.

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

### Example: List Certificates

```bash
curl -sk "https://localhost/realms/x509-demo/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN"
```

## Certificate Authentication Flow

For a detailed explanation of how X.509 authentication works, including the role of public and private keys, see [docs/authentication-flow.md](docs/authentication-flow.md).

### Quick Overview

1. **User registers certificate via API:**
   - Authenticates with password
   - Uploads their **public certificate** (private key stays on their machine)
   - Certificate fingerprint (SHA-256 hash) stored in user attributes

2. **User authenticates with certificate:**
   - Browser presents client certificate during TLS handshake
   - Browser proves private key ownership via cryptographic signature
   - Nginx verifies signature and forwards public cert to Keycloak
   - Custom authenticator extracts fingerprint from certificate
   - Looks up user by fingerprint in attributes
   - User authenticated without password

### Key Security Points

- **Private key NEVER leaves the user's machine** - only used for TLS signatures
- **Server only stores public certificate and fingerprint** - no secrets to steal
- **TLS handshake proves identity** - browser cryptographically proves private key ownership
- **Self-signed certificates supported** - like GitHub SSH keys, no CA required
- Similar to GitHub SSH keys - upload public key, authenticate with private key

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

## Browser Setup for Certificate Authentication

### macOS

```bash
# Import certificates to Keychain (recommended)
make import-certs

# Or manually:
# 1. Import CA as trusted root (requires sudo)
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca/ca.crt.pem

# 2. Import client certificate
security import certs/client/testuser/client.p12 -k ~/Library/Keychains/login.keychain-db -P changeit -A
```

### Other Systems

1. **Import CA certificate:**
   - File: `certs/ca/ca.crt.pem`
   - Add to trusted root authorities

2. **Import client certificate:**
   - File: `certs/client/testuser/client.p12`
   - Password: `changeit`

### Test Authentication

1. Visit: https://localhost/realms/x509-demo/account
2. Browser should prompt for certificate selection
3. Select your imported certificate
4. You should be logged in automatically

## Configuration as Code

The realm configuration in `keycloak/realm-config/x509-realm.json` includes:

- **Realm settings:** SSL requirements, brute force protection, events
- **Roles:** `user`, `admin`, `cert-manager`
- **Users:** Pre-configured test users with attributes
- **Clients:** `x509-demo-app` (public app), `cert-api-client` (service account)
- **Authentication flows:** Custom X.509 browser flow with certificate-based authenticator
- **Protocol mappers:** Include certificate attributes in tokens
- **User profile:** Custom attributes for certificate storage

### Modifying Configuration

1. Edit `keycloak/realm-config/x509-realm.json`
2. Restart Keycloak: `make restart`

Or export from running Keycloak:
```bash
make export-realm
```

## Custom Provider Development

The X.509 Certificate API is implemented as a Keycloak SPI (Service Provider Interface).

### Building

```bash
make build
make restart
```

### Key Components

| File | Description |
|------|-------------|
| `X509CertificateResource.java` | REST endpoints for certificate management |
| `X509CertificateResourceProvider.java` | Provider implementation |
| `X509CertificateResourceProviderFactory.java` | Factory for Keycloak |
| `X509UserAttributeAuthenticator.java` | Custom authenticator for certificate lookup |
| `X509UserAttributeAuthenticatorFactory.java` | Authenticator factory |

### Adding New Endpoints

1. Add method to `X509CertificateResource.java`
2. Rebuild: `make build`
3. Restart: `make restart`

## Security Considerations

- **Production use:** Replace self-signed certificates with proper CA-signed certificates
- **Certificate validation:** Enable CRL/OCSP checking in production
- **Key storage:** Protect private keys appropriately
- **Rate limiting:** Add rate limiting to certificate API
- **Audit logging:** Monitor certificate additions/removals
- **HTTPS:** Always use HTTPS in production

## Troubleshooting

### Certificate not being passed to Keycloak

Check Nginx logs:
```bash
make logs-gateway
```

Look for `ssl_client_verify="SUCCESS"` in the logs.

### Keycloak not starting

Check Keycloak logs:
```bash
make logs-keycloak
```

Common issues:
- Truststore not found or wrong password
- Invalid realm configuration JSON
- Provider JAR build issues

### Cannot authenticate with certificate

1. Run tests to verify setup: `make test`
2. Verify certificate is registered: Check user attributes in Keycloak admin
3. Check certificate fingerprint matches
4. Ensure authentication flow is configured correctly

### macOS Keychain import fails

If you see "MAC verification failed":
```bash
# Regenerate PKCS12 with legacy algorithms
make import-certs
```

### Tests failing

```bash
# Check if services are running
make logs

# Restart services
make restart

# Run tests again
make test
```

## License

MIT License - See LICENSE file for details.
