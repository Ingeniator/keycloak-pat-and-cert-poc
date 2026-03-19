// Shared helpers for e2e tests

const BASE_URL = "https://localhost";
const REALM = "public";
const CLIENT_ID = "ui-bff";
const CLIENT_SECRET = "bff-secret";

/**
 * Login via the Keycloak UI form.
 * Navigates to /ui/, clicks Sign in, fills credentials, waits for authenticated page.
 */
export async function loginViaUI(page, username, password) {
  await page.goto("/ui/");

  // Click the sign-in link which triggers /auth/login -> Keycloak
  await page.getByRole("link", { name: "Sign in" }).click();

  // Wait for the Keycloak login form
  await page.waitForSelector("#username", { timeout: 15000 });
  await page.locator("#username").fill(username);
  await page.locator("#password").fill(password);

  // Submit and wait for navigation back to /ui/
  await Promise.all([
    page.waitForURL("**/ui/**", { timeout: 15000 }),
    page.locator("#kc-login").click(),
  ]);

  // Wait for authenticated content — the cookie is set by the callback,
  // but the React app needs to call /auth/me to detect the session.
  // Give it time to load.
  await page.waitForTimeout(1000);
}

/**
 * Login by setting the session cookie directly via API.
 * This avoids the 4KB cookie limit issue in headless browsers.
 */
export async function loginViaAPI(page, request, username, password) {
  // Get tokens via password grant
  const tokenResp = await request.post(
    `${BASE_URL}/realms/${REALM}/protocol/openid-connect/token`,
    {
      form: {
        grant_type: "password",
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        username,
        password,
      },
      ignoreHTTPSErrors: true,
    }
  );
  const tokens = await tokenResp.json();

  // Build the cookie payload (same format as oidc.js setTokenCookie — no ID token)
  const payload = JSON.stringify({
    a: tokens.access_token,
    r: tokens.refresh_token,
    e: Date.now() + tokens.expires_in * 1000,
  });
  const encoded = Buffer.from(payload).toString("base64");
  const cookieValue = encodeURIComponent(encoded);

  // Set the cookie in the browser context
  await page.context().addCookies([
    {
      name: "__token",
      value: cookieValue,
      domain: "localhost",
      path: "/",
      httpOnly: true,
      secure: true,
      sameSite: "Lax",
    },
  ]);

  // Navigate to the UI
  await page.goto("/ui/");
  await page.waitForSelector("h1", { timeout: 10000 });
}

/**
 * Get an access token via password grant (for API-level tests).
 */
export async function getAccessToken(request, username, password) {
  const resp = await request.post(
    `${BASE_URL}/realms/${REALM}/protocol/openid-connect/token`,
    {
      form: {
        grant_type: "password",
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        username,
        password,
      },
      ignoreHTTPSErrors: true,
    }
  );
  const data = await resp.json();
  return data.access_token;
}

export { BASE_URL, REALM, CLIENT_ID, CLIENT_SECRET };
