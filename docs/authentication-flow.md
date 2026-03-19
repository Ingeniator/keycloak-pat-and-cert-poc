# X.509 Certificate Authentication Flow

This document explains how X.509 certificate authentication works in this project, including the role of public and private keys.

## Public Key Cryptography Basics

X.509 certificates use asymmetric cryptography with a **key pair**:

| Key | Location | Purpose |
|-----|----------|---------|
| **Private Key** | User's machine only (NEVER shared) | Signs data to prove identity |
| **Public Key** | Inside the certificate (shared freely) | Verifies signatures |

The certificate (`.crt` or `.pem`) contains:
- Public key
- User identity information (CN, email, etc.)
- Issuer (CA) signature
- Validity period
- Fingerprint (hash of the certificate)

## How Authentication Works

### Step 1: Certificate Registration (One-time Setup)

```
┌──────────────┐                              ┌──────────────┐
│    User      │                              │   Keycloak   │
│   Browser    │                              │              │
└──────┬───────┘                              └──────┬───────┘
       │                                             │
       │  1. Login with username/password            │
       │────────────────────────────────────────────▶│
       │                                             │
       │  2. Get access token                        │
       │◀────────────────────────────────────────────│
       │                                             │
       │  3. POST /x509-cert-api/certificates        │
       │     Body: { certificate: "PUBLIC CERT" }    │
       │────────────────────────────────────────────▶│
       │                                             │
       │                            4. Extract fingerprint
       │                            5. Store in user attributes:
       │                               x509_cert_fingerprints: ["SHA256:abc..."]
       │                               x509_cert_0: "-----BEGIN CERT..."
       │                                             │
       │  6. Success: certificate registered         │
       │◀────────────────────────────────────────────│
```

**What happens:**
- User uploads their **public certificate** (NOT the private key!)
- Server calculates the certificate's **fingerprint** (SHA-256 hash)
- Fingerprint is stored in user's Keycloak attributes
- The certificate itself is also stored for reference

### Step 2: Certificate Authentication (Login)

```
┌──────────────┐         ┌──────────────┐         ┌──────────────┐
│    User      │         │    Nginx     │         │   Keycloak   │
│   Browser    │         │   (TLS)      │         │              │
└──────┬───────┘         └──────┬───────┘         └──────┬───────┘
       │                        │                        │
       │  1. HTTPS Request      │                        │
       │───────────────────────▶│                        │
       │                        │                        │
       │  2. TLS Handshake:     │                        │
       │     Server asks for    │                        │
       │     client certificate │                        │
       │◀───────────────────────│                        │
       │                        │                        │
       │  3. Browser sends:     │                        │
       │     - Public Cert      │                        │
       │     - Signature (made  │                        │
       │       with PRIVATE KEY)│                        │
       │───────────────────────▶│                        │
       │                        │                        │
       │     4. Nginx verifies: │                        │
       │        - Signature valid (proves private key)   │
       │        - Cert signed by trusted CA              │
       │        - Cert not expired                       │
       │                        │                        │
       │                        │  5. Forward request +  │
       │                        │     SSL_CLIENT_CERT    │
       │                        │─────────────────────▶  │
       │                        │                        │
       │                        │     6. Custom Authenticator:
       │                        │        - Extract fingerprint
       │                        │        - Search users by fingerprint
       │                        │        - Find matching user
       │                        │        - Authenticate user
       │                        │                        │
       │                        │  7. Auth code/token    │
       │◀─────────────────────────────────────────────────│
```

**Where the Private Key is used:**

The private key is used during the **TLS handshake** (step 3):

1. Nginx sends a random challenge to the browser
2. Browser signs the challenge using the **private key**
3. Browser sends: public certificate + signature
4. Nginx verifies the signature using the **public key** from the certificate

This proves the user possesses the private key **without ever transmitting it**.

## Security Model

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER'S MACHINE                           │
│  ┌─────────────────┐    ┌─────────────────┐                     │
│  │  Private Key    │    │  Public Cert    │                     │
│  │  (NEVER LEAVES) │    │  (can be shared)│                     │
│  │                 │    │                 │                     │
│  │  client.key.pem │    │  client.crt.pem │                     │
│  └────────┬────────┘    └────────┬────────┘                     │
│           │                      │                              │
│           │    TLS Handshake     │    API Upload                │
│           │    (proves ownership)│    (registration)            │
│           ▼                      ▼                              │
└───────────┼──────────────────────┼──────────────────────────────┘
            │                      │
            │                      │
