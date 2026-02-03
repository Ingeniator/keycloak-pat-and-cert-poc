#!/bin/bash

# Main setup script for Keycloak X.509 Demo

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# Banner
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     Keycloak X.509 Certificate Authentication Demo        ║"
echo "║                      Setup Script                          ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Check prerequisites
log_step "Checking prerequisites..."

if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    log_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    log_error "OpenSSL is not installed. Please install OpenSSL first."
    exit 1
fi

if ! command -v keytool &> /dev/null; then
    log_warn "Java keytool not found. Truststore generation may fail."
    log_warn "Please ensure Java JDK is installed."
fi

log_info "All prerequisites met!"

# Generate certificates
log_step "Generating certificates..."
chmod +x "$SCRIPT_DIR/generate-certs.sh"
"$SCRIPT_DIR/generate-certs.sh"

# Build provider (if Maven is available)
log_step "Building Keycloak provider..."
if command -v mvn &> /dev/null; then
    chmod +x "$SCRIPT_DIR/build-provider.sh"
    "$SCRIPT_DIR/build-provider.sh"
else
    log_warn "Maven not found. Skipping provider build."
    log_warn "Please build the provider manually and place the JAR in keycloak/providers/"
fi

# Add localhost entry to hosts file (optional)
log_step "Checking hosts file..."
if ! grep -q "keycloak.local" /etc/hosts 2>/dev/null; then
    log_warn "Consider adding this to /etc/hosts for easier access:"
    echo "  127.0.0.1 keycloak.local"
fi

# Start services
log_step "Starting Docker services..."
cd "$PROJECT_ROOT"

# Use docker compose or docker-compose based on what's available
if docker compose version &> /dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="docker-compose"
fi

$COMPOSE_CMD down --volumes 2>/dev/null || true
$COMPOSE_CMD up -d

log_step "Waiting for Keycloak to start..."
echo -n "Waiting"
for i in {1..60}; do
    if curl -sk https://localhost/health/ready &> /dev/null; then
        echo ""
        log_info "Keycloak is ready!"
        break
    fi
    echo -n "."
    sleep 2
done

# Summary
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""
echo "Access URLs:"
echo "  Keycloak Admin:  https://localhost/admin"
echo "  Keycloak Account: https://localhost/realms/x509-demo/account"
echo ""
echo "Admin Credentials:"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "Test User Credentials:"
echo "  Username: testuser"
echo "  Password: testuser123"
echo ""
echo "X.509 Certificate API:"
echo "  Base URL: https://localhost/realms/x509-demo/x509-cert-api/"
echo ""
echo "Client Certificates:"
echo "  testuser: certs/client/testuser/client.p12 (password: changeit)"
echo "  admin:    certs/client/admin/client.p12 (password: changeit)"
echo ""
echo "To test certificate authentication:"
echo "  1. Import client.p12 into your browser"
echo "  2. Import certs/ca/ca.crt.pem as a trusted CA"
echo "  3. Visit https://localhost/realms/x509-demo/account"
echo ""
echo "Useful commands:"
echo "  View logs:    docker-compose logs -f keycloak"
echo "  Stop:         docker-compose down"
echo "  Restart:      docker-compose restart"
echo ""
