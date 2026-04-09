// When OPENFGA_API_URL is not set, authorization is disabled (all requests pass through).
// This allows the backend to run without OpenFGA in lighter layer configurations.

const OPENFGA_API_URL = process.env.OPENFGA_API_URL;

if (!OPENFGA_API_URL) {
  console.log("OpenFGA not configured — authorization checks disabled");
}

let fgaClient = null;

async function getClient() {
  if (fgaClient) return fgaClient;

  const { OpenFgaClient } = await import("@openfga/sdk");

  // Discover store by name
  const res = await fetch(`${OPENFGA_API_URL}/stores`);
  const { stores } = await res.json();
  const store = stores?.find((s) => s.name === "demo");
  if (!store) throw new Error(`OpenFGA store "demo" not found`);

  fgaClient = new OpenFgaClient({
    apiUrl: OPENFGA_API_URL,
    storeId: store.id,
  });

  return fgaClient;
}

export async function checkPermission(userId, objectType, objectId, relation) {
  if (!OPENFGA_API_URL) return true;

  const client = await getClient();
  const { allowed } = await client.check({
    user: `user:${userId}`,
    relation,
    object: `${objectType}:${objectId}`,
  });
  return allowed;
}

export async function batchCheckPermissions(userId, checks) {
  if (!OPENFGA_API_URL) return checks.map(() => true);

  const client = await getClient();
  const { responses } = await client.batchCheck(
    checks.map((c) => ({
      user: `user:${userId}`,
      relation: c.relation,
      object: `${c.objectType}:${c.objectId}`,
    }))
  );
  return responses.map((r) => !!r.allowed);
}

export function requirePermission(objectType, paramName, relation) {
  if (!OPENFGA_API_URL) {
    return (req, res, next) => next();
  }

  return async (req, res, next) => {
    const objectId = req.params[paramName];
    const userId = req.user?.preferred_username || req.user?.sub;

    if (!userId) {
      return res.status(401).json({ error: "Not authenticated" });
    }

    try {
      const allowed = await Promise.race([
        checkPermission(userId, objectType, objectId, relation),
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error("Authorization check timed out")), 5000)
        ),
      ]);
      if (!allowed) {
        return res.status(403).json({ error: "Forbidden" });
      }
      next();
    } catch (err) {
      console.error("OpenFGA check failed:", err.message);
      return res.status(500).json({ error: "Authorization check failed" });
    }
  };
}
