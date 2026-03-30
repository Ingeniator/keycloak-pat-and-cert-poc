import { readFileSync } from "node:fs";

const OPENFGA_API_URL = process.env.OPENFGA_API_URL || "http://openfga:8080";
const STORE_NAME = "demo";

async function waitForReady(maxRetries = 30) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const res = await fetch(`${OPENFGA_API_URL}/healthz`);
      if (res.ok) return;
    } catch {}
    console.log(`Waiting for OpenFGA... (${i + 1}/${maxRetries})`);
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error("OpenFGA not ready");
}

async function findOrCreateStore() {
  const res = await fetch(`${OPENFGA_API_URL}/stores`);
  const { stores } = await res.json();
  const existing = stores?.find((s) => s.name === STORE_NAME);
  if (existing) {
    console.log(`Store "${STORE_NAME}" already exists: ${existing.id}`);
    return existing.id;
  }

  const createRes = await fetch(`${OPENFGA_API_URL}/stores`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: STORE_NAME }),
  });
  const store = await createRes.json();
  console.log(`Created store "${STORE_NAME}": ${store.id}`);
  return store.id;
}

async function writeModel(storeId) {
  const model = JSON.parse(readFileSync(new URL("./model.json", import.meta.url), "utf-8"));

  const res = await fetch(`${OPENFGA_API_URL}/stores/${storeId}/authorization-models`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(model),
  });
  const result = await res.json();
  if (!res.ok) {
    console.error("Failed to write model:", JSON.stringify(result, null, 2));
    process.exit(1);
  }
  console.log(`Authorization model written: ${result.authorization_model_id}`);
  return result.authorization_model_id;
}

async function writeTuples(storeId) {
  const tuples = [
    { user: "user:testuser", relation: "owner", object: "workspace:acme" },
    { user: "workspace:acme", relation: "workspace", object: "document:doc1" },
    { user: "user:testuser", relation: "owner", object: "document:doc1" },
  ];

  const res = await fetch(`${OPENFGA_API_URL}/stores/${storeId}/write`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ writes: { tuple_keys: tuples } }),
  });

  if (res.ok) {
    console.log(`Wrote ${tuples.length} tuples`);
  } else {
    const body = await res.json();
    // Ignore duplicate tuple errors (already seeded)
    if (res.status === 400 && JSON.stringify(body).includes("cannot write a tuple")) {
      console.log("Tuples already exist, skipping");
    } else {
      console.error("Failed to write tuples:", JSON.stringify(body, null, 2));
      process.exit(1);
    }
  }
}

async function main() {
  console.log(`OpenFGA API: ${OPENFGA_API_URL}`);
  await waitForReady();
  const storeId = await findOrCreateStore();
  await writeModel(storeId);
  await writeTuples(storeId);
  console.log("OpenFGA bootstrap complete!");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
