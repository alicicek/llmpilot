import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// The pro surfaces run entirely off the ?pro= license fixture + ?fixtures= board
// fixture — no daemon license calls — so these are deterministic and network
// idle. cancel/recover are the exceptions (they POST to the daemon) and are
// route-mocked where exercised.

test.describe.configure({ mode: "serial" });

test("onboarding → paywall ladder walk → checkout handoff → activation flips the UI", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");

  // Onboarding: pain framing → the autopilot shown working → the paywall.
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /switches before you are blocked/i })).toBeVisible();
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();

  // Ladder rung 1 — full price, charged once.
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  // Decline → rung 2, discounted trial with an exact charge date.
  await page.getByRole("button", { name: "Try it free first" }).click();
  await expect(page.getByText(/charged once on/i)).toBeVisible();
  await expect(page.getByText(/8-day free trial/i)).toBeVisible();
  // Decline → rung 3, no-card trial (bottom rung, no further decline).
  await page.getByRole("button", { name: "Start without a card" }).click();
  await expect(page.getByText(/no card\. The autopilot turns on now/i)).toBeVisible();

  // CTA → checkout hands off a URL (no navigation in fixture mode).
  await page.getByRole("button", { name: "Start the free trial" }).click();
  await expect(page.getByTestId("checkout-handoff")).toBeVisible();

  // The silent activation lands over SSE — onboarding unmounts, the board shows.
  await expect(page.getByRole("button", { name: "Start the free trial" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("Settings → License shows the trial and cancels it in one click", async ({ page }) => {
  let cancelCalled = false;
  await page.route("**/v1/license/cancel", async (route) => {
    cancelCalled = true;
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ status: "lapsed" }),
    });
  });

  await page.goto("/?fixtures=1&pro=trial");
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByText("Free trial")).toBeVisible();
  await expect(page.getByText(/days left/i)).toBeVisible();

  await page.getByRole("button", { name: "Cancel trial" }).click();
  await expect(page.getByText(/Cancel the trial\?/i)).toBeVisible();
  await page.getByRole("button", { name: "Cancel the trial" }).click();
  await expect.poll(() => cancelCalled).toBe(true);
});

test("recover-by-email answers with uniform copy", async ({ page }) => {
  await page.route("**/v1/license/recover", (route) =>
    route.fulfill({ status: 202, contentType: "application/json", body: '{"ok":true}' }),
  );
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByLabel("Email to recover a purchase").fill("someone@example.com");
  await page.getByRole("button", { name: "Restore by email" }).click();
  await expect(page.getByText(/If that email has a purchase/i)).toBeVisible();
});

test("recovery code restores Pro from Settings → License", async ({ page }) => {
  let claimBody: unknown;
  await page.route("**/v1/license/recover/claim", async (route) => {
    claimBody = route.request().postDataJSON();
    await route.fulfill({ status: 200, contentType: "application/json", body: '{"status":"lifetime"}' });
  });
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByLabel("Recovery code from your email").fill("abc123deadbeef");
  await page.getByRole("button", { name: "Restore with code" }).click();
  await expect(page.getByText(/Restored — Pro is back on/i)).toBeVisible();
  expect(claimBody).toEqual({ token: "abc123deadbeef" });
});

async function noSeriousAxe(page: import("@playwright/test").Page) {
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious, JSON.stringify(serious, null, 1)).toEqual([]);
}

test("axe: onboarding has no serious violations", async ({ page }) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: paywall ladder has no serious violations", async ({ page }) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: Settings → License (trial) has no serious violations", async ({ page }) => {
  await page.goto("/?fixtures=1&pro=trial");
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByText("Free trial")).toBeVisible();
  await noSeriousAxe(page);
});
