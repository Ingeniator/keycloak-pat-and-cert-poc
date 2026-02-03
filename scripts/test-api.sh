#!/bin/bash

# Test script for X.509 Certificate API

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BASE_URL="https://localhost"
REALM="x509-demo"
API_URL="$BASE_URL/realms/$REALM/x509-cert-api"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default credentials
USERNAME="${1:-testuser}"
PASSWORD="${2:-testuser123}"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║          X.509 Certificate API Test Script                 ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Get access token
log_info "Step 1: Obtaining access token for $USERNAME..."

TOKEN_RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=x509-demo-app" \
    -d "client_secret=demo-app-secret" \
    -d "username=$USERNAME" \
    -d "password=$PASSWORD")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -z "$ACCESS_TOKEN" ]; then
    log_error "Failed to get access token!"
    echo "$TOKEN_RESPONSE"
    exit 1
fi

log_info "Access token obtained successfully!"
echo ""

# Step 2: List current certificates
log_info "Step 2: Listing current certificates..."

curl -sk -X GET "$API_URL/certificates" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Accept: application/json" | python3 -m json.tool 2>/dev/null || cat

echo ""

# Step 3: Add a certificate
log_info "Step 3: Adding a certificate..."

CERT_FILE="$PROJECT_ROOT/certs/client/$USERNAME/client.crt.pem"
if [ -f "$CERT_FILE" ]; then
    CERT_CONTENT=$(cat "$CERT_FILE" | sed ':a;N;$!ba;s/\n/\\n/g')

    ADD_RESPONSE=$(curl -sk -X POST "$API_URL/certificates" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"certificate\": \"$CERT_CONTENT\", \"title\": \"My Test Certificate\"}")

    echo "$ADD_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$ADD_RESPONSE"
else
    log_warn "Certificate file not found: $CERT_FILE"
    log_warn "Generate certificates first with: ./scripts/generate-certs.sh"
fi

echo ""

# Step 4: List certificates again
log_info "Step 4: Listing certificates after addition..."

curl -sk -X GET "$API_URL/certificates" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Accept: application/json" | python3 -m json.tool 2>/dev/null || cat

echo ""

# Step 5: Verify certificate
log_info "Step 5: Verifying certificate..."

if [ -f "$CERT_FILE" ]; then
    VERIFY_RESPONSE=$(curl -sk -X POST "$API_URL/certificates/verify" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"certificate\": \"$CERT_CONTENT\"}")

    echo "$VERIFY_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$VERIFY_RESPONSE"
fi

echo ""
log_info "API test completed!"
echo ""
echo "To test certificate-based authentication:"
echo "  1. Import $PROJECT_ROOT/certs/client/$USERNAME/client.p12 into your browser"
echo "  2. Import $PROJECT_ROOT/certs/ca/ca.crt.pem as a trusted CA"
echo "  3. Visit https://localhost/realms/x509-demo/account"
echo ""
