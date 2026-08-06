import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";
import { walkBenefits, walkProblem, walkToPrice, walkToPriceFromStart } from "./flow.ts";

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

test("the full ladder: problem → benefits → receipt → reminder → price → handoff → activation facts", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");

  // ① the wall: the pain named, on the product's own runway bar.
  await expect(page.getByRole("heading", { name: /You know this moment/ })).toBeVisible();
  await expect(page.getByTestId("edu-wall-lanes")).toBeVisible();
  // No exit before the price: the corridor is one-way (SPEC-127 D9).
  await expect(page.getByTestId("paywall-close")).toBeHidden();
  await page.getByRole("button", { name: "Continue" }).click();

  // ② the blind spot: three fixture identities, so the pair variant.
  await expect(page.getByTestId("edu-blind-pair")).toBeVisible();
  await expect(page.getByText(/3 Claude accounts are signed in on this Mac/)).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // ④ the switch, on the real fixture lanes.
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
  await expect(page.getByText("kai@example.dev").first()).toBeVisible();
  await expect(page.getByText("mira@example.dev")).toBeVisible();
  await expect(page.getByText("ACTIVE").first()).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // ⑤ the scheduled window: the real board, and the bar that proves it.
  await expect(page.getByTestId("edu-windows-board")).toBeVisible();
  await expect(page.getByTestId("edu-windows-block")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();

  // ⑥ the receipt: the free column is honestly full, and THIS is where the
  // trial is announced — the reminder screen would be a non-sequitur first.
  await expect(page.getByTestId("receipt-table")).toBeVisible();
  await expect(page.getByText("Watching and switching by hand stay free, forever.")).toBeVisible();
  await expect(page.getByTestId("receipt-trial")).toContainText("free for 4 days");
  // Still no price this far in.
  await expect(page.getByText(/£9\.99/)).toHaveCount(0);
  await page.getByRole("button", { name: "Continue" }).click();

  // ⑦ the reminder: it names the trial it is about, states NO amount, and
  // locks Continue until a day is actually chosen.
  await expect(page.getByTestId("remind-headline")).toHaveText(`Your 4 free days end ${gb(4)}.`);
  await expect(page.getByText(/£9\.99/)).toHaveCount(0);
  await expect(page.getByTestId("remind-continue")).toBeDisabled();
  await page.getByRole("button", { name: "2 days before" }).click();
  await expect(page.getByText(`The amber dot is your reminder email — ${gb(2)}`)).toBeVisible();
  await expect(page.getByTestId("remind-continue")).toBeEnabled();
  await page.getByTestId("remind-continue").click();

  // ⑧ the price: every consent fact on the one screen with the money button.
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();
  await expect(page.getByText(/£9\.99/).first()).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await expect(page.getByText(/LINK\.COM\* LLMPILOT\.DEV/)).toBeVisible();
  // The removed rungs stay removed.
  await expect(page.getByRole("button", { name: "Start without a card" })).toBeHidden();
  await expect(page.getByRole("button", { name: "Keep using the free tools for now" })).toBeHidden();

  // Checkout starts HERE, and the reminder choice made two screens back
  // RIDES the call (the fixture handoff echoes what was posted).
  await page.getByTestId("checkout-start").click();
  await expect(page.getByTestId("checkout-handoff")).toBeVisible();
  await expect(page.getByTestId("checkout-handoff")).toHaveAttribute(
    "data-url",
    /pay\/full\?remind=2$/,
  );

  // ⑨ the silent activation lands over SSE — facts only, then the cockpit.
  await expect(page.getByText("Pro is on")).toBeVisible();
  await expect(page.getByText("Watching 3 accounts")).toBeVisible();
  await expect(page.getByText("Switches you before the wall")).toBeVisible();
  await page.getByRole("button", { name: "Open the cockpit" }).click();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("✕ on the price surfaces the decline offer once; the second ✕ closes for real", async ({
  page,
}) => {
  await page.goto("/?fixtures=1&pro=paywall");
  await walkToPriceFromStart(page);
  await expect(page.getByRole("heading", { name: "Try the autopilot free for 4 days" })).toBeVisible();

  // First ✕ is the reject: the standing lower price surfaces, honestly framed.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: "Same trial, lower price" })).toBeVisible();
  await expect(page.getByText(/£9\.99/).first()).toBeVisible(); // struck beside the new price
  await expect(page.getByRole("button", { name: "Start the trial at £5.99" })).toBeVisible();

  // Second ✕ closes for real — the free tools remain.
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("button", { name: "Start the trial at £5.99" })).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("the reminder day can still be changed after the price is seen", async ({ page }) => {
  // Forward-only is not the same as trapped: the choice made on ⑦ is
  // reachable again from ⑧ without leaving the flow.
  await page.goto("/?fixtures=1&pro=paywall");
  await walkToPriceFromStart(page, 1);
  await page.getByRole("button", { name: "Change the reminder day" }).click();
  await expect(page.getByTestId("remind-headline")).toBeVisible();
  await page.getByRole("button", { name: "2 days before" }).click();
  await page.getByTestId("remind-continue").click();
  await page.getByTestId("checkout-start").click();
  await expect(page.getByTestId("checkout-handoff")).toHaveAttribute(
    "data-url",
    /pay\/full\?remind=2$/,
  );
});

test("paused paywall (trial restart) states the full consent, keeps an exit, and walks to a commit", async ({
  page,
}) => {
  // A lapsed licence never enters the guided flow (that needs status
  // "none"), so this is the banner-opened overlay — no education screens,
  // and every screen keeps its own ✕ because the corridor rule is a
  // property of onboarding, not of the paywall.
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /Your trial ended/ })).toBeVisible();
  // Restarting a card-upfront trial owes the same consent as the first one.
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await expect(page.getByText("No payment due today.")).toBeVisible();
  await expect(page.getByTestId("paywall-close")).toBeVisible();
  await page.getByRole("button", { name: "Try it free for 4 days" }).click();
  await expect(page.getByRole("group", { name: "When should we remind you?" })).toBeVisible();
  await page.getByRole("button", { name: "1 day before" }).click();
  await page.getByTestId("remind-continue").click();
  await expect(page.getByTestId("checkout-start")).toBeVisible();
});

