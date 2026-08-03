import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// The pro surfaces run entirely off the ?pro= license fixture + ?fixtures= board
// fixture — no daemon license calls — so these are deterministic and network
// idle. cancel/recover are the exceptions (they POST to the daemon) and are
// route-mocked where exercised.

test.describe.configure({ mode: "serial" });
// Money copy renders locale-resolved currency and dates; pin both so the
// consent strings under test are deterministic.
test.use({ locale: "en-GB", timezoneId: "UTC" });

test("onboarding → trial offer → ✕ surfaces the decline offer → checkout handoff → activation", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");

  // Onboarding: pain framing → the autopilot shown working → the ask.
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /switches before you are blocked/i })).toBeVisible();
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();

  // The single offer: trial-first full rung with timeline + reminder choice.
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  // Dates derive from the CLOCK at render (now + trial_days), not the
  // quote's fetch-time charge_date — Stripe anchors the trial at checkout
  // completion, so render-time is the freshest honest date. The reminder
  // choice moves the shown date by a real day. (Runner and page share
  // TZ=UTC + en-GB, so both format the same strings.)
  const DAY = 24 * 60 * 60 * 1000;
  const gb = (daysFromNow: number) =>
    new Date(Date.now() + daysFromNow * DAY).toLocaleDateString("en-GB", { day: "numeric", month: "long" });
  await expect(page.getByText(gb(3))).toHaveCount(2); // 1-day default: chip date + timeline stop
  await page.getByRole("button", { name: /2 days before/ }).click();
  await expect(page.getByText(gb(2))).toHaveCount(2);
  // The removed rungs stay removed.
  await expect(page.getByRole("button", { name: "Start without a card" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Keep using the free tools for now" })).toBeHidden();

  // First ✕ is the reject: the standing lower price surfaces, honestly framed.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await expect(page.getByText("£9.99")).toBeVisible(); // struck beside the new price

  // CTA → checkout hands off a URL (no navigation in fixture mode).
  await page.getByRole("button", { name: "Start the trial at £5.99" }).click();
  await expect(page.getByTestId("checkout-handoff")).toBeVisible();

  // The silent activation lands over SSE — onboarding unmounts, the board shows.
  await expect(page.getByRole("button", { name: "Start the trial at £5.99" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("second ✕ closes the paywall for real — free tools remain, no re-trap", async ({ page }) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await page.getByRole("button", { name: "Show me the autopilot" }).click();
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();

  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("paused paywall (trial restart) states the full consent: dates, price, reminder choice", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /Your trial ended/ })).toBeVisible();
  // Restarting a card-upfront trial owes the same consent as the first one.
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await expect(page.getByText("When should we remind you?").first()).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await expect(page.getByRole("button", { name: "Start the 4-day free trial" })).toBeVisible();
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
