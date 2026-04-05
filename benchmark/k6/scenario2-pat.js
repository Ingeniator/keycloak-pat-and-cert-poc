// Scenario 2: PAT through nginx — PAT + nginx token exchange + introspection + backend
//
// Flow: PAT token → nginx (exchange PAT→JWT + introspect) → backend /hello
// Measures the full gateway path: PAT exchange + introspection + proxy to backend.

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, createPat, NGINX_BASE } from "./helpers.js";

const apiSuccessLatency = new Trend("api_success_ms", true);
const apiFailLatency = new Trend("api_fail_ms", true);
const successCount = new Counter("success_total");
const failCount = new Counter("fail_total");

export const options = {
  scenarios: {
    pat_nginx: {
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
  setupTimeout: "120s",
  thresholds: {
    api_success_ms: ["p(95)<3000"],
  },
};

export function setup() {
  const jwt = getToken("testuser", "testuser123");
  const pat = createPat(jwt, `bench-${Date.now()}`);
  console.log(`Created PAT for benchmark: ${pat.substring(0, 12)}...`);
  return { pat };
}

export default function (data) {
  const pat = data.pat;

  // --- Success path: valid PAT → nginx → backend /hello ---
  group("api_success", function () {
    const res = http.get(`${NGINX_BASE}/api/hello`, {
      headers: { Authorization: `Bearer ${pat}` },
    });
    apiSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "status is 200": (r) => r.status === 200,
      "has greeting": (r) => r.json("message") !== undefined,
    });
    if (ok) successCount.add(1);
  });

  // --- Failure path: invalid PAT → 401 ---
  group("api_fail", function () {
    const res = http.get(`${NGINX_BASE}/api/hello`, {
      headers: { Authorization: "Bearer pat_invalid_token_xxx" },
    });
    apiFailLatency.add(res.timings.duration);

    check(res, {
      "status is 401": (r) => r.status === 401,
    });
    failCount.add(1);
  });
}