test("a lapsed user can always leave the paused screen", async ({ page }) => {
  // The 1.2.6 paused screen shipped with no ✕ at all. Harmless then; a trap
  // now that SPEC-127 D9 has removed every other exit.
  await page.goto("/?fixtures=1&pro=paused");
  await page.getByRole("button", { name: "Turn on the autopilot" }).click();
  await expect(page.getByRole("heading", { name: /Your trial ended/ })).toBeVisible();
  await page.getByTestId("paywall-close").click();
  await expect(page.getByRole("heading", { name: /Your trial ended/ })).toBeHidden();
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

// The axe passes run under reduced motion: entrance fades otherwise blend
// text toward the background at sample time (a transient, not a real
// contrast defect) — and this also exercises the reduced-motion rendering
// the motion budget requires.

test("axe: the education screens have no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=paywall");
  await expect(page.getByRole("heading", { name: /You know this moment/ })).toBeVisible();
  await noSeriousAxe(page);
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId(/^edu-blind-/)).toBeVisible();
  await noSeriousAxe(page);
  await page.getByRole("button", { name: "Continue" }).click();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId("edu-windows-board")).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: receipt, reminder and price screens have no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=paywall");
  await walkProblem(page);
  await walkBenefits(page);
  await expect(page.getByTestId("receipt-table")).toBeVisible();
  await noSeriousAxe(page);
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId("remind-headline")).toBeVisible();
  await noSeriousAxe(page);
  await page.getByRole("button", { name: "1 day before" }).click();
  await page.getByTestId("remind-continue").click();
  await expect(page.getByText(/charged once\. We cancel the renewal/i)).toBeVisible();
  await noSeriousAxe(page);
});

test("axe: Settings → License (trial) has no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto("/?fixtures=1&pro=trial");
  await page.getByRole("button", { name: "Settings" }).click();
  await expect(page.getByText("Free trial")).toBeVisible();
  await noSeriousAxe(page);
});
