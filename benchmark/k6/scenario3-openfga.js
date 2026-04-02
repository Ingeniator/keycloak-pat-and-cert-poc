// Scenario 3: OpenFGA authorization — JWT + nginx + backend → OpenFGA check
//
// Flow: JWT → nginx (introspect) → backend → OpenFGA permission check → response
// Measures the added latency of a fine-grained authorization call to OpenFGA.
//
// Success path: testuser is owner of workspace:acme and document:doc1
// Failure path: testuser has no relation to workspace:nonexistent → 403

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, NGINX_BASE } from "./helpers.js";

const tokenLatency = new Trend("token_acquisition_ms", true);
const apiSuccessLatency = new Trend("api_success_ms", true);
const apiForbiddenLatency = new Trend("api_forbidden_ms", true);
const successCount = new Counter("success_total");
const forbiddenCount = new Counter("forbidden_total");

export const options = {
  scenarios: {
    openfga: {
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
    api_success_ms: ["p(95)<3000"],
    http_req_failed: ["rate<0.2"],
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

  // --- Success path: testuser → owner of workspace:acme → 200 ---
  group("workspace_allowed", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/acme`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    apiSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "status is 200": (r) => r.status === 200,
      "workspace is acme": (r) => r.json("workspace") === "acme",
    });
    if (ok) successCount.add(1);
  });

  // --- Success path: testuser → owner of document:doc1 → 200 ---
  group("document_allowed", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/acme/documents/doc1`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    apiSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "status is 200": (r) => r.status === 200,
      "document is doc1": (r) => r.json("document") === "doc1",
    });
    if (ok) successCount.add(1);
  });

  // --- Forbidden path: no relation to workspace:nonexistent → 403 ---
  group("workspace_forbidden", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/nonexistent`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    apiForbiddenLatency.add(res.timings.duration);

    check(res, {
      "status is 403": (r) => r.status === 403,
    });
    forbiddenCount.add(1);
  });
}
