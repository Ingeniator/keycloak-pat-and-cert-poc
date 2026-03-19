import { test, expect } from "@playwright/test";

test.describe("Login flow", () => {
  test("shows sign-in page when not authenticated", async ({ page }) => {
    await page.goto("/ui/");
    await expect(page.getByRole("link", { name: "Sign in" })).toBeVisible();
  });

  test("redirects to Keycloak login form", async ({ page }) => {
    await page.goto("/auth/login");
    await expect(page.locator("#username")).toBeVisible();
    await expect(page.locator("#password")).toBeVisible();
  });

  test("Keycloak accepts credentials and redirects to callback", async ({ page }) => {
    await page.goto("/auth/login");
    await page.locator("#username").fill("testuser");
    await page.locator("#password").fill("testuser123");
    await page.locator("#kc-login").click();

    // After successful auth, Keycloak redirects to /auth/callback which sets
    // the session cookie and redirects to /ui/. Verify we reach /ui/.
    await page.waitForURL("**/ui/**", { timeout: 15000 });
    // The page should be /ui/ (callback completed successfully)
    expect(page.url()).toContain("/ui/");
  });
});
