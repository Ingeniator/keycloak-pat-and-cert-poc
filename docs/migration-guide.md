# Migration Guide: Adding X.509 Certificate Authentication to Existing Keycloak

This guide explains how to add X.509 certificate authentication to an existing Keycloak realm that already has users and clients.

## Prerequisites

1. Keycloak 24.0+ running
2. Admin access to Keycloak
3. The custom provider JAR deployed

## Step 1: Deploy the Provider JAR

Copy the provider JAR to Keycloak's providers directory:

```bash
# Build the provider
cd keycloak/providers/x509-cert-api
mvn clean package -DskipTests

# Copy to Keycloak
cp target/x509-cert-api.jar /path/to/keycloak/providers/

# Restart Keycloak
# Docker: docker compose restart keycloak
# Standalone: ./bin/kc.sh build && ./bin/kc.sh start
```

## Step 2: Configure Environment Variable (Optional)

If you want email fallback authentication (authenticate by email in certificate), set the trusted CA path:

```bash
# Add to your Keycloak environment
X509_TRUSTED_CA_CERT_PATH=/opt/keycloak/conf/trusted-ca.pem
```

For Docker Compose:
```yaml
services:
  keycloak:
    environment:
      X509_TRUSTED_CA_CERT_PATH: /opt/keycloak/certs/ca/ca.crt.pem
    volumes:
      - ./certs/ca/ca.crt.pem:/opt/keycloak/certs/ca/ca.crt.pem:ro
```

## Step 3: Create Authentication Flow

### Option A: Using Migration Script (Recommended)

```bash
# Using kcadm.sh (Keycloak Admin CLI)
./scripts/migrate-x509-auth.sh my-realm https://keycloak.example.com admin password

# OR using curl (no dependencies)
./scripts/migrate-x509-auth-curl.sh my-realm https://keycloak.example.com admin password
```

### Option B: Using Partial Realm Import

1. Go to **Realm Settings** → **Action** → **Partial Import**
2. Upload `scripts/x509-auth-patch.json`
3. Select "Skip" or "Overwrite" for existing resources
4. Click **Import**

### Option C: Manual Setup via Admin Console

1. Go to **Authentication** → **Flows**
2. Click **Create flow**:
   - Name: `x509-browser-forms`
   - Type: `basic-flow`
   - Top level: No
3. Add executions to `x509-browser-forms`:
   - `X.509/Certificate User Attribute` (ALTERNATIVE)
   - `Username Password Form` (ALTERNATIVE)
4. Create another flow:
   - Name: `x509-browser-flow`
   - Type: `basic-flow`
   - Top level: Yes
5. Add executions to `x509-browser-flow`:
   - `Cookie` (ALTERNATIVE)
   - `Identity Provider Redirector` (ALTERNATIVE)
   - `x509-browser-forms` subflow (ALTERNATIVE)

### Option D: Using REST API Directly

```bash
# Get admin token
TOKEN=$(curl -s -X POST 'https://keycloak.example.com/realms/master/protocol/openid-connect/token' \
    -d 'username=admin&password=admin&grant_type=password&client_id=admin-cli' \
    | jq -r '.access_token')

# Create subflow
curl -X POST 'https://keycloak.example.com/admin/realms/my-realm/authentication/flows' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{
        "alias": "x509-browser-forms",
        "description": "X.509 certificate and password form",
        "providerId": "basic-flow",
        "topLevel": false,
        "builtIn": false
    }'

# Add X.509 authenticator to subflow
curl -X POST 'https://keycloak.example.com/admin/realms/my-realm/authentication/flows/x509-browser-forms/executions/execution' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"provider": "x509-user-attribute-authenticator"}'

# ... (see migrate-x509-auth-curl.sh for complete example)
```

## Step 4: Bind the Authentication Flow

### Via Admin Console
1. Go to **Authentication** → **Flows**
2. Select `x509-browser-flow`
3. Click **Action** → **Bind flow**
4. Select **Browser flow**

### Via Script
The migration scripts prompt to bind automatically, or run:

```bash
# Using kcadm.sh
kcadm.sh update realms/my-realm -s browserFlow=x509-browser-flow

# Using curl
curl -X PUT 'https://keycloak.example.com/admin/realms/my-realm' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"browserFlow": "x509-browser-flow"}'
```

## Step 5: Configure Authenticator (Optional)

To configure email fallback settings:

1. Go to **Authentication** → **Flows** → `x509-browser-forms`
2. Click the gear icon on `X.509/Certificate User Attribute`
3. Configure:
   - **Enable Email Fallback**: `true` (default)
   - **Auto-register Certificate on Email Match**: `true` (default)
   - **Trusted CA Certificate(s)**: (optional, if not using env var)

## Step 6: Configure Nginx/Proxy

Ensure your reverse proxy passes client certificates to Keycloak:

```nginx
server {
    listen 443 ssl;

    # Client certificate settings
    ssl_verify_client optional_no_ca;  # Accept self-signed and CA-signed
    ssl_client_certificate /etc/nginx/ca/ca.crt.pem;  # For CA verification

    location / {
        proxy_pass http://keycloak:8080;

        # Pass certificate to Keycloak
        proxy_set_header SSL_CLIENT_CERT $ssl_client_cert;
        proxy_set_header SSL_CLIENT_CERT_CHAIN_0 $ssl_client_cert;
    }
}
```

## Verification

### Test Password Login
1. Navigate to your application
2. Login with username/password
3. Should work as before

### Test Certificate Login
1. Generate a test certificate:
   ```bash
   openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 \
       -subj "/CN=testuser/emailAddress=testuser@example.com" -nodes
   openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem
   ```

2. Import `cert.p12` into your browser

3. Register the certificate via API:
   ```bash
   # Get access token
   TOKEN=$(curl -s -X POST 'https://keycloak.example.com/realms/my-realm/protocol/openid-connect/token' \
       -d 'username=testuser&password=testpass&grant_type=password&client_id=my-client' \
       | jq -r '.access_token')

   # Register certificate
   curl -X POST 'https://keycloak.example.com/realms/my-realm/x509-cert-api/certificates' \
       -H "Authorization: Bearer $TOKEN" \
       -H 'Content-Type: application/json' \
       -d "{\"certificate\": \"$(cat cert.pem)\"}"
   ```

4. Clear cookies and navigate to your application
5. Browser should prompt for certificate selection
6. Select your certificate - should log in without password

### Test Email Fallback (if CA configured)
1. Create a CA-signed certificate with matching email
2. Don't register it via API
3. Login with the certificate - should match by email

## Rollback

To revert to the original browser flow:

```bash
# Using kcadm.sh
kcadm.sh update realms/my-realm -s browserFlow=browser

# Using curl
curl -X PUT 'https://keycloak.example.com/admin/realms/my-realm' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"browserFlow": "browser"}'
```

## Troubleshooting

### Certificate not being passed to Keycloak
- Check Nginx logs for SSL errors
- Verify `ssl_verify_client` is set correctly
- Check Keycloak logs for `X509ClientCertificateLookup` messages

### "Provider not found" error
- Ensure JAR is in providers directory
- Restart Keycloak after adding JAR
- Check `./bin/kc.sh build` output for errors

### Email fallback not working
- Verify `X509_TRUSTED_CA_CERT_PATH` is set
- Check certificate has email in SAN or Subject DN
- Verify user exists with matching email in Keycloak

### View Keycloak logs
```bash
# Docker
docker logs keycloak 2>&1 | grep -i x509

# Standalone
tail -f /path/to/keycloak/logs/keycloak.log | grep -i x509
```
