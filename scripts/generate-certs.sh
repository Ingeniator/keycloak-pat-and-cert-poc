#!/bin/bash

# Certificate Generation Script for Keycloak X.509 Demo
# This script generates:
# 1. CA (Certificate Authority) certificate
# 2. Server certificate (for Keycloak/Nginx)
# 3. Sample client certificates for testing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CERTS_DIR="$PROJECT_ROOT/certs"

# Configuration
CA_DAYS=3650
SERVER_DAYS=365
CLIENT_DAYS=365
KEY_SIZE=4096

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create directories
mkdir -p "$CERTS_DIR"/{ca,server,client}

# ============================================
# 1. Generate CA Certificate
# ============================================
log_info "Generating CA certificate..."

cat > "$CERTS_DIR/ca/ca.cnf" << EOF
[req]
default_bits = $KEY_SIZE
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_ca

[dn]
C = US
ST = California
L = San Francisco
O = Demo Organization
OU = Certificate Authority
CN = Demo CA

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:1
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
EOF

openssl genrsa -out "$CERTS_DIR/ca/ca.key.pem" $KEY_SIZE
chmod 400 "$CERTS_DIR/ca/ca.key.pem"

openssl req -x509 -new -nodes \
    -key "$CERTS_DIR/ca/ca.key.pem" \
    -sha256 -days $CA_DAYS \
    -out "$CERTS_DIR/ca/ca.crt.pem" \
    -config "$CERTS_DIR/ca/ca.cnf"

log_info "CA certificate created: $CERTS_DIR/ca/ca.crt.pem"

# ============================================
# 2. Generate Server Certificate
# ============================================
log_info "Generating server certificate..."

cat > "$CERTS_DIR/server/server.cnf" << EOF
[req]
default_bits = $KEY_SIZE
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = US
ST = California
L = San Francisco
O = Demo Organization
OU = Server
CN = localhost

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = keycloak
DNS.3 = keycloak.local
DNS.4 = nginx
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

cat > "$CERTS_DIR/server/server_ext.cnf" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = keycloak
DNS.3 = keycloak.local
DNS.4 = nginx
IP.1 = 127.0.0.1
IP.2 = ::1
EOF

openssl genrsa -out "$CERTS_DIR/server/server.key.pem" $KEY_SIZE
chmod 400 "$CERTS_DIR/server/server.key.pem"

openssl req -new \
    -key "$CERTS_DIR/server/server.key.pem" \
    -out "$CERTS_DIR/server/server.csr" \
    -config "$CERTS_DIR/server/server.cnf"

openssl x509 -req \
    -in "$CERTS_DIR/server/server.csr" \
    -CA "$CERTS_DIR/ca/ca.crt.pem" \
    -CAkey "$CERTS_DIR/ca/ca.key.pem" \
    -CAcreateserial \
    -out "$CERTS_DIR/server/server.crt.pem" \
    -days $SERVER_DAYS \
    -sha256 \
    -extfile "$CERTS_DIR/server/server_ext.cnf"

log_info "Server certificate created: $CERTS_DIR/server/server.crt.pem"

# ============================================
# 3. Generate Sample Client Certificates
# ============================================
generate_client_cert() {
    local username=$1
    local email=$2
    local client_dir="$CERTS_DIR/client/$username"

    log_info "Generating client certificate for: $username"

    mkdir -p "$client_dir"

    cat > "$client_dir/client.cnf" << EOF
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
CN = $username
emailAddress = $email
EOF

    cat > "$client_dir/client_ext.cnf" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = email:$email
EOF

    openssl genrsa -out "$client_dir/client.key.pem" $KEY_SIZE
    chmod 400 "$client_dir/client.key.pem"

    openssl req -new \
        -key "$client_dir/client.key.pem" \
        -out "$client_dir/client.csr" \
        -config "$client_dir/client.cnf"

    openssl x509 -req \
        -in "$client_dir/client.csr" \
        -CA "$CERTS_DIR/ca/ca.crt.pem" \
        -CAkey "$CERTS_DIR/ca/ca.key.pem" \
        -CAcreateserial \
        -out "$client_dir/client.crt.pem" \
        -days $CLIENT_DAYS \
        -sha256 \
        -extfile "$client_dir/client_ext.cnf"

    # Create PKCS12 bundle for browser import (use -legacy for macOS Keychain compatibility)
    openssl pkcs12 -export \
        -out "$client_dir/client.p12" \
        -inkey "$client_dir/client.key.pem" \
        -in "$client_dir/client.crt.pem" \
        -certfile "$CERTS_DIR/ca/ca.crt.pem" \
        -legacy \
        -passout pass:changeit

    # Extract public key
    openssl x509 -pubkey -noout -in "$client_dir/client.crt.pem" > "$client_dir/client.pub.pem"

    log_info "Client certificate created: $client_dir/client.crt.pem"
    log_info "Client PKCS12 bundle: $client_dir/client.p12 (password: changeit)"
}

# Generate sample client certificates
generate_client_cert "testuser" "testuser@example.com"
generate_client_cert "admin" "admin@example.com"

# ============================================
# 4. Create Java Truststore for Keycloak
# ============================================
log_info "Creating Java truststore for Keycloak..."

# Remove existing truststore if present
rm -f "$CERTS_DIR/truststore.jks"

keytool -import -noprompt \
    -alias demo-ca \
    -file "$CERTS_DIR/ca/ca.crt.pem" \
    -keystore "$CERTS_DIR/truststore.jks" \
    -storepass changeit \
    -trustcacerts

log_info "Truststore created: $CERTS_DIR/truststore.jks"

# ============================================
# Summary
# ============================================
echo ""
log_info "============================================"
log_info "Certificate generation complete!"
log_info "============================================"
echo ""
echo "Generated files:"
echo "  CA Certificate:      $CERTS_DIR/ca/ca.crt.pem"
echo "  Server Certificate:  $CERTS_DIR/server/server.crt.pem"
echo "  Server Key:          $CERTS_DIR/server/server.key.pem"
echo "  Truststore:          $CERTS_DIR/truststore.jks"
echo ""
echo "Client certificates:"
echo "  testuser:            $CERTS_DIR/client/testuser/client.p12"
echo "  admin:               $CERTS_DIR/client/admin/client.p12"
echo ""
echo "To import client certificate in browser:"
echo "  1. Import the PKCS12 file (.p12) - password: changeit"
echo "  2. Import the CA certificate to trusted authorities"
echo ""
