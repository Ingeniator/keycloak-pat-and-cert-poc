# Keycloak X.509 Certificate Authentication Demo

A demonstration project showing how to configure Keycloak v24 with X.509 certificate authentication behind Nginx v1.25 reverse proxy. Features GitHub-style certificate management where users can register their certificates via API.

## Features

- **Keycloak v24** with X.509 client certificate authentication
- **Nginx v1.25** reverse proxy with SSL termination and client certificate forwarding
- **Configuration as Code** - realm, clients, roles, and authentication flows defined in JSON
- **Custom Certificate API** - REST API for users to manage their X.509 certificates (similar to GitHub SSH keys)
- **Custom Authenticator** - Looks up users by certificate fingerprint stored in user attributes
- **Self-signed certificates** - Complete PKI setup with CA, server, and client certificates

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
├── keycloak/
│   ├── realm-config/           # Realm configuration as code
│   │   └── x509-realm.json     # Complete realm definition
│   ├── providers/              # Custom Keycloak extensions
│   │   └── x509-cert-api/      # Certificate management API (Maven project)
│   ├── themes/                 # Custom themes (optional)
│   └── conf/                   # Additional configuration
├── nginx/
│   ├── nginx.conf              # Main Nginx configuration
│   └── conf.d/
│       └── keycloak.conf       # Reverse proxy configuration
├── certs/                      # Generated certificates
│   ├── ca/                     # Certificate Authority
│   ├── server/                 # Server certificates
│   ├── client/                 # Client certificates
│   └── truststore.jks          # Java truststore for Keycloak
├── scripts/
│   ├── setup.sh                # Main setup script
│   ├── generate-certs.sh       # Certificate generation
│   ├── build-provider.sh       # Build custom provider
│   ├── test-api.sh             # Test certificate API
│   └── test-cert-auth.sh       # Test certificate authentication
└── docs/                       # Additional documentation
```

## Quick Start

### Prerequisites

- Docker & Docker Compose
- OpenSSL
- Java JDK 17+ (for keytool and building provider)
- Maven (for building custom provider)

### Setup

1. **Clone and setup:**
   ```bash
   cd keycloak_x509_demo
   chmod +x scripts/*.sh
   ./scripts/setup.sh
   ```

   This will:
   - Generate CA, server, and client certificates
   - Build the custom Keycloak provider
   - Start all Docker services
   - Import the realm configuration

2. **Access Keycloak:**
   - Admin Console: https://localhost/admin
   - Username: `admin`
   - Password: `admin`

3. **Test user credentials:**
   - Username: `testuser`
   - Password: `testuser123`

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

1. **User registers certificate via API:**
   - Authenticates with password
   - Uploads their X.509 certificate
   - Certificate fingerprint stored in user attributes

2. **User authenticates with certificate:**
   - Browser presents client certificate
   - Nginx forwards certificate to Keycloak
   - Custom authenticator extracts fingerprint
   - Looks up user by fingerprint in attributes
   - User authenticated without password

## Browser Setup for Certificate Authentication

1. **Import CA certificate:**
   - File: `certs/ca/ca.crt.pem`
   - Add to trusted root authorities

2. **Import client certificate:**
   - File: `certs/client/testuser/client.p12`
   - Password: `changeit`

3. **Test authentication:**
   - Visit: https://localhost/realms/x509-demo/account
   - Browser should prompt for certificate selection
   - Select your imported certificate

## Configuration as Code

The realm configuration in `keycloak/realm-config/x509-realm.json` includes:

- **Realm settings:** SSL requirements, brute force protection, events
- **Roles:** `user`, `admin`, `cert-manager`
- **Users:** Pre-configured test users with attributes
- **Clients:** `x509-demo-app` (public app), `cert-api-client` (service account)
- **Authentication flows:** Custom X.509 browser flow
- **Protocol mappers:** Include certificate attributes in tokens

### Modifying Configuration

1. Edit `keycloak/realm-config/x509-realm.json`
2. Restart Keycloak: `docker-compose restart keycloak`

Or export from running Keycloak:
```bash
docker exec keycloak /opt/keycloak/bin/kc.sh export \
    --dir /opt/keycloak/data/export \
    --realm x509-demo
```

## Custom Provider Development

The X.509 Certificate API is implemented as a Keycloak SPI (Service Provider Interface).

### Building

```bash
./scripts/build-provider.sh
docker-compose restart keycloak
```

### Key Components

- `X509CertificateResource.java` - REST endpoints
- `X509CertificateResourceProvider.java` - Provider implementation
- `X509CertificateResourceProviderFactory.java` - Factory for Keycloak
- `X509UserAttributeAuthenticator.java` - Custom authenticator
- `X509UserAttributeAuthenticatorFactory.java` - Authenticator factory

### Adding New Endpoints

1. Add method to `X509CertificateResource.java`
2. Rebuild: `./scripts/build-provider.sh`
3. Restart Keycloak

## Security Considerations

- **Production use:** Replace self-signed certificates with proper CA-signed certificates
- **Certificate validation:** Enable CRL/OCSP checking in production
- **Key storage:** Protect private keys appropriately
- **Rate limiting:** Add rate limiting to certificate API
- **Audit logging:** Monitor certificate additions/removals

## Troubleshooting

### Certificate not being passed to Keycloak

Check Nginx logs:
```bash
docker-compose logs nginx
```

Verify SSL client certificate headers are being set.

### Keycloak not starting

Check Keycloak logs:
```bash
docker-compose logs keycloak
```

Common issues:
- Truststore not found or wrong password
- Invalid realm configuration JSON
- Provider JAR build issues

### Cannot authenticate with certificate

1. Verify certificate is registered in user attributes
2. Check certificate fingerprint matches
3. Ensure authentication flow is configured correctly

## Scripts Reference

| Script | Description |
|--------|-------------|
| `setup.sh` | Complete setup (certs + build + start) |
| `generate-certs.sh` | Generate all certificates |
| `build-provider.sh` | Build custom Keycloak provider |
| `test-api.sh` | Test certificate management API |
| `test-cert-auth.sh` | Test certificate authentication |

## License

MIT License - See LICENSE file for details.
