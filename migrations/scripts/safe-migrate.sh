#!/bin/bash
#
# Safe migration wrapper: snapshots the realm before applying config-cli,
# and offers rollback if the migration fails.
#
# Usage:
#   ./safe-migrate.sh [realm-name] [keycloak-url] [admin-user] [admin-password]
#
# Examples:
#   ./safe-migrate.sh
#   ./safe-migrate.sh x509-demo http://localhost:8080 admin admin
#   KEYCLOAK_URL=http://kc:8080 ./safe-migrate.sh my-realm
#

set -euo pipefail

# Configuration (env vars take precedence, then positional args, then defaults)
REALM="${1:-${REALM_NAME:-x509-demo}}"
KEYCLOAK_URL="${2:-${KEYCLOAK_URL:-http://localhost:8080}}"
ADMIN_USER="${3:-${KEYCLOAK_ADMIN:-admin}}"
ADMIN_PASSWORD="${4:-${KEYCLOAK_ADMIN_PASSWORD:-admin}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKUP_DIR="$PROJECT_ROOT/backups"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/${REALM}_${TIMESTAMP}.json"

# ---- helpers ----------------------------------------------------------------

log()  { echo "==> $*"; }
err()  { echo "ERROR: $*" >&2; }
die()  { err "$@"; exit 1; }

get_token() {
  local response
  response=$(curl -sf -X POST \
    "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASSWORD" \
    -d "grant_type=password" \
    -d "client_id=admin-cli") || die "Failed to authenticate with Keycloak at $KEYCLOAK_URL"

  echo "$response" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

realm_exists() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    "$KEYCLOAK_URL/admin/realms/$REALM" \
    -H "Authorization: Bearer $1")
  [ "$code" = "200" ]
}

# ---- snapshot ---------------------------------------------------------------

snapshot_realm() {
  local token="$1"

  log "Exporting realm '$REALM' to $BACKUP_FILE"
  mkdir -p "$BACKUP_DIR"

  local http_code
  http_code=$(curl -s -o "$BACKUP_FILE" -w "%{http_code}" \
    -X POST "$KEYCLOAK_URL/admin/realms/$REALM/partial-export?exportClients=true&exportGroupsAndRoles=true" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  if [ "$http_code" != "200" ]; then
    rm -f "$BACKUP_FILE"
    die "Export failed (HTTP $http_code)"
  fi

  local size
  size=$(wc -c < "$BACKUP_FILE" | tr -d ' ')
  log "Snapshot saved ($size bytes)"
}

# ---- rollback ---------------------------------------------------------------

rollback_realm() {
  local token="$1"
  local file="$2"

  log "Rolling back: deleting realm '$REALM'"
  curl -sf -X DELETE \
    "$KEYCLOAK_URL/admin/realms/$REALM" \
    -H "Authorization: Bearer $token" || die "Failed to delete realm"

  log "Rolling back: re-importing from $file"
  curl -sf -X POST \
    "$KEYCLOAK_URL/admin/realms" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "@$file" || die "Failed to import realm from backup"

  log "Rollback complete"
}

# ---- migrate ----------------------------------------------------------------

run_config_cli() {
  log "Running keycloak-config-cli"
  docker compose -f "$PROJECT_ROOT/docker-compose.yml" up keycloak-config-cli
  return $?
}

# ---- main -------------------------------------------------------------------

echo "============================================"
echo "  Safe Migration — $REALM"
echo "  Keycloak: $KEYCLOAK_URL"
echo "  Timestamp: $TIMESTAMP"
echo "============================================"
echo ""

# Step 1: authenticate
log "Authenticating as '$ADMIN_USER'"
TOKEN=$(get_token)

# Step 2: snapshot (skip if realm doesn't exist yet — first run)
if realm_exists "$TOKEN"; then
  snapshot_realm "$TOKEN"
else
  log "Realm '$REALM' does not exist yet — skipping snapshot (first run)"
  BACKUP_FILE=""
fi

# Step 3: apply migrations
echo ""
if run_config_cli; then
  log "Migration succeeded"
  if [ -n "$BACKUP_FILE" ]; then
    log "Backup retained at: $BACKUP_FILE"
    log "To rollback manually: $0 --rollback $BACKUP_FILE"
  fi
  exit 0
fi

# Step 4: migration failed — offer rollback
echo ""
err "config-cli exited with an error"

if [ -z "$BACKUP_FILE" ]; then
  die "No backup available (realm was new). Check config-cli logs."
fi

# Non-interactive mode (CI): rollback automatically if SAFE_MIGRATE_AUTO_ROLLBACK=1
if [ "${SAFE_MIGRATE_AUTO_ROLLBACK:-0}" = "1" ]; then
  log "Auto-rollback enabled"
  TOKEN=$(get_token)
  rollback_realm "$TOKEN" "$BACKUP_FILE"
  exit 1
fi

# Interactive: ask the user
echo ""
read -r -p "Migration failed. Rollback to pre-migration state? [y/N] " answer
case "$answer" in
  [yY]|[yY][eE][sS])
    TOKEN=$(get_token)
    rollback_realm "$TOKEN" "$BACKUP_FILE"
    exit 1
    ;;
  *)
    log "Rollback skipped. Backup available at: $BACKUP_FILE"
    log "To rollback later: $0 --rollback $BACKUP_FILE"
    exit 1
    ;;
esac
