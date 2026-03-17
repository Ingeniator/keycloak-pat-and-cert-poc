#!/bin/bash

# Test Personal Access Tokens API

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

BASE_URL="https://localhost"
REALM="public"

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

# Get access token via password grant
get_token() {
    local username=$1
    local password=$2
    curl -sk -X POST "$BASE_URL/realms/$REALM/protocol/openid-connect/token" \
        -d "grant_type=password&client_id=ui-bff&client_secret=bff-secret&username=$username&password=$password" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

echo "========================================"
echo "  Personal Access Token Tests"
echo "========================================"
echo ""

# Test 1: Get token for PAT API auth
echo "Test 1: Authenticate as testuser"
TOKEN=$(get_token "testuser" "testuser123")
if [ -n "$TOKEN" ]; then
    pass "Get access token for testuser"
else
    fail "Get access token for testuser"
    echo "Cannot continue without token"
    exit 1
fi

# Test 2: PAT API provider available
echo ""
echo "Test 2: PAT API provider available"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/pat-api/tokens" \
    -H "Authorization: Bearer $TOKEN")
if echo "$RESPONSE" | grep -q '"tokens"'; then
    pass "GET /pat-api/tokens returns valid response"
else
    fail "GET /pat-api/tokens returns valid response"
    echo "  Response: $RESPONSE"
fi

# Test 3: Unauthorized access rejected
echo ""
echo "Test 3: Unauthorized access rejected"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/pat-api/tokens")
if echo "$RESPONSE" | grep -q '"error"'; then
    pass "Unauthorized request is rejected"
else
    fail "Unauthorized request is rejected"
fi

# Test 4: Create a PAT
echo ""
echo "Test 4: Create a personal access token"
RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/pat-api/tokens" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name": "Test Token", "expiresInDays": 90}')

PAT_TOKEN=$(echo "$RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
PAT_ID=$(echo "$RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

if [ -n "$PAT_TOKEN" ] && echo "$PAT_TOKEN" | grep -q "^pat_"; then
    pass "Create PAT returns token with pat_ prefix"
else
    fail "Create PAT returns token with pat_ prefix"
    echo "  Response: $RESPONSE"
fi

# Test 5: Token appears in list
echo ""
echo "Test 5: Token appears in list"
RESPONSE=$(curl -sk "$BASE_URL/realms/$REALM/pat-api/tokens" \
    -H "Authorization: Bearer $TOKEN")

if echo "$RESPONSE" | grep -q '"Test Token"'; then
    pass "Created token appears in list"
else
    fail "Created token appears in list"
fi

# Test 6: Use PAT to access backend API
echo ""
echo "Test 6: Use PAT to access backend API"
if [ -n "$PAT_TOKEN" ]; then
    RESPONSE=$(curl -sk "$BASE_URL/api/hello" \
        -H "Authorization: Bearer $PAT_TOKEN")

    if echo "$RESPONSE" | grep -q "testuser"; then
        pass "PAT authenticates to backend API"
    else
        fail "PAT authenticates to backend API"
        echo "  Response: $RESPONSE"
    fi
else
    skip "No PAT token available"
fi

# Test 7: Invalid PAT rejected
echo ""
echo "Test 7: Invalid PAT rejected"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/api/hello" \
    -H "Authorization: Bearer pat_invalidtoken123")

if [ "$HTTP_CODE" = "401" ]; then
    pass "Invalid PAT returns 401"
else
    fail "Invalid PAT returns 401 (got $HTTP_CODE)"
fi

# Test 8: Missing name rejected
echo ""
echo "Test 8: Missing name rejected"
RESPONSE=$(curl -sk -X POST "$BASE_URL/realms/$REALM/pat-api/tokens" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"name": ""}')

if echo "$RESPONSE" | grep -q '"error"'; then
    pass "Empty name is rejected"
else
    fail "Empty name is rejected"
fi

# Test 9: Delete PAT
echo ""
echo "Test 9: Delete PAT"
if [ -n "$PAT_ID" ]; then
    RESPONSE=$(curl -sk -X DELETE "$BASE_URL/realms/$REALM/pat-api/tokens/$PAT_ID" \
        -H "Authorization: Bearer $TOKEN")

    if echo "$RESPONSE" | grep -q '"message"'; then
        pass "Delete PAT succeeds"
    else
        fail "Delete PAT succeeds"
        echo "  Response: $RESPONSE"
    fi
else
    skip "No PAT ID available"
fi

# Test 10: Deleted PAT no longer works
echo ""
echo "Test 10: Deleted PAT no longer works"
if [ -n "$PAT_TOKEN" ]; then
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/api/hello" \
        -H "Authorization: Bearer $PAT_TOKEN")

    if [ "$HTTP_CODE" = "401" ]; then
        pass "Deleted PAT returns 401"
    else
        fail "Deleted PAT returns 401 (got $HTTP_CODE)"
    fi
else
    skip "No PAT token available"
fi

# Test 11: Exchange endpoint blocked from public access
echo ""
echo "Test 11: Exchange endpoint blocked from public access"
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
    "$BASE_URL/realms/$REALM/pat-api/tokens/exchange" \
    -H "Content-Type: application/json" \
    -d '{"token": "pat_test"}')

if [ "$HTTP_CODE" = "403" ]; then
    pass "Exchange endpoint blocked from public access"
else
    fail "Exchange endpoint blocked from public access (got $HTTP_CODE)"
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
