#!/bin/bash

# Generate a self-signed X.509 certificate for authentication
# Similar to: ssh-keygen -t rsa -b 4096
#
# Usage: ./generate-self-signed-cert.sh [output-dir] [common-name] [email]
#
# Example:
#   ./generate-self-signed-cert.sh ~/.x509 "John Doe" "john@example.com"
#
# This creates:
#   - private.key.pem  (keep secret, like id_rsa)
#   - certificate.pem  (upload to API, like id_rsa.pub)
#   - certificate.p12  (for browser import)

set -e

# Default values
OUTPUT_DIR="${1:-$HOME/.x509}"
COMMON_NAME="${2:-$(whoami)}"
EMAIL="${3:-$(whoami)@localhost}"
DAYS_VALID=365
KEY_SIZE=4096

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║     Generate Self-Signed X.509 Certificate                ║"
echo "║     (Like ssh-keygen for X.509)                           ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Create output directory
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

KEY_FILE="$OUTPUT_DIR/private.key.pem"
CERT_FILE="$OUTPUT_DIR/certificate.pem"
P12_FILE="$OUTPUT_DIR/certificate.p12"

# Check if files already exist
if [ -f "$KEY_FILE" ] || [ -f "$CERT_FILE" ]; then
    echo -e "${YELLOW}Warning: Certificate files already exist in $OUTPUT_DIR${NC}"
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

echo "Generating certificate for:"
echo "  Common Name: $COMMON_NAME"
echo "  Email: $EMAIL"
echo "  Output: $OUTPUT_DIR"
echo "  Valid for: $DAYS_VALID days"
echo ""

# Generate private key
echo -e "${BLUE}[1/3]${NC} Generating private key ($KEY_SIZE bit RSA)..."
openssl genrsa -out "$KEY_FILE" $KEY_SIZE 2>/dev/null
chmod 600 "$KEY_FILE"
echo -e "      ${GREEN}✓${NC} Private key: $KEY_FILE"

# Generate self-signed certificate
echo -e "${BLUE}[2/3]${NC} Generating self-signed certificate..."
openssl req -new -x509 \
    -key "$KEY_FILE" \
    -out "$CERT_FILE" \
    -days $DAYS_VALID \
    -subj "/CN=$COMMON_NAME/emailAddress=$EMAIL" \
    -addext "basicConstraints=CA:FALSE" \
    -addext "keyUsage=digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=clientAuth" \
    2>/dev/null
chmod 644 "$CERT_FILE"
echo -e "      ${GREEN}✓${NC} Certificate: $CERT_FILE"

# Generate PKCS12 for browser import
echo -e "${BLUE}[3/3]${NC} Generating PKCS12 bundle for browser..."
# Use legacy algorithms for macOS compatibility
openssl pkcs12 -export \
    -out "$P12_FILE" \
    -inkey "$KEY_FILE" \
    -in "$CERT_FILE" \
    -name "$COMMON_NAME" \
    -legacy \
    -passout pass:changeit \
    2>/dev/null
chmod 600 "$P12_FILE"
echo -e "      ${GREEN}✓${NC} PKCS12: $P12_FILE (password: changeit)"

# Calculate fingerprint
FINGERPRINT=$(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=/SHA256:/' | tr -d ':')

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Certificate Generated!                  ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Files created:"
echo "  Private key:  $KEY_FILE (keep secret!)"
echo "  Certificate:  $CERT_FILE (upload to API)"
echo "  Browser pkg:  $P12_FILE (import to browser)"
echo ""
echo "Fingerprint:"
echo "  $FINGERPRINT"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "1. Register certificate with Keycloak:"
echo ""
echo "   # Get access token"
echo "   TOKEN=\$(curl -sk -X POST 'https://localhost/realms/x509-demo/protocol/openid-connect/token' \\"
echo "       -d 'grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret' \\"
echo "       -d 'username=YOUR_USERNAME&password=YOUR_PASSWORD' | jq -r '.access_token')"
echo ""
echo "   # Upload certificate"
echo "   curl -sk -X POST 'https://localhost/realms/x509-demo/x509-cert-api/certificates' \\"
echo "       -H \"Authorization: Bearer \$TOKEN\" \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d \"{\\\"certificate\\\": \\\"\$(cat $CERT_FILE | awk '{printf \"%s\\\\n\", \$0}')\\\", \\\"title\\\": \\\"My Certificate\\\"}\""
echo ""
echo "2. Import to browser (macOS):"
echo "   security import $P12_FILE -k ~/Library/Keychains/login.keychain-db -P changeit -A"
echo ""
echo "3. Visit https://localhost/realms/x509-demo/account"
echo "   Select your certificate when prompted"
echo ""
