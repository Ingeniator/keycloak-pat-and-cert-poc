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
| Uploads public key to GitHub | Uploads public certificate to API |
| GitHub stores public key | Keycloak stores cert fingerprint |
| SSH client uses private key | Browser uses private key (TLS) |
| Server verifies signature | Nginx verifies signature |

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

    // 4. If found, authenticate the user
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
