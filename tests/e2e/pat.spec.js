import { test, expect } from "@playwright/test";
import { getAccessToken, BASE_URL } from "./helpers.js";

test.describe("Personal Access Tokens — API", () => {
  let patToken;
  let patId;

  test("cleanup old tokens", async ({ request }) => {
    const accessToken = await getAccessToken(request, "testuser", "testuser123");
    const listResp = await request.get(
      `${BASE_URL}/realms/public/pat-api/tokens`,
      { headers: { Authorization: `Bearer ${accessToken}` }, ignoreHTTPSErrors: true }
    );
    const data = await listResp.json();
    for (const t of (data.tokens || [])) {
      await request.delete(
        `${BASE_URL}/realms/public/pat-api/tokens/${t.id}`,
        { headers: { Authorization: `Bearer ${accessToken}` }, ignoreHTTPSErrors: true }
      );
    }
  });

  test("create PAT", async ({ request }) => {
    const accessToken = await getAccessToken(request, "testuser", "testuser123");
    expect(accessToken).toBeTruthy();

    const resp = await request.post(
      `${BASE_URL}/realms/public/pat-api/tokens`,
      {
        headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
        data: { name: "E2E Token", expiresInDays: 1 },
        ignoreHTTPSErrors: true,
      }
    );
    expect(resp.status()).toBe(201);
    const data = await resp.json();
    patToken = data.token;
    patId = data.id;
    expect(patToken).toMatch(/^pat_/);
    expect(data.name).toBe("E2E Token");
  });

  test("list tokens includes created PAT", async ({ request }) => {
    const accessToken = await getAccessToken(request, "testuser", "testuser123");
    const resp = await request.get(
      `${BASE_URL}/realms/public/pat-api/tokens`,
      { headers: { Authorization: `Bearer ${accessToken}` }, ignoreHTTPSErrors: true }
    );
    expect(resp.status()).toBe(200);
    const data = await resp.json();
    expect(data.tokens.length).toBeGreaterThan(0);
    expect(data.tokens.some((t) => t.name === "E2E Token")).toBe(true);
  });

  test("PAT works as Bearer token for /api/hello", async ({ request }) => {
    test.skip(!patToken, "No PAT created");
    const resp = await request.get(`${BASE_URL}/api/hello`, {
      headers: { Authorization: `Bearer ${patToken}` },
      ignoreHTTPSErrors: true,
    });
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.message).toContain("testuser");
  });

  test("invalid PAT returns 401", async ({ request }) => {
    const resp = await request.get(`${BASE_URL}/api/hello`, {
      headers: { Authorization: "Bearer pat_invalidtoken123456" },
      ignoreHTTPSErrors: true,
    });
    expect(resp.status()).toBe(401);
  });

  test("exchange endpoint blocked from public", async ({ request }) => {
    const resp = await request.post(
      `${BASE_URL}/realms/public/pat-api/tokens/exchange`,
      {
        headers: { "Content-Type": "application/json" },
        data: { token: "pat_test" },
        ignoreHTTPSErrors: true,
      }
    );
    expect(resp.status()).toBe(403);
  });

  test("unauthorized access rejected", async ({ request }) => {
    const resp = await request.get(
      `${BASE_URL}/realms/public/pat-api/tokens`,
      { ignoreHTTPSErrors: true }
    );
    const data = await resp.json();
    expect(data.error).toBeTruthy();
  });

  test("delete PAT", async ({ request }) => {
    test.skip(!patId, "No PAT created");
    const accessToken = await getAccessToken(request, "testuser", "testuser123");
    const resp = await request.delete(
      `${BASE_URL}/realms/public/pat-api/tokens/${patId}`,
      { headers: { Authorization: `Bearer ${accessToken}` }, ignoreHTTPSErrors: true }
    );
    expect(resp.status()).toBe(200);
  });

  test("deleted PAT returns 401", async ({ request }) => {
    test.skip(!patToken, "No PAT created");
    const resp = await request.get(`${BASE_URL}/api/hello`, {
      headers: { Authorization: `Bearer ${patToken}` },
      ignoreHTTPSErrors: true,
    });
    expect(resp.status()).toBe(401);
  });
});
