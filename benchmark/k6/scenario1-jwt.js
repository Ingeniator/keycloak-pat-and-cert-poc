// Scenario 1: Vanilla JWT — Keycloak token + nginx gateway + backend authz
//
// Flow: password grant → JWT → nginx (introspect) → backend /hello
// Measures the baseline: JWT acquisition + gateway introspection + backend response.

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, NGINX_BASE } from "./helpers.js";

const tokenLatency = new Trend("token_acquisition_ms", true);
const apiSuccessLatency = new Trend("api_success_ms", true);
const apiFailLatency = new Trend("api_fail_ms", true);
const successCount = new Counter("success_total");
const failCount = new Counter("fail_total");

export const options = {
  scenarios: {
    jwt: {
      executor: "ramping-vus",
      startVUs: 1,
      stages: [
        { duration: "30s", target: 25 },
        { duration: "1m30s", target: 50 },
        { duration: "1m", target: 50 },
      ],
      gracefulRampDown: "10s",
    },
  },
  insecureSkipTLSVerify: true,
  thresholds: {
    api_success_ms: ["p(95)<2000"],
    http_req_failed: ["rate<0.1"],
  },
};

export function setup() {
  // Warm up: get one token to ensure Keycloak is ready
  const token = getToken("testuser", "testuser123");
  return { warmupToken: token };
}

export default function () {
  // --- Token acquisition ---
  group("token_acquisition", function () {
    const start = Date.now();
    const token = getToken("testuser", "testuser123");
    tokenLatency.add(Date.now() - start);

    // --- Success path: valid JWT → /api/hello ---
    group("api_success", function () {
      const res = http.get(`${NGINX_BASE}/api/hello`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      apiSuccessLatency.add(res.timings.duration);

      const ok = check(res, {
        "status is 200": (r) => r.status === 200,
        "has greeting": (r) => r.json("message") !== undefined,
      });
      if (ok) successCount.add(1);
    });

    // --- Failure path: invalid token → 401 ---
    group("api_fail", function () {
      const res = http.get(`${NGINX_BASE}/api/hello`, {
        headers: { Authorization: "Bearer invalid_token_xxx" },
      });
      apiFailLatency.add(res.timings.duration);

      check(res, {
        "status is 401": (r) => r.status === 401,
      });
      failCount.add(1);
    });
  });
}
