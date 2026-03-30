#!/bin/bash

# OpenFGA Integration Tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BASE_URL="https://localhost"
OPENFGA_URL="http://localhost:8081"
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
echo "  OpenFGA Integration Tests"
echo "========================================"
echo ""

# Test 1: OpenFGA health
echo "Test 1: OpenFGA is healthy"
RESPONSE=$(curl -s -w "%{http_code}" -o /dev/null "$OPENFGA_URL/healthz" 2>/dev/null || echo "000")
if [ "$RESPONSE" = "200" ]; then
    pass "OpenFGA is healthy"
else
    fail "OpenFGA is healthy (got $RESPONSE)"
fi

# Test 2: OpenFGA store exists
echo ""
echo "Test 2: OpenFGA store exists"
STORES=$(curl -s "$OPENFGA_URL/stores" 2>/dev/null)
if echo "$STORES" | grep -q '"demo"'; then
    pass "OpenFGA store 'demo' exists"
else
    fail "OpenFGA store 'demo' exists"
fi

# Test 3: Get access token for testuser
echo ""
echo "Test 3: Authenticate as testuser"
TOKEN_RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
    -d "grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=testuser&password=testuser123")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
if [ -n "$ACCESS_TOKEN" ]; then
    pass "Got access token for testuser"
else
    fail "Got access token for testuser"
    echo "Cannot continue without token"
    exit 1
fi

# Test 4: Workspace with access returns 200
echo ""
echo "Test 4: GET /api/workspaces/acme returns 200 (testuser is owner)"
RESPONSE=$(curl -sk -w "%{http_code}" -o /tmp/openfga-test-body.txt "$BASE_URL/api/workspaces/acme" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
if [ "$RESPONSE" = "200" ]; then
    pass "Workspace acme accessible (200)"
else
    fail "Workspace acme accessible (got $RESPONSE)"
    cat /tmp/openfga-test-body.txt 2>/dev/null
fi

# Test 5: Workspace without access returns 403
echo ""
echo "Test 5: GET /api/workspaces/unknown returns 403"
RESPONSE=$(curl -sk -w "%{http_code}" -o /tmp/openfga-test-body.txt "$BASE_URL/api/workspaces/unknown" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
if [ "$RESPONSE" = "403" ]; then
    pass "Workspace unknown blocked (403)"
else
    fail "Workspace unknown blocked (got $RESPONSE)"
    cat /tmp/openfga-test-body.txt 2>/dev/null
fi

# Test 6: Document with access returns 200
echo ""
echo "Test 6: GET /api/workspaces/acme/documents/doc1 returns 200"
RESPONSE=$(curl -sk -w "%{http_code}" -o /tmp/openfga-test-body.txt "$BASE_URL/api/workspaces/acme/documents/doc1" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
if [ "$RESPONSE" = "200" ]; then
    pass "Document doc1 accessible (200)"
else
    fail "Document doc1 accessible (got $RESPONSE)"
    cat /tmp/openfga-test-body.txt 2>/dev/null
fi

# Test 7: Workspace admin settings returns 200 (owner > admin)
echo ""
echo "Test 7: POST /api/workspaces/acme/settings returns 200 (owner has admin)"
RESPONSE=$(curl -sk -w "%{http_code}" -o /tmp/openfga-test-body.txt -X POST "$BASE_URL/api/workspaces/acme/settings" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name":"Acme Corp"}')
if [ "$RESPONSE" = "200" ]; then
    pass "Workspace settings accessible (200)"
else
    fail "Workspace settings accessible (got $RESPONSE)"
    cat /tmp/openfga-test-body.txt 2>/dev/null
fi

# Cleanup
rm -f /tmp/openfga-test-body.txt

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
