#!/bin/bash
#
# Migration script to add X.509 certificate authentication to an existing Keycloak realm
#
# Usage:
#   ./migrate-x509-auth.sh <realm-name> [keycloak-url] [admin-user] [admin-password]
#
# Example:
#   ./migrate-x509-auth.sh my-realm https://keycloak.example.com admin admin123
#
# Prerequisites:
#   1. Keycloak Admin CLI (kcadm.sh) in PATH or KEYCLOAK_HOME set
#   2. x509-cert-api.jar deployed to Keycloak providers directory
#   3. Keycloak restarted after deploying the provider
#

set -e

# Configuration
REALM="${1:?Usage: $0 <realm-name> [keycloak-url] [admin-user] [admin-password]}"
KEYCLOAK_URL="${2:-http://localhost:8080}"
ADMIN_USER="${3:-admin}"
ADMIN_PASSWORD="${4:-admin}"

# Find kcadm.sh
if [ -n "$KEYCLOAK_HOME" ]; then
    KCADM="$KEYCLOAK_HOME/bin/kcadm.sh"
elif command -v kcadm.sh &> /dev/null; then
    KCADM="kcadm.sh"
else
    echo "Error: kcadm.sh not found. Set KEYCLOAK_HOME or add kcadm.sh to PATH"
    exit 1
fi

echo "=== X.509 Certificate Authentication Migration ==="
echo "Realm: $REALM"
echo "Keycloak URL: $KEYCLOAK_URL"
echo ""

# Authenticate
echo "1. Authenticating with Keycloak..."
$KCADM config credentials --server "$KEYCLOAK_URL" --realm master --user "$ADMIN_USER" --password "$ADMIN_PASSWORD"

# Check if realm exists
echo "2. Checking if realm '$REALM' exists..."
if ! $KCADM get realms/"$REALM" > /dev/null 2>&1; then
    echo "Error: Realm '$REALM' not found"
    exit 1
fi
echo "   Realm found."

# Check if custom authenticator is available
echo "3. Checking if X.509 User Attribute Authenticator is available..."
PROVIDERS=$($KCADM get authentication/authenticator-providers -r "$REALM" 2>/dev/null || echo "[]")
if echo "$PROVIDERS" | grep -q "x509-user-attribute-authenticator"; then
    echo "   Custom authenticator found."
else
    echo "   Warning: Custom authenticator 'x509-user-attribute-authenticator' not found."
    echo "   Make sure x509-cert-api.jar is deployed and Keycloak is restarted."
    echo "   Continuing anyway (flow will be created but may not work until provider is deployed)..."
fi

# Create the x509-browser-forms subflow
echo "4. Creating 'x509-browser-forms' subflow..."
SUBFLOW_ID=$($KCADM create authentication/flows -r "$REALM" -s alias="x509-browser-forms" -s providerId="basic-flow" -s topLevel=false -s builtIn=false -s description="Username, password, and X.509 certificate form" -i 2>/dev/null || echo "exists")

if [ "$SUBFLOW_ID" = "exists" ]; then
    echo "   Subflow already exists, skipping..."
    SUBFLOW_ID=$($KCADM get authentication/flows -r "$REALM" --fields id,alias | grep -A1 '"x509-browser-forms"' | grep '"id"' | cut -d'"' -f4)
else
    echo "   Created subflow with ID: $SUBFLOW_ID"
fi

# Add executions to subflow
echo "5. Adding authenticators to subflow..."

# Add X.509 User Attribute Authenticator (custom)
echo "   - Adding X.509 User Attribute Authenticator..."
$KCADM create authentication/flows/x509-browser-forms/executions/execution -r "$REALM" \
    -s provider="x509-user-attribute-authenticator" 2>/dev/null || echo "   (already exists or provider not available)"

# Add X.509 Client Username Form (built-in Keycloak)
echo "   - Adding X.509 Client Username Form..."
$KCADM create authentication/flows/x509-browser-forms/executions/execution -r "$REALM" \
    -s provider="auth-x509-client-username-form" 2>/dev/null || echo "   (already exists)"

