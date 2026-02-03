#!/bin/bash

# Test Infrastructure Health

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
echo "  Infrastructure Health Tests"
echo "========================================"
echo ""

# Test 1: Keycloak is accessible
echo "Test 1: Keycloak is accessible"
RESPONSE=$(curl -sk -w "%{http_code}" -o /dev/null "$BASE_URL/realms/$REALM/")
if [ "$RESPONSE" = "200" ]; then
    pass "Keycloak realm is accessible"
else
    fail "Keycloak realm is accessible (got $RESPONSE)"
fi

# Test 2: Keycloak realm exists
echo ""
echo "Test 2: Keycloak realm configuration"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/.well-known/openid-configuration")
if echo "$RESPONSE" | grep -q '"issuer"'; then
    pass "Realm $REALM is configured"
else
    fail "Realm $REALM is configured"
fi

# Test 3: OIDC endpoints available
echo ""
echo "Test 3: OIDC endpoints available"
if echo "$RESPONSE" | grep -q '"token_endpoint"' && echo "$RESPONSE" | grep -q '"authorization_endpoint"'; then
    pass "OIDC endpoints are available"
else
    fail "OIDC endpoints are available"
fi

# Test 4: Nginx SSL termination
echo ""
echo "Test 4: Nginx SSL termination"
RESPONSE=$(curl -sk -I "$BASE_URL/realms/$REALM" 2>&1 | head -1)
if echo "$RESPONSE" | grep -q "HTTP/"; then
    pass "Nginx SSL termination working"
else
    fail "Nginx SSL termination working"
fi

# Test 5: Custom provider loaded
echo ""
echo "Test 5: Custom X509 API provider loaded"
RESPONSE=$(curl -sk -w "%{http_code}" -o /dev/null "$BASE_URL/realms/$REALM/x509-cert-api/certificates")
if [ "$RESPONSE" = "401" ] || [ "$RESPONSE" = "200" ]; then
    pass "X509 API endpoint exists (got $RESPONSE as expected)"
else
    fail "X509 API endpoint exists (got $RESPONSE)"
fi

# Test 6: Database connectivity (via Keycloak token request)
echo ""
echo "Test 6: Database connectivity"
# If we can get a token, database is working
DB_CHECK=$(curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=testuser&password=testuser123" 2>&1)
if echo "$DB_CHECK" | grep -q '"access_token"'; then
    pass "Database connectivity (token request successful)"
else
    fail "Database connectivity (token request failed)"
fi

# Test 7: Client configured
echo ""
echo "Test 7: OAuth client configured"
TOKEN_RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=testuser&password=testuser123" 2>&1)

if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
    pass "OAuth client x509-demo-app configured correctly"
else
    fail "OAuth client x509-demo-app configured correctly"
fi

# Test 8: User exists
echo ""
echo "Test 8: Test user exists"
if echo "$TOKEN_RESPONSE" | grep -q '"access_token"'; then
    pass "Test user 'testuser' exists and can authenticate"
else
    fail "Test user 'testuser' exists and can authenticate"
fi

# Test 9: X.509 browser flow configured
echo ""
echo "Test 9: X.509 browser flow exists"
ADMIN_TOKEN=$(curl -sk -X POST "$BASE_URL/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" 2>/dev/null \
    | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

if [ -n "$ADMIN_TOKEN" ]; then
    FLOWS=$(curl -sk "$BASE_URL/admin/realms/$REALM/authentication/flows" \
        -H "Authorization: Bearer $ADMIN_TOKEN")

    if echo "$FLOWS" | grep -q 'x509-browser'; then
        pass "X.509 browser authentication flow exists"
    else
        fail "X.509 browser authentication flow exists"
    fi
else
    skip "Could not get admin token to verify flows"
fi

# Test 10: Certificate files exist
echo ""
echo "Test 10: Certificate files exist"
CERT_FILE="$PROJECT_ROOT/certs/client/testuser/client.crt.pem"
KEY_FILE="$PROJECT_ROOT/certs/client/testuser/client.key.pem"
CA_FILE="$PROJECT_ROOT/certs/ca/ca.crt.pem"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ] && [ -f "$CA_FILE" ]; then
    pass "All required certificate files exist"
else
    fail "All required certificate files exist"
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
