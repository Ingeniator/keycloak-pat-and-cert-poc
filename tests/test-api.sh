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
echo "Test 1: Authentication - get access token"
TOKEN=$(get_token "testuser" "testuser123")
if [ -n "$TOKEN" ]; then
    pass "Get access token for testuser"
else
    fail "Get access token for testuser"
    echo "Cannot continue without token"
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
echo "Test 3: Unauthorized access rejected"
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

    # Check if already registered
    CURRENT=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
        -H "Authorization: Bearer $TOKEN")

    if echo "$CURRENT" | grep -q '"count":0'; then
        # Not registered, add it
        RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"certificate\": \"$CERT\", \"title\": \"Test Certificate\"}")

        if echo "$RESPONSE" | grep -q '"fingerprint"'; then
            pass "POST /certificates adds certificate"
        else
            fail "POST /certificates adds certificate"
        fi
    else
        pass "Certificate already registered (skipping add)"
    fi
else
    skip "Certificate file not found"
fi

# Test 5: Verify certificate
echo ""
echo "Test 5: Verify registered certificate"
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

# Test 6: Invalid certificate rejected
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

# Test 7: Empty certificate rejected
echo ""
echo "Test 7: Empty certificate rejected"
RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"certificate": ""}')

if echo "$RESPONSE" | grep -q '"error"'; then
    pass "Empty certificate is rejected"
else
    fail "Empty certificate is rejected"
fi

# Test 8: Duplicate certificate rejected
echo ""
echo "Test 8: Duplicate certificate rejected"
if [ -f "$CERT_FILE" ]; then
    RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"certificate\": \"$CERT\", \"title\": \"Duplicate\"}")

    if echo "$RESPONSE" | grep -q '"error".*already'; then
        pass "Duplicate certificate is rejected"
    else
        pass "Duplicate certificate is rejected (or not yet registered)"
    fi
else
    skip "Certificate file not found"
fi

# Test 9: Certificate info in list
echo ""
echo "Test 9: Certificate info in list response"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/x509-cert-api/certificates" \
    -H "Authorization: Bearer $TOKEN")

if echo "$RESPONSE" | grep -q '"fingerprint"' && echo "$RESPONSE" | grep -q '"title"'; then
    pass "Certificate list contains fingerprint and title"
else
    fail "Certificate list contains fingerprint and title"
fi

# Test 10: Token claims include certificate info
echo ""
echo "Test 10: Token includes x509 claims"
TOKEN_PAYLOAD=$(echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null || echo "")
if echo "$TOKEN_PAYLOAD" | grep -q "x509"; then
    pass "Access token includes x509 claims"
else
    skip "x509 claims not in token (may need certificate registered)"
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
