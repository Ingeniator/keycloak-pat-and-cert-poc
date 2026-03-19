#!/usr/bin/env bash
# Export a Keycloak realm and convert it to a clean config-cli YAML.
#
# Usage:
#   ./export-realm.sh [realm] [keycloak-url]
#
# Examples:
#   ./export-realm.sh                          # defaults: x509-demo, http://localhost:8080
#   ./export-realm.sh my-realm
#   ./export-realm.sh my-realm https://keycloak.example.com
#
# Prerequisites: curl, jq, python3 (with PyYAML)

set -euo pipefail

REALM="${1:-x509-demo}"
KEYCLOAK_URL="${2:-http://localhost:8080}"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

OUTPUT_JSON="realm-export.json"
OUTPUT_YAML="realm-clean.yaml"

# --- Check dependencies ---
for cmd in curl jq python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found" >&2
    exit 1
  fi
done

python3 -c "import yaml" 2>/dev/null || {
  echo "Error: PyYAML is required. Install with: pip install pyyaml" >&2
  exit 1
}

# --- Get admin token ---
echo "Fetching admin token from $KEYCLOAK_URL ..."
TOKEN=$(curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Error: failed to get admin token" >&2
  exit 1
fi

# --- Export realm ---
echo "Exporting realm '${REALM}' ..."
curl -sf "${KEYCLOAK_URL}/admin/realms/${REALM}" \
  -H "Authorization: Bearer $TOKEN" > "$OUTPUT_JSON"

echo "Raw export saved to ${OUTPUT_JSON} ($(wc -c < "$OUTPUT_JSON" | tr -d ' ') bytes)"

# --- Clean up and convert to YAML ---
echo "Cleaning up and converting to YAML ..."

python3 <<'PYEOF'
import json
import yaml
import sys
import re

INPUT = "realm-export.json"
OUTPUT = "realm-clean.yaml"

with open(INPUT) as f:
    realm = json.load(f)

# Keys to always remove (internal/auto-generated)
REMOVE_KEYS = {
    "id",
    "notBefore",
    "defaultDefaultClientScopes",
    "defaultOptionalClientScopes",
    "browserSecurityHeaders",
    "smtpServer",
    "internationalizationEnabled",
    "supportedLocales",
    "defaultLocale",
    "otpPolicyType",
    "otpPolicyAlgorithm",
    "otpPolicyDigits",
    "otpPolicyInitialCounter",
    "otpPolicyPeriod",
    "otpPolicyLookAheadWindow",
    "otpSupportedApplications",
    "webAuthnPolicyRpEntityName",
    "webAuthnPolicySignatureAlgorithms",
    "webAuthnPolicyRpId",
    "webAuthnPolicyAttestationConveyancePreference",
    "webAuthnPolicyAuthenticatorAttachment",
    "webAuthnPolicyRequireResidentKey",
    "webAuthnPolicyUserVerificationRequirement",
    "webAuthnPolicyCreateTimeout",
    "webAuthnPolicyAvoidSameAuthenticatorRegister",
    "webAuthnPolicyAcceptableAaguids",
    "webAuthnPolicyPasswordlessRpEntityName",
    "webAuthnPolicyPasswordlessSignatureAlgorithms",
    "webAuthnPolicyPasswordlessRpId",
    "webAuthnPolicyPasswordlessAttestationConveyancePreference",
    "webAuthnPolicyPasswordlessAuthenticatorAttachment",
    "webAuthnPolicyPasswordlessRequireResidentKey",
    "webAuthnPolicyPasswordlessUserVerificationRequirement",
    "webAuthnPolicyPasswordlessCreateTimeout",
    "webAuthnPolicyPasswordlessAvoidSameAuthenticatorRegister",
    "webAuthnPolicyPasswordlessAcceptableAaguids",
    "clientProfiles",
    "clientPolicies",
    "identityProviders",
    "identityProviderMappers",
    "components",
    "scopeMappings",
    "clientScopeMappings",
    "requiredActions",
}

# Built-in authentication flow aliases to strip
BUILTIN_FLOW_PREFIXES = {
    "browser",
    "registration",
    "direct grant",
    "reset credentials",
    "clients",
    "first broker login",
    "docker auth",
    "http challenge",
}

# Default client IDs to strip (Keycloak built-ins)
BUILTIN_CLIENTS = {
    "account",
    "account-console",
    "admin-cli",
    "broker",
    "realm-management",
    "security-admin-console",
}


def remove_ids(obj):
    """Recursively remove 'id' fields."""
    if isinstance(obj, dict):
        return {k: remove_ids(v) for k, v in obj.items() if k != "id"}
    elif isinstance(obj, list):
        return [remove_ids(item) for item in obj]
    return obj


def is_builtin_flow(flow):
    """Check if an authentication flow is a Keycloak built-in."""
    alias = flow.get("alias", "").lower()
    if flow.get("builtIn", False):
        return True
    for prefix in BUILTIN_FLOW_PREFIXES:
        if alias.startswith(prefix):
            return True
    return False


# --- Strip top-level keys ---
for key in REMOVE_KEYS:
    realm.pop(key, None)

# --- Strip built-in auth flows ---
if "authenticationFlows" in realm:
    realm["authenticationFlows"] = [
        f for f in realm["authenticationFlows"] if not is_builtin_flow(f)
    ]
    if not realm["authenticationFlows"]:
        del realm["authenticationFlows"]

# --- Strip built-in clients ---
if "clients" in realm:
    realm["clients"] = [
        c for c in realm["clients"]
        if c.get("clientId") not in BUILTIN_CLIENTS
    ]
    if not realm["clients"]:
        del realm["clients"]

# --- Strip default client scopes (built-in) ---
realm.pop("clientScopes", None)

# --- Strip built-in roles ---
if "roles" in realm:
    roles = realm["roles"]
    if "realm" in roles:
        builtin_roles = {
            "default-roles-" + realm.get("realm", ""),
            "offline_access",
            "uma_authorization",
        }
        roles["realm"] = [
            r for r in roles["realm"] if r.get("name") not in builtin_roles
        ]
        if not roles["realm"]:
            del roles["realm"]
    # Remove client-level roles for built-in clients
    if "client" in roles:
        roles["client"] = {
            k: v for k, v in roles["client"].items()
            if k not in BUILTIN_CLIENTS
        }
        if not roles["client"]:
            del roles["client"]
    if not roles:
        del realm["roles"]

# --- Strip defaultRole (auto-managed) ---
realm.pop("defaultRole", None)

# --- Strip flow bindings that point to built-in flows ---
FLOW_BINDING_KEYS = [
    "registrationFlow",
    "directGrantFlow",
    "resetCredentialsFlow",
    "clientAuthenticationFlow",
    "dockerAuthenticationFlow",
]
for key in FLOW_BINDING_KEYS:
    realm.pop(key, None)

# --- Remove IDs everywhere ---
realm = remove_ids(realm)

# --- Write YAML ---
# Add config-cli variable substitution header
realm_name = realm.pop("realm", "x509-demo")

header = f'# Cleaned realm export — review and adjust before using as a config-cli migration\n'
header += f'# Generated from: realm-export.json\n'
header += f'#\n'
header += f'# TODO:\n'
header += f'#   1. Review and remove any settings you want to keep at Keycloak defaults\n'
header += f'#   2. Replace hardcoded values with variable substitution where needed\n'
header += f'#   3. Move secrets to environment variables\n\n'

class QuotedStr(str):
    pass

def quoted_str_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='"')

yaml.add_representer(QuotedStr, quoted_str_representer)

realm_line = f'realm: "$(env:REALM_NAME:-{realm_name})"\n'

yaml_content = yaml.dump(
    realm,
    default_flow_style=False,
    allow_unicode=True,
    sort_keys=False,
    width=120,
)

with open(OUTPUT, "w") as f:
    f.write(header)
    f.write(realm_line)
    f.write(yaml_content)

print(f"Clean YAML written to {OUTPUT}")
print(f"  - Removed {len(REMOVE_KEYS)} internal/auto-generated keys")
print(f"  - Stripped built-in auth flows, clients, roles, and client scopes")
print(f"  - Removed all 'id' fields")
PYEOF

echo ""
echo "Files created:"
echo "  ${OUTPUT_JSON}  — raw API export (keep for reference)"
echo "  ${OUTPUT_YAML}  — cleaned YAML (review, then copy to config-cli/)"
echo ""
echo "Next steps:"
echo "  1. Review ${OUTPUT_YAML} — remove anything you don't need"
echo "  2. cp ${OUTPUT_YAML} config-cli/000_baseline.yaml"
echo "  3. Test: docker compose up keycloak-config-cli"
