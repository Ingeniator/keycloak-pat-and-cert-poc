.PHONY: all setup certs build build-pat start stop restart logs clean test test-health test-setup test-api test-cert test-pat test-e2e help logs-gateway shell-gateway logs-openfga seed-openfga test-openfga start-core start-x509 start-gateway start-pat start-full stop-layer

# Default target
all: setup

# Complete setup
setup:
	@./scripts/setup.sh

# Generate certificates only
certs:
	@./scripts/generate-certs.sh

# Build custom providers
build:
	@./scripts/build-provider.sh
	@./scripts/build-pat-provider.sh

# Build PAT provider only
build-pat:
	@./scripts/build-pat-provider.sh

# Compose file sets for each layer
COMPOSE_BASE    := -f docker/compose.base.yml
COMPOSE_X509    := $(COMPOSE_BASE) -f docker/compose.x509.yml
COMPOSE_GATEWAY := $(COMPOSE_X509) -f docker/compose.gateway.yml
COMPOSE_PAT     := $(COMPOSE_GATEWAY) -f docker/compose.pat.yml
COMPOSE_FULL    := $(COMPOSE_PAT) -f docker/compose.openfga.yml -f docker/compose.bench.yml

# Start full stack (default — backward compatible)
start:
	@docker compose $(COMPOSE_FULL) up -d

# Start individual layers
start-core:
	@docker compose $(COMPOSE_BASE) up -d

start-x509:
	@docker compose $(COMPOSE_X509) up -d

start-gateway:
	@docker compose $(COMPOSE_GATEWAY) up -d

start-pat:
	@docker compose $(COMPOSE_PAT) up -d

start-full:
	@docker compose $(COMPOSE_FULL) up -d

# Stop services (works with any layer combination)
stop:
	@docker compose $(COMPOSE_FULL) down

# Stop a specific layer set (pass LAYER=core|x509|gateway|pat|full)
stop-layer:
ifndef LAYER
	$(error LAYER is required. Usage: make stop-layer LAYER=core|x509|gateway|pat|full)
endif
	@docker compose $(COMPOSE_$(shell echo $(LAYER) | tr a-z A-Z)) down

# Restart services
restart:
	@docker compose $(COMPOSE_FULL) restart

# View logs
logs:
	@docker compose $(COMPOSE_FULL) logs -f

# View Keycloak logs
logs-keycloak:
	@docker compose $(COMPOSE_FULL) logs -f keycloak

# View Gateway (nginx) logs
logs-gateway:
	@docker compose $(COMPOSE_FULL) logs -f nginx

# Clean everything
clean:
	@docker compose $(COMPOSE_FULL) down -v
	@rm -rf certs/
	@rm -f keycloak/providers/*.jar
	@rm -rf keycloak/providers/*/target/

# Run all tests
test:
	@./tests/test-all.sh

# Test certificate API
test-api:
	@./tests/test-api.sh

# Test certificate authentication
test-cert:
	@./tests/test-cert-auth.sh

# Test personal access tokens
test-pat:
	@./tests/test-pat.sh

# Run Playwright e2e tests
test-e2e:
	@cd tests && npx playwright test

# Run Playwright e2e tests with browser visible
test-e2e-headed:
	@cd tests && npx playwright test --headed

# Test infrastructure health
test-health:
	@./tests/test-health.sh

# Test setup (register certificates)
test-setup:
	@./tests/test-setup.sh

# Generate new client certificate (CA-signed)
new-client:
	@read -p "Enter username: " user && \
	read -p "Enter email: " email && \
	./scripts/generate-client-cert.sh "$$user" "$$email"

# Generate self-signed certificate (like ssh-keygen)
gen-cert:
	@./scripts/generate-self-signed-cert.sh

# Register self-signed certificate (~/.x509/certificate.pem) for testuser
register-cert:
	@echo "Registering certificate for testuser..."
	@TOKEN=$$(curl -sk -X POST 'https://localhost/realms/x509-demo/protocol/openid-connect/token' \
		-d 'grant_type=password&client_id=x509-demo-app&client_secret=demo-app-secret&username=testuser&password=testuser123' \
		| grep -o '"access_token":"[^"]*"' | cut -d'"' -f4) && \
	CERT=$$(cat ~/.x509/certificate.pem | awk '{printf "%s\\n", $$0}') && \
	RESPONSE=$$(curl -sk -X POST 'https://localhost/realms/x509-demo/x509-cert-api/certificates' \
		-H "Authorization: Bearer $$TOKEN" \
		-H 'Content-Type: application/json' \
		-d "{\"certificate\": \"$$CERT\", \"title\": \"Self-Signed Certificate\"}") && \
	if echo "$$RESPONSE" | grep -q '"fingerprint"'; then \
		echo "Certificate registered successfully!"; \
		echo "$$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$$RESPONSE"; \
	elif echo "$$RESPONSE" | grep -q 'already'; then \
		echo "Certificate already registered."; \
	else \
		echo "Failed to register: $$RESPONSE"; \
		exit 1; \
	fi

