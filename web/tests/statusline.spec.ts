import { expect, test } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

// Statusline editor against the REAL sandboxed daemon: the preview is
// the daemon's Go renderer, apply writes statusline.json, and the binary's
// output changes (the shell script asserts that last step after this run).

async function openEditor(page: import("@playwright/test").Page) {
  await page.goto("/");
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByRole("button", { name: "Customize statusline" }).click();
  await expect(page.getByTestId("sl-preview")).not.toContainText("rendering…", {
    timeout: 10_000,
  });
}

test("editor: toggle a segment → preview updates → apply → config persists", async ({
  page,
  request,
}) => {
  await openEditor(page);

  // default runway line renders live fleet data from the sandbox store
  const preview = page.getByTestId("sl-preview");
  await expect(preview).toContainText("[acct");

  // add the model segment: sample stdin renders "Fable" in the preview
  await expect(preview).not.toContainText("Fable");
  await page.getByRole("button", { name: "Add Model" }).click();
  await expect(preview).toContainText("Fable");

  await page.getByRole("button", { name: "Apply changes" }).click();
  await expect(page.getByText("Applied — your line updates on its next refresh.")).toBeVisible();

  const res = await request.get("/v1/statusline/config");
  expect(res.ok()).toBeTruthy();
  const doc = (await res.json()) as { config: { segments: { id: string }[] } };
  expect(doc.config.segments.map((s) => s.id)).toContain("model");
  // NOTE: the model segment stays applied on purpose — the shell script
  // asserts the BINARY's output now renders it (apply → output changes).
});

test("editor: preset switch previews the fleet segments", async ({ page }) => {
  await openEditor(page);
  await page.getByRole("button", { name: /Pilot/ }).click();
  // autopilot state comes from the daemon-backed segment set
  await expect(page.getByTestId("sl-preview")).toContainText("auto:on");
  // discarding returns to the saved config
  await page.getByRole("button", { name: "Discard changes" }).click();
  await expect(page.getByTestId("sl-preview")).not.toContainText("auto:on");
});

test("editor: reorder via keyboard buttons updates the preview order", async ({ page }) => {
  await openEditor(page);
  // the model segment is in the saved line (applied by the first test)
  const preview = page.getByTestId("sl-preview");
  await expect(preview).toContainText("Fable");
  const before = await preview.innerText();
  expect(before.indexOf("Fable")).toBeGreaterThan(before.indexOf("[acct"));
  await page.getByRole("button", { name: "Move Model up" }).click();
  await page.getByRole("button", { name: "Move Model up" }).click();
  await expect
    .poll(async () => {
      const text = await preview.innerText();
      return text.indexOf("Fable") < text.indexOf("[acct");
    })
    .toBeTruthy();
});

test("axe: statusline editor has no serious violations", async ({ page }) => {
  await openEditor(page);
  const results = await new AxeBuilder({ page }).analyze();
  const serious = results.violations.filter((v) => ["serious", "critical"].includes(v.impact ?? ""));
  expect(serious).toEqual([]);
});
