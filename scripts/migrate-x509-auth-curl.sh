#!/bin/bash
#
# Migration script using curl to add X.509 certificate authentication
# to an existing Keycloak realm via REST API
#
# Usage:
#   ./migrate-x509-auth-curl.sh <realm-name> [keycloak-url] [admin-user] [admin-password]
#
# Example:
#   ./migrate-x509-auth-curl.sh my-realm https://keycloak.example.com admin admin123
#

set -e

# Configuration
REALM="${1:?Usage: $0 <realm-name> [keycloak-url] [admin-user] [admin-password]}"
KEYCLOAK_URL="${2:-http://localhost:8080}"
ADMIN_USER="${3:-admin}"
ADMIN_PASSWORD="${4:-admin}"

echo "=== X.509 Certificate Authentication Migration (curl) ==="
echo "Realm: $REALM"
echo "Keycloak URL: $KEYCLOAK_URL"
echo ""

# Get access token
echo "1. Getting admin access token..."
TOKEN_RESPONSE=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

if [ -z "$ACCESS_TOKEN" ]; then
    echo "Error: Failed to get access token"
    echo "$TOKEN_RESPONSE"
    exit 1
fi
echo "   Token obtained."

# Helper function for API calls
api_call() {
    local method="$1"
    local endpoint="$2"
    local data="$3"

    if [ -n "$data" ]; then
        curl -s -X "$method" "$KEYCLOAK_URL/admin/realms/$REALM$endpoint" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "$KEYCLOAK_URL/admin/realms/$REALM$endpoint" \
            -H "Authorization: Bearer $ACCESS_TOKEN"
    fi
}

# Check if realm exists
echo "2. Checking if realm '$REALM' exists..."
REALM_CHECK=$(curl -s -o /dev/null -w "%{http_code}" "$KEYCLOAK_URL/admin/realms/$REALM" \
    -H "Authorization: Bearer $ACCESS_TOKEN")

if [ "$REALM_CHECK" != "200" ]; then
    echo "Error: Realm '$REALM' not found (HTTP $REALM_CHECK)"
    exit 1
fi
echo "   Realm found."

# Create x509-browser-forms subflow
echo "3. Creating 'x509-browser-forms' subflow..."
SUBFLOW_RESPONSE=$(api_call POST "/authentication/flows" '{
    "alias": "x509-browser-forms",
    "description": "Username, password, and X.509 certificate form",
    "providerId": "basic-flow",
    "topLevel": false,
    "builtIn": false
}')

if echo "$SUBFLOW_RESPONSE" | grep -q "already exists"; then
    echo "   Subflow already exists, skipping..."
else
    echo "   Created subflow."
fi

# Get subflow ID
SUBFLOW_ID=$(api_call GET "/authentication/flows" | grep -o '"id":"[^"]*","alias":"x509-browser-forms"' | cut -d'"' -f4)
echo "   Subflow ID: $SUBFLOW_ID"

# Add X.509 User Attribute Authenticator to subflow
echo "4. Adding authenticators to subflow..."

echo "   - Adding X.509 User Attribute Authenticator..."
api_call POST "/authentication/flows/x509-browser-forms/executions/execution" \
    '{"provider": "x509-user-attribute-authenticator"}' > /dev/null 2>&1 || true

echo "   - Adding Username Password Form..."
api_call POST "/authentication/flows/x509-browser-forms/executions/execution" \
    '{"provider": "auth-username-password-form"}' > /dev/null 2>&1 || true

# Set executions to ALTERNATIVE
echo "5. Configuring execution requirements..."
EXECUTIONS=$(api_call GET "/authentication/flows/x509-browser-forms/executions")

for EXEC_ID in $(echo "$EXECUTIONS" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); do
    api_call PUT "/authentication/flows/x509-browser-forms/executions" \
        "{\"id\":\"$EXEC_ID\",\"requirement\":\"ALTERNATIVE\"}" > /dev/null 2>&1 || true
done
echo "   Set all to ALTERNATIVE."

# Create main x509-browser-flow
echo "6. Creating 'x509-browser-flow' main flow..."
MAIN_FLOW_RESPONSE=$(api_call POST "/authentication/flows" '{
    "alias": "x509-browser-flow",
    "description": "Browser flow with X.509 certificate support",
    "providerId": "basic-flow",
    "topLevel": true,
    "builtIn": false
}')

if echo "$MAIN_FLOW_RESPONSE" | grep -q "already exists"; then
    echo "   Flow already exists, skipping..."
else
    echo "   Created flow."
fi

# Add executions to main flow
echo "7. Adding authenticators to main flow..."

echo "   - Adding Cookie authenticator..."
api_call POST "/authentication/flows/x509-browser-flow/executions/execution" \
    '{"provider": "auth-cookie"}' > /dev/null 2>&1 || true

echo "   - Adding Identity Provider Redirector..."
api_call POST "/authentication/flows/x509-browser-flow/executions/execution" \
    '{"provider": "identity-provider-redirector"}' > /dev/null 2>&1 || true

echo "   - Adding x509-browser-forms subflow reference..."
api_call POST "/authentication/flows/x509-browser-flow/executions/flow" \
    '{"alias": "x509-browser-forms-ref", "provider": "registration-page-form", "type": "basic-flow"}' > /dev/null 2>&1 || true

# Set main flow executions to ALTERNATIVE
echo "8. Configuring main flow requirements..."
MAIN_EXECUTIONS=$(api_call GET "/authentication/flows/x509-browser-flow/executions")

for EXEC_ID in $(echo "$MAIN_EXECUTIONS" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); do
    api_call PUT "/authentication/flows/x509-browser-flow/executions" \
        "{\"id\":\"$EXEC_ID\",\"requirement\":\"ALTERNATIVE\"}" > /dev/null 2>&1 || true
done
echo "   Set all to ALTERNATIVE."

# Create authenticator config
echo "9. Creating authenticator configuration..."
# First, find the x509-user-attribute-authenticator execution ID
X509_EXEC_ID=$(echo "$EXECUTIONS" | grep -o '"id":"[^"]*".*"providerId":"x509-user-attribute-authenticator"' | head -1 | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

if [ -n "$X509_EXEC_ID" ]; then
    api_call POST "/authentication/executions/$X509_EXEC_ID/config" '{
        "alias": "x509-fingerprint-config",
        "config": {
            "emailFallbackEnabled": "true",
            "autoRegisterCertOnEmailMatch": "true"
        }
    }' > /dev/null 2>&1 || echo "   (config may already exist)"
    echo "   Configuration created."
else
    echo "   Warning: Could not find x509-user-attribute-authenticator execution"
fi

echo ""
echo "=== Migration Complete ==="
echo ""
echo "To bind x509-browser-flow as the browser flow:"
echo ""
echo "  curl -X PUT '$KEYCLOAK_URL/admin/realms/$REALM' \\"
echo "    -H 'Authorization: Bearer <token>' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"browserFlow\": \"x509-browser-flow\"}'"
echo ""

read -p "Bind x509-browser-flow as the browser flow now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Binding x509-browser-flow..."
    curl -s -X PUT "$KEYCLOAK_URL/admin/realms/$REALM" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"browserFlow": "x509-browser-flow"}'
    echo "Done! x509-browser-flow is now the default browser flow."
fi