┌───────────┼──────────────────────┼──────────────────────────────┐
│           │       NGINX          │                              │
│           ▼                      │                              │
│  ┌─────────────────┐             │                              │
│  │ Verify signature│             │                              │
│  │ using public key│             │                              │
│  └────────┬────────┘             │                              │
│           │                      │                              │
│           │  SSL_CLIENT_CERT     │                              │
│           │  (public cert only)  │                              │
│           ▼                      ▼                              │
└───────────┼──────────────────────┼──────────────────────────────┘
            │                      │
┌───────────┼──────────────────────┼──────────────────────────────┐
│           │      KEYCLOAK        │                              │
│           ▼                      ▼                              │
│  ┌───────────────────────────────────-──────┐                   │
│  │  Custom Authenticator                    │                   │
│  │  - Extracts fingerprint from cert        │                   │
│  │  - Searches user attributes              │                   │
│  │  - Matches: x509_cert_fingerprints       │                   │
│  └─────────────────────────────────────-────┘                   │
│                                                                 │
│  ┌───────────────────────────────────────-──┐                   │
│  │  User Attributes (stored in DB)          │                   │
│  │  - x509_cert_fingerprints: ["SHA256:..."]│                   │
│  │  - x509_cert_0: "-----BEGIN CERT..."     │                   │
│  │  - x509_cert_0_title: "My Laptop"        │                   │
│  └─────────────────────────────────────────-┘                   │
└─────────────────────────────────────────────────────────────────┘
```

## Key Points

### What is stored on the server?

| Data | Stored? | Purpose |
|------|---------|---------|
| Private Key | **NO, NEVER** | Stays on user's machine |
| Public Certificate | Yes | For reference and display |
| Certificate Fingerprint | Yes | For quick user lookup |
| Certificate Title | Yes | User-friendly name |

### What proves the user's identity?

1. **TLS handshake** proves the user has the private key (via signature verification)
2. **Fingerprint matching** links the certificate to a specific Keycloak user
3. **CA signature** on the certificate proves it was issued by a trusted authority

### Why is this secure?

1. **Private key never transmitted** - Only signatures are sent
2. **Fingerprint is a hash** - Cannot reverse to get the certificate
3. **CA trust chain** - Only certificates from trusted CAs are accepted
4. **User binding** - Certificate must be pre-registered to a user account

## Comparison with Password Authentication

| Aspect | Password | Certificate |
|--------|----------|-------------|
| Secret storage | Server stores hash | Server stores fingerprint (public info) |
| Secret transmission | Password sent over TLS | Private key NEVER sent |
| Proof of identity | Knowledge (something you know) | Possession (something you have) |
| Phishing resistance | Low (user can type password on fake site) | High (browser handles TLS) |
| Credential theft | If server breached, hashes exposed | Only public certs exposed |

## Comparison with SSH Key Authentication (GitHub)

This project's flow is similar to GitHub's SSH key management:

| GitHub SSH | This Project (X.509) |
|------------|---------------------|
| User generates SSH key pair | User generates X.509 certificate |
| `ssh-keygen -t rsa` | `make gen-cert` or `openssl` |
| Uploads public key to GitHub | Uploads public certificate to API |
| GitHub stores public key | Keycloak stores cert fingerprint |
| SSH client uses private key | Browser uses private key (TLS) |
| Server verifies signature | Nginx verifies signature |
| No CA required | No CA required (self-signed OK) |

## Trust Models: CA-Signed vs Self-Signed

This project supports two trust models:

### Model 1: Self-Signed Certificates (Default - Like SSH)

```
┌─────────────────────────────────────────────────────────────────┐
│  TRUST = Registration                                           │
│                                                                 │
│  User generates self-signed cert  ──▶  Uploads to API           │
│  (like ssh-keygen)                     (like GitHub SSH keys)   │
│                                                                 │
│  Trust is based on: "This fingerprint belongs to this user"     │
│  CA verification: NONE (ssl_verify_client optional_no_ca)       │
└─────────────────────────────────────────────────────────────────┘
```

**Nginx config:** `ssl_verify_client optional_no_ca`

**Pros:**
- Users can generate their own certificates (no PKI infrastructure needed)
- Simple like SSH keys
- Users control their own key pairs

**Cons:**
- No revocation checking (CRL/OCSP)
- No centralized certificate management
- Must trust user's certificate generation

### Model 2: CA-Signed Certificates (Enterprise)

```
┌─────────────────────────────────────────────────────────────────┐
│  TRUST = CA Signature + Registration                            │
│                                                                 │
│  CA signs user's cert  ──▶  User uploads to API                 │
│  (corporate PKI)            (registers with account)            │
│                                                                 │
│  Trust is based on: "CA vouches for identity" + "fingerprint    │
│                      belongs to this user"                      │
│  CA verification: YES (ssl_verify_client optional)              │
└─────────────────────────────────────────────────────────────────┘
```

**Nginx config:** `ssl_verify_client optional`

**Pros:**
- CA can verify user identity before issuing cert
- Supports revocation (CRL/OCSP)
- Centralized certificate lifecycle management

**Cons:**
- Requires PKI infrastructure
- More complex setup
- Users depend on CA for certificates

### Switching Between Models

Edit `gateway/conf.d/keycloak.conf`:

```nginx
# Self-signed (like SSH keys) - DEFAULT
ssl_verify_client optional_no_ca;

