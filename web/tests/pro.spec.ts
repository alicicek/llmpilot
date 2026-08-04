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

// Dates derive from the CLOCK at render (now + trial_days), not the quote's
// fetch-time charge_date — Stripe anchors the trial at checkout completion,
// so render-time is the freshest honest date. (Runner and page share TZ=UTC
// + en-GB, so both format the same strings.)
const DAY = 24 * 60 * 60 * 1000;
const gb = (daysFromNow: number) =>
  new Date(Date.now() + daysFromNow * DAY).toLocaleDateString("en-GB", { day: "numeric", month: "long" });

test("the wall → the offer → the reminder screen → checkout handoff → activation facts", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");

  // The wall: pain named, the switch shown happening (two fixture lanes +
  // the ACTIVE badge), the free/paid split said out loud.
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await expect(page.getByText("kai@example.dev").first()).toBeVisible();
  await expect(page.getByText("mira@example.dev")).toBeVisible();
  // Both lanes carry the badge (the idle one invisible, for stable layout);
  // the first lane is the active account at open.
  await expect(page.getByText("ACTIVE").first()).toBeVisible();
  await expect(page.getByText(/Watching and switching by hand are free/)).toBeVisible();
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();

  // The offer: terms only — the reminder control moved to its own screen.
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await expect(page.getByText("When should we remind you?")).toBeHidden();
  // The removed rungs stay removed.
  await expect(page.getByRole("button", { name: "Start without a card" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Keep using the free tools for now" })).toBeHidden();

  // The reminder screen: the headline IS the confirmation — it restates the
  // live choice as a real date and follows the control.
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByText("BEFORE ANYTHING IS CHARGED")).toBeVisible();
  await expect(page.getByTestId("remind-headline")).toHaveText(`We'll remind you on ${gb(3)}`);
  await page.getByRole("button", { name: /2 days before/ }).click();
  await expect(page.getByTestId("remind-headline")).toHaveText(`We'll remind you on ${gb(2)}`);
  // The commit screen states the exact amount and the charge date.
  await expect(page.getByText(`£9.99 once on ${gb(4)}`)).toBeVisible();

  // The commit CTA lives HERE, not on the offer — and the reminder choice
  // RIDES the checkout call (the fixture handoff echoes what was posted).
  await page.getByRole("button", { name: "Start the 4-day free trial" }).click();
  await expect(page.getByTestId("checkout-handoff")).toBeVisible();
  await expect(page.getByTestId("checkout-handoff")).toHaveAttribute(
    "data-url",
    /pay\/full\?remind=2$/,
  );

  // The silent activation lands over SSE — facts only, then the cockpit.
  await expect(page.getByText("Pro is on")).toBeVisible();
  await expect(page.getByText("Watching 3 accounts")).toBeVisible();
  await expect(page.getByText("Switches you before the wall")).toBeVisible();
  await page.getByRole("button", { name: "Open the cockpit" }).click();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("✕ surfaces the decline offer once; its commit CTA carries the lower price; the second ✕ closes for real", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();

  // First ✕ is the reject: the standing lower price surfaces, honestly framed.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await expect(page.getByText("£9.99")).toBeVisible(); // struck beside the new price

  // The reminder screen commits at the declined price.
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByRole("button", { name: "Start the trial at £5.99" })).toBeVisible();

  // Second ✕ (from the reminder screen) closes for real — free tools remain.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("button", { name: "Start the trial at £5.99" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("double ✕ on the offer closes without a re-trap", async ({ page }) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("paused paywall (trial restart) states the full consent and walks the same reminder screen", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /Your trial ended/ })).toBeVisible();
  // Restarting a card-upfront trial owes the same consent as the first one.
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByRole("group", { name: "When should we remind you?" })).toBeVisible();
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

// The axe passes run under reduced motion: entrance fades otherwise blend
// text toward the background at sample time (a transient, not a real
// contrast defect) — and this also exercises the reduced-motion rendering
// the motion budget requires.

test("axe: the wall has no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=paywall");
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: offer and reminder screens have no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=paywall");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await noSeriousAxe(page);
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByText("BEFORE ANYTHING IS CHARGED")).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: Settings → License (trial) has no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=trial");
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByText("Free trial")).toBeVisible();
  await noSeriousAxe(page);
});
