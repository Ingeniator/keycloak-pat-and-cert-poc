import { OpenFgaClient } from "@openfga/sdk";

const OPENFGA_API_URL = process.env.OPENFGA_API_URL || "http://openfga:8080";
const STORE_NAME = "demo";

let fgaClient = null;

async function getClient() {
  if (fgaClient) return fgaClient;

  // Discover store by name
  const res = await fetch(`${OPENFGA_API_URL}/stores`);
  const { stores } = await res.json();
  const store = stores?.find((s) => s.name === STORE_NAME);
  if (!store) throw new Error(`OpenFGA store "${STORE_NAME}" not found`);

  fgaClient = new OpenFgaClient({
    apiUrl: OPENFGA_API_URL,
    storeId: store.id,
  });

  return fgaClient;
}

export async function checkPermission(userId, objectType, objectId, relation) {
  const client = await getClient();
  const { allowed } = await client.check({
    user: `user:${userId}`,
    relation,
    object: `${objectType}:${objectId}`,
  });
  return allowed;
}

export function requirePermission(objectType, paramName, relation) {
  return async (req, res, next) => {
    const objectId = req.params[paramName];
    const userId = req.user?.preferred_username || req.user?.sub;

    if (!userId) {
      return res.status(401).json({ error: "Not authenticated" });
    }

    try {
      const allowed = await checkPermission(userId, objectType, objectId, relation);
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
