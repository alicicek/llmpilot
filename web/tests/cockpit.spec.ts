import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// Proof happy path, against the sandboxed daemon (single binary serving
// the embedded cockpit + API): open → board renders fixture accounts → book
// a fresh window → persisted via API → keyboard-move it (PUT) → switch
// account from the UI → SSE updates the page without reload.

test.describe.configure({ mode: "serial" });

test("board renders the sandbox fleet from the daemon", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("a@example.dev")).toBeVisible();
  await expect(page.getByText("b@example.dev")).toBeVisible();
  // runway bars carry real fixture percentages (usage-a.json via the poller)
  await expect(page.getByText(/%/).first()).toBeVisible();
  await expect(page.getByText("Daemon active")).toBeVisible();
});

test("book a fresh window → persisted → SSE renders it live", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("a@example.dev")).toBeVisible();

  const before = (await (await page.request.get("/v1/schedules")).json()) as unknown[];

  await page.getByRole("button", { name: "＋ Fresh window" }).click();
  await page.getByRole("menuitem").first().click();

  await expect
    .poll(async () => ((await (await page.request.get("/v1/schedules")).json()) as unknown[]).length)
    .toBe(before.length + 1);

  // SSE pushed the new schedule — a slider thumb appears with NO reload.
  await expect(page.getByRole("slider").first()).toBeVisible();
});

test("keyboard-move a reset persists via PUT", async ({ page }) => {
  await page.goto("/");
  const thumb = page.getByRole("slider").first();
  await expect(thumb).toBeVisible();

  const schedules = (await (await page.request.get("/v1/schedules")).json()) as {
    id: string;
    hour: number;
    minute: number;
  }[];
  const start = schedules[0];

  await thumb.focus();
  await page.keyboard.press("ArrowRight");

  await expect
    .poll(async () => {
      const now = (await (await page.request.get("/v1/schedules")).json()) as {
        id: string;
        hour: number;
        minute: number;
      }[];
      const moved = now.find((s) => s.id === start.id);
      return moved ? moved.hour * 60 + moved.minute : -1;
    })
    .toBe((start.hour * 60 + start.minute + 15) % 1440);
});

test("switch account from the UI (sandboxed swap end-to-end)", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("ACTIVE", { exact: true })).toBeVisible();
  const initial = ((await (await page.request.get("/v1/state")).json()) as { active_id: string })
    .active_id;

  await page.getByRole("button", { name: /switch/i }).first().click();

  // the swap goes through the real switcher (throwaway keychain) and the
  // active account changes, surfaced over SSE.
  await expect
    .poll(async () => {
      const st = (await (await page.request.get("/v1/state")).json()) as { active_id: string };
      return st.active_id;
    }, { timeout: 20_000 })
    .not.toBe(initial);
});

test("axe: board (live) has no serious violations", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("a@example.dev")).toBeVisible();
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious, JSON.stringify(serious, null, 1)).toEqual([]);
});

test("axe: designed fixture states have no serious violations", async ({ page }) => {
  await page.goto("/?fixtures=1");
  await expect(page.getByText("kai@example.dev")).toBeVisible();
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious, JSON.stringify(serious, null, 1)).toEqual([]);
});