# CA-signed only (enterprise)
ssl_verify_client optional;
```

Then restart: `make restart`

## Email Fallback Authentication

The authenticator supports **email fallback** for CA-signed certificates. This allows users with certificates from a trusted CA to authenticate without pre-registering their certificate, as long as the email in the certificate matches their Keycloak user email.

### How It Works

```
Certificate presented
        │
        ▼
┌───────────────────────────────────────┐
│ 1. Fingerprint lookup                 │
│    Found? ──────────────────────────────▶ Authenticate ✓
│    (works for self-signed & CA-signed)│
└───────────────────┬───────────────────┘
                    │ (not found)
                    ▼
┌───────────────────────────────────────┐
│ 2. Email fallback enabled?            │
│    No? ─────────────────────────────────▶ Reject ✗
└───────────────────┬───────────────────┘
                    │ (yes)
                    ▼
┌───────────────────────────────────────┐
│ 3. Certificate signed by trusted CA?  │
│    No? ─────────────────────────────────▶ Reject ✗
│    (self-signed certs blocked here)   │
└───────────────────┬───────────────────┘
                    │ (yes)
                    ▼
┌───────────────────────────────────────┐
│ 4. Extract email from certificate     │
│    - Subject Alternative Name (SAN)   │
│    - Subject DN (emailAddress field)  │
└───────────────────┬───────────────────┘
                    │
                    ▼
┌───────────────────────────────────────┐
│ 5. Find user by email in Keycloak     │
│    Not found? ──────────────────────────▶ Reject ✗
└───────────────────┬───────────────────┘
                    │ (found)
                    ▼
┌───────────────────────────────────────┐
│ 6. Auto-register fingerprint          │
│    (for faster future logins)         │
└───────────────────┬───────────────────┘
                    │
                    ▼
              Authenticate ✓
```

### Configuration

#### Environment Variable (Recommended)

Set the path to your trusted CA certificate file:

```bash
# In docker-compose.yml
services:
  keycloak:
    environment:
      X509_TRUSTED_CA_CERT_PATH: /opt/keycloak/conf/trusted-ca.pem
    volumes:
      - ./certs/ca/ca.crt.pem:/opt/keycloak/conf/trusted-ca.pem:ro
```

The file can contain multiple PEM-encoded certificates (concatenated).

#### Authenticator Configuration (Alternative)

In the Keycloak Admin Console:

1. Go to **Authentication** → **Flows** → your X509 flow
2. Click the gear icon on the authenticator
3. Configure:

| Option | Default | Description |
|--------|---------|-------------|
| **Enable Email Fallback** | `true` | Allow email-based lookup for CA-signed certs |
| **Auto-register Certificate** | `true` | Store fingerprint after email match for faster future logins |
| **Trusted CA Certificate(s)** | (empty) | Inline PEM (only if env var not set) |

### Security Considerations

| Certificate Type | Fingerprint Auth | Email Fallback |
|-----------------|------------------|----------------|
| Self-signed | Yes (must pre-register) | No (blocked) |
| CA-signed (trusted) | Yes | Yes |
| CA-signed (untrusted) | Yes (must pre-register) | No (blocked) |

**Why block email fallback for self-signed certs?**

Anyone can create a self-signed certificate with any email address. Without CA verification, a malicious user could create a certificate with `admin@company.com` and gain access.

With a trusted CA, the CA is responsible for verifying the user's identity and email ownership before issuing the certificate.

### Example: Corporate PKI Setup

```yaml
# docker-compose.yml
services:
  keycloak:
    environment:
      # Path to corporate CA certificate
      X509_TRUSTED_CA_CERT_PATH: /opt/keycloak/conf/corporate-ca.pem
    volumes:
      # Mount the CA certificate
      - ./certs/corporate-ca.pem:/opt/keycloak/conf/corporate-ca.pem:ro
