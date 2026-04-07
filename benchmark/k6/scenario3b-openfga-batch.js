// Scenario 3b: PAT + nginx + OpenFGA batch check
//
// Same as scenario 3 but uses a single POST /check-permissions call with all
// tuples batched, instead of 3 separate endpoint calls each doing 1 check.

import http from "k6/http";
import { check, group } from "k6";
import { Trend, Counter } from "k6/metrics";
import { getToken, createPat, NGINX_BASE } from "./helpers.js";

const batchCheckLatency = new Trend("batch_check_ms", true);
const successCount = new Counter("success_total");

export const options = {
  scenarios: {
    openfga_batch: {
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
    batch_check_ms: ["p(95)<2000"],
  },
};

export function setup() {
  const jwt = getToken("testuser", "testuser123");
  const pat = createPat(jwt, `bench-batch-${Date.now()}`);
  return { pat };
}

export default function (data) {
  const headers = {
    Authorization: `Bearer ${data.pat}`,
    "Content-Type": "application/json",
  };

  // Single batch call checking all 3 tuples at once
  const payload = JSON.stringify({
    checks: [
      { objectType: "workspace", objectId: "acme", relation: "viewer" },
      { objectType: "document", objectId: "doc1", relation: "viewer" },
      { objectType: "workspace", objectId: "nonexistent", relation: "viewer" },
    ],
  });

  const res = http.post(`${NGINX_BASE}/api/check-permissions`, payload, {
    headers,
  });
  batchCheckLatency.add(res.timings.duration);

  const ok = check(res, {
    "status is 200": (r) => r.status === 200,
    "has results": (r) => {
      try {
        return r.json("results").length === 3;
      } catch (e) {
        return false;
      }
    },
    "acme allowed": (r) => {
      try {
        return r.json("results")[0].allowed === true;
      } catch (e) {
        return false;
      }
    },
    "nonexistent denied": (r) => {
      try {
        return r.json("results")[2].allowed === false;
      } catch (e) {
        return false;
      }
    },
  });
  if (ok) successCount.add(1);
}
