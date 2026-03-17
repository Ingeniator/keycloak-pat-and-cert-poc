#!/usr/bin/env bash
#
# Set a user attribute in Keycloak for a list of users.
#
# Reads a file containing one email per line and sets the specified
# attribute (default: SOURCE) to the filename on each matching user.
# Users that already have the attribute are skipped.
#
# Usage:
#   ./set_source_attribute.sh <file>
#
# Examples:
#   ./set_source_attribute.sh SOURCE1        # sets SOURCE=SOURCE1
#   ./set_source_attribute.sh SOURCE2        # sets SOURCE=SOURCE2
#   ATTR_NAME=ORIGIN ./set_source_attribute.sh SOURCE1  # sets ORIGIN=SOURCE1
#
# Environment variables:
#   KEYCLOAK_URL   Keycloak base URL       (default: http://localhost:8080)
#   REALM          Target realm             (default: master)
#   ADMIN_USER     Admin username           (default: admin)
#   ADMIN_PASSWORD Admin password           (default: admin)
#   ATTR_NAME      User attribute name      (default: SOURCE)
#
# Dependencies: curl, jq
#
set -euo pipefail

# --- Configuration ---
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
REALM="${REALM:-master}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
ATTR_NAME="${ATTR_NAME:-SOURCE}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <file>" >&2
  echo "Example: $0 SOURCE1" >&2
  exit 1
fi

# --- Get admin access token ---
get_token() {
  curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASSWORD}" \
    -d "grant_type=password" | jq -r '.access_token'
}

# --- Main ---
TOKEN=$(get_token)
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Failed to obtain access token" >&2
  exit 1
fi
echo "Authenticated with Keycloak"

AUTH="Authorization: Bearer ${TOKEN}"

file="$1"
attribute_value=$(basename "$file")

if [[ ! -f "$file" ]]; then
  echo "ERROR: ${file} not found" >&2
  exit 1
fi

echo "Processing ${file} (attribute value: ${attribute_value}) ..."

while IFS= read -r email; do
    email=$(echo "$email" | xargs) #trim spaces
    [[ -z "$email" ]] && continue

    # Single GET: search returns full user object with attributes
    user=$(curl -s -H "$AUTH" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users?email=$(jq -rn --arg e "$email" '$e|@uri')&exact=true" \
      | jq '.[0] // empty')

    if [[ -z "$user" || "$user" == "null" ]]; then
      echo "  SKIP: no user found for ${email}"
      continue
    fi

    has_attr=$(echo "$user" | jq -r --arg a "$ATTR_NAME" '.attributes[$a] // [] | length')
    if [[ "$has_attr" -gt 0 ]]; then
      echo "  ERROR: ${email} already has ${ATTR_NAME} attribute, skipping" >&2
      continue
    fi

    # Single PUT: merge new attribute into existing ones
    user_id=$(echo "$user" | jq -r '.id')
    attrs=$(echo "$user" | jq --arg a "$ATTR_NAME" --arg src "$attribute_value" '(.attributes // {}) + {($a): [$src]}')

    status=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
      -H "$AUTH" -H "Content-Type: application/json" \
      "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${user_id}" \
      -d "{\"attributes\": ${attrs}}")

    if [[ "$status" == "204" ]]; then
      echo "  OK: ${email} -> ${attribute_value}"
    else
      echo "  FAIL (HTTP ${status}): ${email}" >&2
    fi
done < "$file"

echo "Done"
