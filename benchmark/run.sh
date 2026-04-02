#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

RESULTS_DIR="benchmark/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "=== Auth Flow Benchmark ==="
echo "Results: $RESULTS_DIR"
echo ""

run_scenario() {
  local name="$1"
  local script="$2"
  echo "--- Running: $name ---"
  docker compose run --rm \
    -e K6_CONSOLE_OUTPUT=stdout \
    k6 run "/scripts/$script" \
    --summary-export "/results/$(basename "$script" .js).json" \
    2>&1 | tee "$RESULTS_DIR/${name}.log"
  echo ""
  echo "--- $name complete ---"
  echo ""
}

run_scenario "1-vanilla-jwt"  "scenario1-jwt.js"
run_scenario "2-pat-exchange" "scenario2-pat.js"
run_scenario "3-openfga-authz" "scenario3-openfga.js"

echo "=== All scenarios complete ==="
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "Summary JSON files:"
ls -la "$RESULTS_DIR/"*.json 2>/dev/null || echo "(check docker volume for JSON exports)"