```

With this setup:
1. Employees with corporate-issued certificates can log in immediately
2. Their email in the certificate is matched to their Keycloak account
3. Certificate fingerprint is auto-registered for faster future logins
4. Self-signed certificates still work if pre-registered via the API

## Generating Self-Signed Certificates

Users can generate their own certificates like SSH keys:

```bash
# Using the provided script (recommended)
make gen-cert

# Or manually with openssl
openssl genrsa -out private.key.pem 4096
openssl req -new -x509 -key private.key.pem -out certificate.pem -days 365 \
    -subj "/CN=Your Name/emailAddress=you@example.com"

# Create PKCS12 for browser
openssl pkcs12 -export -out certificate.p12 \
    -inkey private.key.pem -in certificate.pem -legacy -passout pass:changeit
```

### Using keytool (Java)

```bash
# Generate key pair and self-signed certificate
keytool -genkeypair -alias mycert -keyalg RSA -keysize 4096 \
    -validity 365 -keystore keystore.p12 -storetype PKCS12 \
    -dname "CN=Your Name, EMAIL=you@example.com" \
    -storepass changeit

# Export certificate (to upload to API)
keytool -exportcert -alias mycert -keystore keystore.p12 \
    -storetype PKCS12 -storepass changeit -rfc -file certificate.pem
```

## File Types in This Project

```
certs/client/testuser/
├── client.key.pem      # PRIVATE KEY - never shared, used by browser
├── client.crt.pem      # PUBLIC CERTIFICATE - uploaded to API
├── client.csr.pem      # Certificate Signing Request (intermediate)
└── client.p12          # PKCS12 bundle (private key + cert for browser import)
```

The `.p12` file contains both the private key and certificate bundled together, protected by a password. This is what you import into your browser/keychain.

## Authentication Flow Code

### 1. Certificate Registration (X509CertificateResource.java)

```java
@POST
public Response addCertificate(CertificateRequest request) {
    // 1. Parse the uploaded certificate (PUBLIC cert only)
    X509Certificate cert = parseCertificate(request.getCertificate());

    // 2. Calculate fingerprint (SHA-256 hash)
    String fingerprint = calculateFingerprint(cert);

    // 3. Store in user attributes
    user.setAttribute("x509_cert_fingerprints", fingerprints);
    user.setAttribute("x509_cert_0", certPem);

    // Private key is NEVER involved here
}
```

### 2. Certificate Authentication (X509UserAttributeAuthenticator.java)

```java
@Override
public void authenticate(AuthenticationFlowContext context) {
    // 1. Get certificate from TLS handshake (via Nginx header)
    X509Certificate[] certs = getCertificateChain(context);

    // 2. Calculate fingerprint of presented certificate
    String fingerprint = calculateFingerprint(certs[0]);

    // 3. Search for user with matching fingerprint
    UserModel user = findUserByFingerprint(fingerprint);

    // 4. Email fallback: if no user found and cert is CA-signed
    if (user == null && isEmailFallbackEnabled()) {
        if (isCertificateSignedByTrustedCA(clientCert)) {
            String email = extractEmailFromCertificate(clientCert);
            user = session.users().getUserByEmail(realm, email);

            // Auto-register fingerprint for future logins
            if (user != null && isAutoRegisterEnabled()) {
                autoRegisterCertificate(user, fingerprint);
            }
        }
    }

    // 5. If found, authenticate the user
    context.setUser(user);
    context.success();

    // The TLS layer already verified the private key ownership
}
```

## Summary

1. **Registration**: User uploads PUBLIC certificate → Server stores fingerprint
2. **Authentication**: Browser proves PRIVATE key ownership via TLS → Server matches fingerprint to user
3. **Private key**: Used only during TLS handshake, never leaves user's machine
4. **Security**: Based on cryptographic proof, not shared secrets
