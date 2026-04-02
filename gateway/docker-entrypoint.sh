#!/bin/sh
set -e

# Substitute env vars in njs scripts (with defaults via :- syntax)
# envsubst doesn't support :- defaults, so we set defaults here
export KEYCLOAK_INTERNAL="${KEYCLOAK_INTERNAL:-http://keycloak:8080}"
export KEYCLOAK_EXTERNAL="${KEYCLOAK_EXTERNAL:-https://localhost}"
export REALM="${REALM:-public}"
export CLIENT_ID="${CLIENT_ID:-ui-bff}"
export CLIENT_SECRET="${CLIENT_SECRET:-bff-secret}"
export BASE_URL="${BASE_URL:-https://localhost}"
export TOKEN_COOKIE="${TOKEN_COOKIE:-__token}"
export INTROSPECTION_CACHE_SEC="${INTROSPECTION_CACHE_SEC:-30}"
export PAT_CACHE_SEC="${PAT_CACHE_SEC:-60}"

# Derived URLs for pat.js
export PAT_EXCHANGE_URL="${KEYCLOAK_INTERNAL}/realms/${REALM}/pat-api/tokens/exchange"
export OIDC_INTROSPECT_URL="${KEYCLOAK_INTERNAL}/realms/${REALM}/protocol/openid-connect/token/introspect"

# Process oidc.js template
envsubst '${KEYCLOAK_INTERNAL} ${KEYCLOAK_EXTERNAL} ${REALM} ${CLIENT_ID} ${CLIENT_SECRET} ${BASE_URL} ${TOKEN_COOKIE} ${INTROSPECTION_CACHE_SEC}' \
  < /etc/nginx/njs/oidc.js.template \
  > /etc/nginx/njs/oidc.js

# Process pat.js template
envsubst '${PAT_EXCHANGE_URL} ${PAT_CACHE_SEC} ${OIDC_INTROSPECT_URL} ${CLIENT_ID} ${CLIENT_SECRET} ${INTROSPECTION_CACHE_SEC}' \
  < /etc/nginx/njs/pat.js.template \
  > /etc/nginx/njs/pat.js

exec nginx -g 'daemon off;'
