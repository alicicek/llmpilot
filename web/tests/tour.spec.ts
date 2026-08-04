import { test, expect, type Page } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// The guided tour points at REAL cockpit elements. This file drops the
// config's "already seen the tour" storage so these run as a genuine
// first-time user — that auto-open IS the behavior under test.

test.use({
  locale: "en-GB",
  timezoneId: "UTC",
  storageState: { cookies: [], origins: [] },
});

// The fixture harnesses never auto-open the guide (the README recorder drives
// them), so component-level walks ask for it explicitly.
const TOURED = "/?fixtures=1&pro=lifetime&tour=1";

test("the guide walks the real cockpit and ends", async ({ page }) => {
  await page.goto(TOURED);

  // Step 1 spotlights the ACTIVE account's own runway bars — the claim the
  // product makes is that these numbers are real, so the guide points at
  // them rather than describing them.
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
  await expect(page.getByText("This is your real usage")).toBeVisible();

  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByText("Move to an account with room")).toBeVisible();
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByText("Open a window on your own clock")).toBeVisible();
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByText("It keeps running without this window")).toBeVisible();

  // The last step commits instead of offering an escape.
  await expect(page.getByRole("button", { name: "Skip the guide" })).toBeHidden();
  await page.getByRole("button", { name: "Got it" }).click();
  await expect(page.getByText("STEP 4 OF 4")).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("keyboard walks one step at a time", async ({ page }) => {
  // The Next button holds focus, so Enter already activates it — a window
  // handler that also advanced would skip a step to nobody's knowledge.
  await page.goto(TOURED);
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(page.getByText("STEP 2 OF 4")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByText("STEP 2 OF 4")).toBeHidden();
});

test("skip ends the guide at any step", async ({ page }) => {
  await page.goto(TOURED);
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
  await page.getByRole("button", { name: "Skip the guide" }).click();
  await expect(page.getByText("STEP 1 OF 4")).toBeHidden();
  await expect(page.getByText("alex@example.dev")).toBeVisible();
});

test("axe: the guide overlay has no serious violations", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(TOURED);
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious, JSON.stringify(serious, null, 1)).toEqual([]);
});

test("a one-account fleet skips the step whose control does not exist", async ({ page }) => {
  // Nothing to switch TO, so the switch step has no target. The guide must
  // renumber rather than teach a control that is not on screen.
  await page.goto("/?fixtures=solo&pro=lifetime&tour=1");
  await expect(page.getByText("STEP 1 OF 3")).toBeVisible();
  await page.getByRole("button", { name: "Next" }).click();
  await expect(page.getByText("Open a window on your own clock")).toBeVisible();
});

// ---- the real thing: a live daemon, no fixture board, no forcing ----

const iso = "2026-07-22T14:32:00Z";
const acct = (id: string, email: string, pct: number) => ({
  id,
  label: id,
  email,
  config_dir: `/Users/x/.claude-${id}`,
  keychain_service: "svc",
  pinned: false,
  snapshot: { account_id: id, as_of: iso, buckets: [{ kind: "session", percent: pct }] },
});
const fleet = {
  accounts: [acct("one", "one@example.dev", 71), acct("two", "two@example.dev", 8)],
  active_id: "one",
  events: [],
  as_of: iso,
  schedules: [],
};

async function mockDaemon(page: Page, license: string) {
  await page.route("**/v1/state", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(fleet) }),
  );
  await page.route("**/v1/events", (r) =>
    r.fulfill({
      status: 200,
      contentType: "text/event-stream",
      body: `retry: 10000\nevent: state\ndata: ${JSON.stringify(fleet)}\n\n`,
    }),
  );
  await page.route("**/v1/detect", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/schedules", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: "[]" }),
  );
  await page.route("**/v1/config", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: "{}" }),
  );
  await page.route("**/v1/license", (r) =>
    r.fulfill({ status: 200, contentType: "application/json", body: license }),
  );
}

const LICENSED = '{"available":true,"active":true,"status":"lifetime","nocard_trial_used":false}';
const UNLICENSED = '{"available":true,"active":false,"status":"none","nocard_trial_used":false}';

test("on a real cockpit the guide opens itself, then never again", async ({ page }) => {
  await mockDaemon(page, LICENSED);
  await page.goto("/");
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
  await page.getByRole("button", { name: "Skip the guide" }).click();

  // Seen once, gone for good — a guide that reopens every launch is a nag.
  await page.goto("/");
  await expect(page.getByText("one@example.dev")).toBeVisible();
  await expect(page.getByText("STEP 1 OF 4")).toBeHidden();

  // ...but it stays reachable on purpose.
  await page.getByRole("button", { name: "Show me around" }).click();
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
});

test("the guide follows the first-run flow rather than being consumed by it", async ({ page }) => {
  // An unlicensed arrival gets the first-run flow, which suppresses the
  // board entirely. The guide must still be waiting on the other side of it
  // — this is the path a new paying user actually takes.
  await mockDaemon(page, UNLICENSED);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  await page.getByTestId("wall-close").click();

  await expect(page.getByText("one@example.dev")).toBeVisible();
  await expect(page.getByText("STEP 1 OF 4")).toBeVisible();
});

test("the wall keeps an exit of its own", async ({ page }) => {
  await mockDaemon(page, UNLICENSED);
  await page.goto("/");
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeVisible();
  // The toolbar and board are suppressed behind it, so this ✕ is the only
  // way out until two screens deeper.
  await page.getByTestId("wall-close").click();
  await expect(page.getByRole("heading", { name: "Never hit a wall mid-thought" })).toBeHidden();
  await expect(page.getByText("one@example.dev")).toBeVisible();
});
