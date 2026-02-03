#!/bin/bash

# Generate a new client certificate for a user

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="$PROJECT_ROOT/certs"

# Configuration
KEY_SIZE=4096
CLIENT_DAYS=365

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <username> <email>"
    echo "Example: $0 johndoe john@example.com"
    exit 1
fi

USERNAME=$1
EMAIL=$2
CLIENT_DIR="$CERTS_DIR/client/$USERNAME"

# Check if CA exists
if [ ! -f "$CERTS_DIR/ca/ca.crt.pem" ] || [ ! -f "$CERTS_DIR/ca/ca.key.pem" ]; then
    log_error "CA certificate not found. Run ./scripts/generate-certs.sh first."
    exit 1
fi

# Check if user already has a certificate
if [ -d "$CLIENT_DIR" ]; then
    log_error "Certificate already exists for user: $USERNAME"
    echo "Directory: $CLIENT_DIR"
    echo "To regenerate, delete the directory first."
    exit 1
fi

log_info "Generating client certificate for: $USERNAME ($EMAIL)"

mkdir -p "$CLIENT_DIR"

# Create configuration
cat > "$CLIENT_DIR/client.cnf" << EOF
[req]
default_bits = $KEY_SIZE
prompt = no
default_md = sha256
distinguished_name = dn

[dn]
C = US
ST = California
L = San Francisco
O = Demo Organization
OU = Users
CN = $USERNAME
emailAddress = $EMAIL
EOF

cat > "$CLIENT_DIR/client_ext.cnf" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = email:$EMAIL
EOF

# Generate key
openssl genrsa -out "$CLIENT_DIR/client.key.pem" $KEY_SIZE
chmod 400 "$CLIENT_DIR/client.key.pem"

# Generate CSR
openssl req -new \
    -key "$CLIENT_DIR/client.key.pem" \
    -out "$CLIENT_DIR/client.csr" \
    -config "$CLIENT_DIR/client.cnf"

# Sign certificate
openssl x509 -req \
    -in "$CLIENT_DIR/client.csr" \
    -CA "$CERTS_DIR/ca/ca.crt.pem" \
    -CAkey "$CERTS_DIR/ca/ca.key.pem" \
    -CAcreateserial \
    -out "$CLIENT_DIR/client.crt.pem" \
    -days $CLIENT_DAYS \
    -sha256 \
    -extfile "$CLIENT_DIR/client_ext.cnf"

# Create PKCS12 bundle (use -legacy for macOS Keychain compatibility)
openssl pkcs12 -export \
    -out "$CLIENT_DIR/client.p12" \
    -inkey "$CLIENT_DIR/client.key.pem" \
    -in "$CLIENT_DIR/client.crt.pem" \
    -certfile "$CERTS_DIR/ca/ca.crt.pem" \
    -legacy \
    -passout pass:changeit

# Extract public key
openssl x509 -pubkey -noout -in "$CLIENT_DIR/client.crt.pem" > "$CLIENT_DIR/client.pub.pem"

log_info "Certificate generated successfully!"
echo ""
echo "Files:"
echo "  Certificate: $CLIENT_DIR/client.crt.pem"
echo "  Private key: $CLIENT_DIR/client.key.pem"
echo "  PKCS12:      $CLIENT_DIR/client.p12 (password: changeit)"
echo "  Public key:  $CLIENT_DIR/client.pub.pem"
echo ""
echo "To register this certificate with Keycloak:"
echo "  1. Create user '$USERNAME' in Keycloak (if not exists)"
echo "  2. Run: ./scripts/test-api.sh $USERNAME <password>"
echo ""