# Add Username Password Form
echo "   - Adding Username Password Form..."
$KCADM create authentication/flows/x509-browser-forms/executions/execution -r "$REALM" \
    -s provider="auth-username-password-form" 2>/dev/null || echo "   (already exists)"

# Get execution IDs and set requirements
echo "6. Configuring execution requirements..."
EXECUTIONS=$($KCADM get authentication/flows/x509-browser-forms/executions -r "$REALM")

# Set all to ALTERNATIVE
for EXEC_ID in $(echo "$EXECUTIONS" | grep '"id"' | cut -d'"' -f4); do
    $KCADM update authentication/flows/x509-browser-forms/executions -r "$REALM" \
        -b "{\"id\":\"$EXEC_ID\",\"requirement\":\"ALTERNATIVE\"}" 2>/dev/null || true
done
echo "   Set all executions to ALTERNATIVE."

# Create the main x509-browser-flow
echo "7. Creating 'x509-browser-flow' main flow..."
MAIN_FLOW_ID=$($KCADM create authentication/flows -r "$REALM" -s alias="x509-browser-flow" -s providerId="basic-flow" -s topLevel=true -s builtIn=false -s description="Browser flow with X.509 certificate support" -i 2>/dev/null || echo "exists")

if [ "$MAIN_FLOW_ID" = "exists" ]; then
    echo "   Flow already exists, skipping..."
else
    echo "   Created flow with ID: $MAIN_FLOW_ID"
fi

# Add executions to main flow
echo "8. Adding authenticators to main flow..."

# Add Cookie authenticator
echo "   - Adding Cookie authenticator..."
$KCADM create authentication/flows/x509-browser-flow/executions/execution -r "$REALM" \
    -s provider="auth-cookie" 2>/dev/null || echo "   (already exists)"

# Add Identity Provider Redirector
echo "   - Adding Identity Provider Redirector..."
$KCADM create authentication/flows/x509-browser-flow/executions/execution -r "$REALM" \
    -s provider="identity-provider-redirector" 2>/dev/null || echo "   (already exists)"

# Add the subflow reference
echo "   - Adding x509-browser-forms subflow..."
$KCADM create authentication/flows/x509-browser-flow/executions/flow -r "$REALM" \
    -s alias="x509-browser-forms" -s type="basic-flow" -s provider="registration-page-form" 2>/dev/null || echo "   (already exists)"

# Configure execution requirements for main flow
echo "9. Configuring main flow execution requirements..."
MAIN_EXECUTIONS=$($KCADM get authentication/flows/x509-browser-flow/executions -r "$REALM")

for EXEC_ID in $(echo "$MAIN_EXECUTIONS" | grep '"id"' | cut -d'"' -f4); do
    $KCADM update authentication/flows/x509-browser-flow/executions -r "$REALM" \
        -b "{\"id\":\"$EXEC_ID\",\"requirement\":\"ALTERNATIVE\"}" 2>/dev/null || true
done
echo "   Set all executions to ALTERNATIVE."

# Create authenticator config for X.509 (optional, for built-in X.509 authenticator)
echo "10. Creating X.509 authenticator configuration..."
$KCADM create authentication/config -r "$REALM" \
    -s alias="x509-email-fallback-config" \
    -s config.emailFallbackEnabled="true" \
    -s config.autoRegisterCertOnEmailMatch="true" 2>/dev/null || echo "   (config already exists or not needed)"

echo ""
echo "=== Migration Complete ==="
echo ""
echo "Next steps:"
echo "1. Go to Keycloak Admin Console -> Authentication -> Flows"
echo "2. Select 'x509-browser-flow'"
echo "3. Click 'Bind flow' -> Select 'Browser flow'"
echo "4. Or run: $KCADM update realms/$REALM -s browserFlow=x509-browser-flow"
echo ""
echo "To bind the flow now, run:"
echo "  $KCADM update realms/$REALM -s browserFlow=x509-browser-flow"
echo ""

read -p "Bind x509-browser-flow as the browser flow now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Binding x509-browser-flow..."
    $KCADM update realms/"$REALM" -s browserFlow=x509-browser-flow
    echo "Done! x509-browser-flow is now the default browser flow."
fi
