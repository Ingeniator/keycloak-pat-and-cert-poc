// Scenario 3: PAT + nginx + OpenFGA — full authorization chain
//
// Flow: PAT → nginx (exchange + introspect) → backend → OpenFGA permission check
// Measures the added latency of fine-grained authorization on top of scenario 2.
//
// Success: testuser is owner of workspace:acme and document:doc1
// Forbidden: testuser has no relation to workspace:nonexistent → 403

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, createPat, NGINX_BASE } from "./helpers.js";

const workspaceSuccessLatency = new Trend("workspace_success_ms", true);
const documentSuccessLatency = new Trend("document_success_ms", true);
const forbiddenLatency = new Trend("forbidden_ms", true);
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
  setupTimeout: "120s",
  thresholds: {
    workspace_success_ms: ["p(95)<3000"],
  },
};

export function setup() {
  const jwt = getToken("testuser", "testuser123");
  const pat = createPat(jwt, `bench-fga-${Date.now()}`);
  console.log(`Created PAT for OpenFGA benchmark: ${pat.substring(0, 12)}...`);
  return { pat };
}

export default function (data) {
  const pat = data.pat;
  const headers = { Authorization: `Bearer ${pat}` };

  // --- Success: workspace:acme (testuser is owner) → 200 ---
  group("workspace_allowed", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/acme`, { headers });
    workspaceSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "workspace 200": (r) => r.status === 200,
      "workspace is acme": (r) => r.json("workspace") === "acme",
    });
    if (ok) successCount.add(1);
  });

  // --- Success: document:doc1 (testuser is owner) → 200 ---
  group("document_allowed", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/acme/documents/doc1`, {
      headers,
    });
    documentSuccessLatency.add(res.timings.duration);

    const ok = check(res, {
      "document 200": (r) => r.status === 200,
      "document is doc1": (r) => r.json("document") === "doc1",
    });
    if (ok) successCount.add(1);
  });

  // --- Forbidden: workspace:nonexistent (no relation) → 403 ---
  group("workspace_forbidden", function () {
    const res = http.get(`${NGINX_BASE}/api/workspaces/nonexistent`, {
      headers,
    });
    forbiddenLatency.add(res.timings.duration);

    check(res, {
      "forbidden 403": (r) => r.status === 403,
    });
    forbiddenCount.add(1);
  });
}