# Export realm from running Keycloak
export-realm:
	@docker exec keycloak /opt/keycloak/bin/kc.sh export \
		--dir /opt/keycloak/data/export \
		--realm x509-demo
	@docker cp keycloak:/opt/keycloak/data/export/x509-demo-realm.json ./keycloak/realm-config/

# Shell into Keycloak container
shell-keycloak:
	@docker exec -it keycloak /bin/bash

# Shell into Gateway (nginx) container
shell-gateway:
	@docker exec -it nginx-proxy /bin/sh

# Import certificates to macOS Keychain for browser testing
import-certs:
	@echo "Regenerating PKCS12 with legacy algorithms..."
	@openssl pkcs12 -export \
		-out certs/client/testuser/client.p12 \
		-inkey certs/client/testuser/client.key.pem \
		-in certs/client/testuser/client.crt.pem \
		-certfile certs/ca/ca.crt.pem \
		-legacy \
		-passout pass:changeit
	@openssl pkcs12 -export \
		-out certs/client/admin/client.p12 \
		-inkey certs/client/admin/client.key.pem \
		-in certs/client/admin/client.crt.pem \
		-certfile certs/ca/ca.crt.pem \
		-legacy \
		-passout pass:changeit
	@echo "Importing CA certificate as trusted (requires sudo)..."
	sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain certs/ca/ca.crt.pem
	@echo "Importing client certificate..."
	security import certs/client/testuser/client.p12 -k ~/Library/Keychains/login.keychain-db -P changeit -A
	@echo ""
	@echo "Certificates imported successfully!"
	@echo "Visit: https://localhost/realms/x509-demo/account"

# Remove certificates from macOS Keychain
remove-certs:
	@echo "Removing Demo CA from System Keychain (requires sudo)..."
	-sudo security delete-certificate -c "Demo CA" /Library/Keychains/System.keychain 2>/dev/null || true
	@echo "Removing client certificate from login Keychain..."
	-security delete-certificate -c "testuser" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
	@echo "Certificates removed."

# View OpenFGA logs
logs-openfga:
	@docker compose $(COMPOSE_FULL) logs -f openfga

# Re-run OpenFGA init container (seed store, model, tuples)
seed-openfga:
	@docker compose $(COMPOSE_FULL) up --build --force-recreate openfga-init

# Run OpenFGA integration tests
test-openfga:
	@./tests/test-openfga.sh

# Help
help:
	@echo "Keycloak X.509 Demo - Available targets:"
	@echo ""
	@echo "  Setup & Build:"
	@echo "    make setup          - Complete setup (certs + build + start)"
	@echo "    make certs          - Generate certificates only"
	@echo "    make build          - Build custom Keycloak providers"
	@echo "    make build-pat      - Build PAT provider only"
	@echo ""
	@echo "  Feature Layers (each includes layers below it):"
	@echo "    make start-core     - Layer 0: Keycloak + PostgreSQL"
	@echo "    make start-x509     - Layer 1: + X.509 certificate auth"
	@echo "    make start-gateway  - Layer 2: + Nginx gateway, UI, backend"
	@echo "    make start-pat      - Layer 3: + Personal access tokens"
	@echo "    make start-full     - Layer 4: + OpenFGA authorization"
	@echo "    make start          - Full stack (all layers, default)"
	@echo ""
	@echo "  Service Management:"
	@echo "    make stop           - Stop Docker services"
	@echo "    make restart        - Restart Docker services"
	@echo "    make clean          - Remove all generated files"
	@echo ""
	@echo "  Logs:"
	@echo "    make logs           - View all logs"
	@echo "    make logs-keycloak  - View Keycloak logs"
	@echo "    make logs-gateway   - View Gateway (nginx) logs"
	@echo "    make logs-openfga   - View OpenFGA logs"
	@echo ""
	@echo "  Testing:"
	@echo "    make test           - Run all tests"
	@echo "    make test-health    - Test infrastructure health"
	@echo "    make test-setup     - Register test certificates"
	@echo "    make test-api       - Test certificate management API"
	@echo "    make test-cert      - Test certificate authentication"
	@echo "    make test-pat       - Test personal access tokens"
	@echo "    make test-openfga   - Run OpenFGA integration tests"
	@echo "    make test-e2e       - Run Playwright e2e tests"
	@echo "    make test-e2e-headed - Run e2e tests with browser visible"
	@echo ""
	@echo "  Certificates:"
	@echo "    make gen-cert       - Generate self-signed certificate (like ssh-keygen)"
	@echo "    make new-client     - Generate new CA-signed client cert"
	@echo "    make register-cert  - Register ~/.x509/certificate.pem for testuser"
	@echo "    make import-certs   - Import certs to macOS Keychain"
	@echo "    make remove-certs   - Remove certs from macOS Keychain"
	@echo ""
	@echo "  Utilities:"
	@echo "    make export-realm   - Export realm from running Keycloak"
	@echo "    make shell-keycloak - Open shell in Keycloak container"
	@echo "    make shell-gateway  - Open shell in Gateway container"
	@echo "    make seed-openfga   - Re-run OpenFGA bootstrap"
	@echo ""
