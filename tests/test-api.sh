#!/bin/bash

# Test Certificate Management API

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

# Get access token
get_token() {
    local username=$1
    local password=$2
    curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=$username&password=$password" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

echo "========================================"
echo "  Certificate API Tests"
echo "========================================"
echo ""

# Test 1: Get token
echo "Test 1: Authentication"
TOKEN=$(get_token "testuser" "testuser123")
if [ -n "$TOKEN" ]; then
    pass "Get access token for testuser"
else
    fail "Get access token for testuser"
    exit 1
fi

# Test 2: List certificates endpoint
echo ""
echo "Test 2: List certificates endpoint"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN")

if echo "$RESPONSE" | grep -q '"certificates"'; then
    pass "GET /certificates returns valid response"
else
    fail "GET /certificates returns valid response"
fi

# Test 3: Unauthorized access
echo ""
echo "Test 3: Unauthorized access"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates")

if echo "$RESPONSE" | grep -q '"error"'; then
    pass "Unauthorized request is rejected"
else
    fail "Unauthorized request is rejected"
fi

# Test 4: Add certificate
echo ""
echo "Test 4: Add certificate"
CERT_FILE="$PROJECT_ROOT/certs/client/testuser/client.crt.pem"
if [ -f "$CERT_FILE" ]; then
    CERT=$(cat "$CERT_FILE" | awk '{printf "%s\\n", $0}')

    # First, get current certificates to check if already added
    CURRENT=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
        -H "Authorization: Bearer $TOKEN")

    if echo "$CURRENT" | grep -q "56:B0"; then
        pass "Certificate already registered (skipping add)"
    else
        RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"certificate\": \"$CERT\", \"title\": \"Test Certificate\"}")

        if echo "$RESPONSE" | grep -q '"fingerprint"'; then
            pass "POST /certificates adds certificate"
        else
            fail "POST /certificates adds certificate"
        fi
    fi
else
    skip "Certificate file not found"
fi

# Test 5: Verify certificate
echo ""
echo "Test 5: Verify certificate"
if [ -f "$CERT_FILE" ]; then
    RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates/verify" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"certificate\": \"$CERT\"}")

    if echo "$RESPONSE" | grep -q '"valid":true'; then
        pass "POST /certificates/verify validates registered certificate"
    else
        fail "POST /certificates/verify validates registered certificate"
    fi
else
    skip "Certificate file not found"
fi

# Test 6: Invalid certificate
echo ""
echo "Test 6: Invalid certificate handling"
RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"certificate": "invalid-cert-data"}')

if echo "$RESPONSE" | grep -q '"error"'; then
    pass "Invalid certificate is rejected"
else
    fail "Invalid certificate is rejected"
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
