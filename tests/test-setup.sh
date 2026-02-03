#!/bin/bash

# Test setup - ensures certificates are registered before running other tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BASE_URL="https://localhost"
REALM="x509-demo"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================"
echo "  Test Setup - Register Certificates"
echo "========================================"
echo ""

# Get access token for testuser
get_token() {
    local username=$1
    local password=$2
    curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=$username&password=$password" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

# Register certificate for user
register_cert() {
    local username=$1
    local password=$2
    local cert_file="$PROJECT_ROOT/certs/client/$username/client.crt.pem"

    if [ ! -f "$cert_file" ]; then
        echo -e "${YELLOW}[SKIP]${NC} Certificate file not found for $username"
        return 0
    fi

    local token=$(get_token "$username" "$password")
    if [ -z "$token" ]; then
        echo -e "${RED}[ERROR]${NC} Failed to get token for $username"
        return 1
    fi

    # Check if certificate already registered
    local existing=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
        -H "Authorization: Bearer $token" | grep -o '"count":[0-9]*' | cut -d: -f2)

    if [ "$existing" != "0" ] && [ -n "$existing" ]; then
        echo -e "${GREEN}[OK]${NC} Certificate already registered for $username"
        return 0
    fi

    # Register certificate
    local cert=$(cat "$cert_file" | awk '{printf "%s\\n", $0}')
    local response=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"certificate\": \"$cert\", \"title\": \"$username certificate\"}")

    if echo "$response" | grep -q '"fingerprint"'; then
        echo -e "${GREEN}[OK]${NC} Certificate registered for $username"
        return 0
    else
        echo -e "${RED}[ERROR]${NC} Failed to register certificate for $username: $response"
        return 1
    fi
}

# Register certificates for test users
echo "Registering certificate for testuser..."
register_cert "testuser" "testuser123"

echo ""
echo "Setup complete."
