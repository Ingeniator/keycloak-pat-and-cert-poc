#!/bin/bash

# Run all tests

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           Keycloak X.509 Demo - Test Suite                ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

FAILED=0

# Check if services are running
echo "Checking services..."
if ! curl -sk https://localhost/health/ready >/dev/null 2>&1; then
    echo -e "${RED}ERROR${NC}: Services not running. Start with 'make start' first."
    exit 1
fi
echo -e "${GREEN}Services are running${NC}"
echo ""

# Run health tests first
echo -e "${BLUE}Running Infrastructure Health Tests...${NC}"
echo ""
if "$SCRIPT_DIR/test-health.sh"; then
    echo -e "${GREEN}Health tests passed${NC}"
else
    echo -e "${RED}Health tests failed${NC}"
    FAILED=1
fi

echo ""

# Run setup to ensure certificates are registered
echo -e "${BLUE}Running Test Setup...${NC}"
echo ""
if "$SCRIPT_DIR/test-setup.sh"; then
    echo -e "${GREEN}Setup completed${NC}"
else
    echo -e "${RED}Setup failed${NC}"
    exit 1
fi

echo ""

# Run API tests
echo -e "${BLUE}Running API Tests...${NC}"
echo ""
if "$SCRIPT_DIR/test-api.sh"; then
    echo -e "${GREEN}API tests passed${NC}"
else
    echo -e "${RED}API tests failed${NC}"
    FAILED=1
fi

echo ""

# Run Certificate Authentication tests
echo -e "${BLUE}Running Certificate Authentication Tests...${NC}"
echo ""
if "$SCRIPT_DIR/test-cert-auth.sh"; then
    echo -e "${GREEN}Certificate authentication tests passed${NC}"
else
    echo -e "${RED}Certificate authentication tests failed${NC}"
    FAILED=1
fi

echo ""
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════╗"
if [ $FAILED -eq 0 ]; then
    echo "║                  All Tests Passed!                        ║"
else
    echo "║                  Some Tests Failed!                       ║"
fi
echo "╚═══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

exit $FAILED
