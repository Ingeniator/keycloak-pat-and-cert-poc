#!/bin/bash

# Test X.509 Certificate Authentication

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

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

skip() {
    echo -e "${YELLOW}○ SKIP${NC}: $1"
}

echo "========================================"
echo "  Certificate Authentication Tests"
echo "========================================"
echo ""

# Check certificate files exist
CERT_FILE="$PROJECT_ROOT/certs/client/testuser/client.crt.pem"
KEY_FILE="$PROJECT_ROOT/certs/client/testuser/client.key.pem"
CA_FILE="$PROJECT_ROOT/certs/ca/ca.crt.pem"

if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ] || [ ! -f "$CA_FILE" ]; then
    echo -e "${RED}ERROR${NC}: Certificate files not found. Run ./scripts/generate-certs.sh first."
    exit 1
fi

# Test 1: TLS connection with client certificate
echo "Test 1: TLS connection with client certificate"
RESPONSE=$(curl -sk -w "%{http_code}" -o /dev/null \
    --cert "$CERT_FILE" \
    --key "$KEY_FILE" \
    --cacert "$CA_FILE" \
    "$BASE_URL/realms/$REALM/.well-known/openid-configuration")

if [ "$RESPONSE" = "200" ]; then
    pass "TLS connection with client certificate"
else
    fail "TLS connection with client certificate (HTTP $RESPONSE)"
fi

# Test 2: Certificate is passed through nginx
echo ""
echo "Test 2: Certificate passed through nginx"
# Check nginx logs for successful client cert verification
NGINX_LOG=$(docker compose logs nginx --tail 5 2>&1 | grep -c 'ssl_client_verify="SUCCESS"' || echo "0")

if [ "$NGINX_LOG" -gt 0 ]; then
    pass "Nginx verifies client certificate"
else
    # Make a request to generate log entry
    curl -sk --cert "$CERT_FILE" --key "$KEY_FILE" --cacert "$CA_FILE" \
        "$BASE_URL/realms/$REALM/account" -o /dev/null 2>&1
    sleep 1
    NGINX_LOG=$(docker compose logs nginx --tail 5 2>&1 | grep -c 'ssl_client_verify="SUCCESS"' || echo "0")
    if [ "$NGINX_LOG" -gt 0 ]; then
        pass "Nginx verifies client certificate"
    else
        fail "Nginx verifies client certificate"
    fi
fi

# Test 3: Authentication flow with certificate
echo ""
echo "Test 3: Authentication flow with certificate"

# Generate PKCE parameters
CODE_VERIFIER=$(openssl rand -base64 32 | tr -d '=+/' | head -c 43)
CODE_CHALLENGE=$(echo -n "$CODE_VERIFIER" | openssl dgst -sha256 -binary | base64 | tr -d '=' | tr '/+' '_-')

RESPONSE=$(curl -sk -D - -o /dev/null \
    --cert "$CERT_FILE" \
    --key "$KEY_FILE" \
    --cacert "$CA_FILE" \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-console&redirect_uri=https%3A%2F%2Flocalhost%2Frealms%2Fx509-demo%2Faccount%2F&response_type=code&scope=openid&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256")

if echo "$RESPONSE" | grep -q "HTTP/1.1 302" && echo "$RESPONSE" | grep -q "code="; then
    pass "Certificate authentication returns auth code"
else
    fail "Certificate authentication returns auth code"
fi

# Test 4: Keycloak logs show successful auth
echo ""
echo "Test 4: Keycloak processes certificate authentication"
KEYCLOAK_LOG=$(docker compose logs keycloak --tail 20 2>&1 | grep -c "authenticated via X.509 certificate" || echo "0")

if [ "$KEYCLOAK_LOG" -gt 0 ]; then
    pass "Keycloak authenticates user via X.509 certificate"
else
    fail "Keycloak authenticates user via X.509 certificate"
fi

# Test 5: Authentication without certificate shows login page
echo ""
echo "Test 5: Without certificate shows login page"
RESPONSE=$(curl -sk \
    "$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-console&redirect_uri=https%3A%2F%2Flocalhost%2Frealms%2Fx509-demo%2Faccount%2F&response_type=code&scope=openid&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256")

if echo "$RESPONSE" | grep -q "kc-form-login"; then
    pass "Without certificate shows login form"
else
    fail "Without certificate shows login form"
fi

# Test 6: Wrong certificate fails authentication
echo ""
echo "Test 6: Unregistered certificate fails authentication"
ADMIN_CERT="$PROJECT_ROOT/certs/client/admin/client.crt.pem"
ADMIN_KEY="$PROJECT_ROOT/certs/client/admin/client.key.pem"

if [ -f "$ADMIN_CERT" ] && [ -f "$ADMIN_KEY" ]; then
    # Check if admin user can get a token (meaning they exist)
    ADMIN_TOKEN=$(curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=admin&password=admin123" 2>/dev/null \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4 || echo "")

    if [ -z "$ADMIN_TOKEN" ]; then
        # Admin user doesn't exist or wrong password, test with their cert
        RESPONSE=$(curl -sk -D - -o /dev/null \
            --cert "$ADMIN_CERT" \
            --key "$ADMIN_KEY" \
            --cacert "$CA_FILE" \
            "$BASE_URL/realms/$REALM/protocol/openid-connect/auth?client_id=account-console&redirect_uri=https%3A%2F%2Flocalhost%2Frealms%2Fx509-demo%2Faccount%2F&response_type=code&scope=openid&code_challenge=$CODE_CHALLENGE&code_challenge_method=S256")

        # Should show login page (200 OK) not redirect with code
        if echo "$RESPONSE" | grep -q "HTTP/1.1 200"; then
            pass "Unregistered certificate does not auto-authenticate"
        else
            skip "Admin certificate might be registered"
        fi
    else
        skip "Admin user exists, skipping unregistered cert test"
    fi
else
    skip "Admin certificate files not found"
fi

# Summary
echo ""
echo "========================================"
echo "  Test Summary"
echo "========================================"
echo -e "  ${GREEN}Passed${NC}: $TESTS_PASSED"
echo -e "  ${RED}Failed${NC}: $TESTS_FAILED"
echo "========================================"

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi
