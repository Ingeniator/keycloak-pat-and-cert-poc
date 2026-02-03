#!/bin/bash

# Build the Keycloak X.509 Certificate API Provider

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROVIDER_DIR="$PROJECT_ROOT/keycloak/providers/x509-cert-api"
TARGET_DIR="$PROJECT_ROOT/keycloak/providers"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Maven is installed
if ! command -v mvn &> /dev/null; then
    log_error "Maven is not installed. Please install Maven first."
    echo "On macOS: brew install maven"
    echo "On Ubuntu: sudo apt install maven"
    exit 1
fi

log_info "Building X.509 Certificate API provider..."

cd "$PROVIDER_DIR"
mvn clean package -DskipTests

# Copy JAR to providers directory
cp "$PROVIDER_DIR/target/x509-cert-api.jar" "$TARGET_DIR/"

log_info "Provider built successfully!"
log_info "JAR location: $TARGET_DIR/x509-cert-api.jar"
echo ""
echo "To apply changes, restart Keycloak:"
echo "  docker-compose restart keycloak"
