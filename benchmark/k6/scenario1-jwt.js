// Scenario 1: Direct JWT — Keycloak token + backend (no gateway)
//
// Flow: password grant → JWT → backend /hello directly
// Baseline measurement: token acquisition + backend auth (claims from token).
// Backend is called directly (not through nginx) to isolate JWT overhead.

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, BACKEND_BASE } from "./helpers.js";

const tokenLatency = new Trend("token_acquisition_ms", true);
const apiSuccessLatency = new Trend("api_success_ms", true);
const apiFailLatency = new Trend("api_fail_ms", true);
const successCount = new Counter("success_total");
const failCount = new Counter("fail_total");

export const options = {
  scenarios: {
    jwt_direct: {
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
  setupTimeout: "120s",
  thresholds: {
    api_success_ms: ["p(95)<1000"],
  },
};

export function setup() {
  const token = getToken("testuser", "testuser123");
  return { warmupToken: token };
}

export default function () {
  // --- Token acquisition ---
  const start = Date.now();
  const token = getToken("testuser", "testuser123");
  tokenLatency.add(Date.now() - start);

  // --- Success path: valid JWT → backend /hello directly ---
  group("api_success", function () {
    const res = http.get(`${BACKEND_BASE}/hello`, {
      headers: {
        Authorization: `Bearer ${token}`,
        "X-Token-Claims": JSON.stringify({
          sub: "testuser",
          preferred_username: "testuser",
          email: "testuser@example.com",
          realm_access: { roles: ["user"] },
          iat: Math.floor(Date.now() / 1000),
        }),
      },
    });
    apiSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "status is 200": (r) => r.status === 200,
      "has greeting": (r) => r.json("message") !== undefined,
    });
    if (ok) successCount.add(1);
  });

  // --- Failure path: no token → 401 ---
  group("api_fail", function () {
    const res = http.get(`${BACKEND_BASE}/hello`);
    apiFailLatency.add(res.timings.duration);

    check(res, {
      "status is 401": (r) => r.status === 401,
    });
    failCount.add(1);
  });
}
