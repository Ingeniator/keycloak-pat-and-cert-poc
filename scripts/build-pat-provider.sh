#!/bin/bash

# Build the Keycloak Personal Access Token API Provider

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROVIDER_DIR="$PROJECT_ROOT/keycloak/providers/pat-api"
TARGET_DIR="$PROJECT_ROOT/keycloak/providers"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
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

log_info "Building PAT API provider..."

cd "$PROVIDER_DIR"
mvn clean package -DskipTests

# Copy JAR to providers directory
cp "$PROVIDER_DIR/target/pat-api.jar" "$TARGET_DIR/"

log_info "Provider built successfully!"
log_info "JAR location: $TARGET_DIR/pat-api.jar"
echo ""
echo "To apply changes, restart Keycloak:"
echo "  docker-compose restart keycloak"
