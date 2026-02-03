#!/bin/bash

# Test X.509 certificate authentication with curl

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BASE_URL="https://localhost"
REALM="x509-demo"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

USERNAME="${1:-testuser}"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     X.509 Certificate Authentication Test                  ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check if certificate files exist
CERT_DIR="$PROJECT_ROOT/certs/client/$USERNAME"
CA_CERT="$PROJECT_ROOT/certs/ca/ca.crt.pem"
CLIENT_CERT="$CERT_DIR/client.crt.pem"
CLIENT_KEY="$CERT_DIR/client.key.pem"

if [ ! -f "$CLIENT_CERT" ] || [ ! -f "$CLIENT_KEY" ]; then
    log_error "Certificate files not found for user: $USERNAME"
    log_warn "Run ./scripts/generate-certs.sh first"
    exit 1
fi

log_info "Testing certificate authentication for: $USERNAME"
echo ""

# Test 1: Simple HTTPS connection with client certificate
log_info "Test 1: Connecting to Keycloak with client certificate..."

RESPONSE=$(curl -sk -w "\n%{http_code}" \
    --cert "$CLIENT_CERT" \
    --key "$CLIENT_KEY" \
    --cacert "$CA_CERT" \
    "$BASE_URL/realms/$REALM/.well-known/openid-configuration")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    log_info "Connection successful (HTTP $HTTP_CODE)"
else
    log_error "Connection failed (HTTP $HTTP_CODE)"
fi

echo ""

# Test 2: Access account page with certificate
log_info "Test 2: Accessing account page with certificate..."

RESPONSE=$(curl -sk -L -w "\n%{http_code}" \
    --cert "$CLIENT_CERT" \
    --key "$CLIENT_KEY" \
    --cacert "$CA_CERT" \
    "$BASE_URL/realms/$REALM/account")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" = "200" ]; then
    log_info "Account page accessible (HTTP $HTTP_CODE)"
else
    log_warn "Account page response (HTTP $HTTP_CODE) - may require interactive login"
fi

echo ""

# Test 3: Get token using certificate authentication (if supported)
log_info "Test 3: Attempting token request with certificate..."

TOKEN_RESPONSE=$(curl -sk \
    --cert "$CLIENT_CERT" \
    --key "$CLIENT_KEY" \
    --cacert "$CA_CERT" \
    -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=x509-demo-app" \
    -d "client_secret=demo-app-secret" \
    -d "username=testuser" \
    -d "password=testuser123")

if echo "$TOKEN_RESPONSE" | grep -q "access_token"; then
    log_info "Token obtained successfully!"
    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
    echo "Token (first 50 chars): ${ACCESS_TOKEN:0:50}..."
else
    log_warn "Token request may require additional configuration"
    echo "$TOKEN_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$TOKEN_RESPONSE"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Test Summary                            ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "For browser-based testing:"
echo ""
echo "1. Import the client certificate into your browser:"
echo "   File: $CERT_DIR/client.p12"
echo "   Password: changeit"
echo ""
echo "2. Import the CA certificate as a trusted authority:"
echo "   File: $CA_CERT"
echo ""
echo "3. Visit: $BASE_URL/realms/$REALM/account"
echo "   The browser should prompt you to select a certificate"
echo ""
echo "4. After selecting the certificate, you should be authenticated"
echo "   as the user whose certificate fingerprint matches"
echo ""
