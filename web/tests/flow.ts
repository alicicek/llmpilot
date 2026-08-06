import { expect, type Page } from "@playwright/test";

// SPEC-127's guided ladder, in the order a first run walks it:
//
//   ① the wall   ② the blind spot   ③ your accounts   ④ the switch
//   ⑤ fresh windows   ⑥ the receipt   ⑦ the reminder   ⑧ the price
//   ⑨ Pro is on
//
// ③ appears only when the fleet started empty, so specs step through it
// themselves; everything else is shared here.

/** ①② — the two problem screens that open every guided run. */
export async function walkProblem(page: Page) {
  await expect(page.getByRole("heading", { name: /You know this moment/ })).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId(/^edu-blind-/)).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
}

/** ④⑤ — the switch demo, then the scheduled window on the real board. */
export async function walkBenefits(page: Page) {
  await expect(page.getByRole("heading", { name: /It moves you/ })).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId("edu-windows-board")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
}

/** ⑥⑦ — the receipt, then the reminder choice, landing on ⑧ the price. */
export async function walkToPrice(page: Page, remindDays: 1 | 2 = 1) {
  await expect(page.getByTestId("receipt-table")).toBeVisible();
  await page.getByRole("button", { name: "Continue" }).click();
  await expect(page.getByTestId("remind-headline")).toBeVisible();
  await page
    .getByRole("button", { name: remindDays === 2 ? "2 days before" : "1 day before" })
    .click();
  await page.getByTestId("remind-continue").click();
}

/** The whole ask from a non-empty fleet: ①②④⑤ then ⑥⑦ → ⑧. */
export async function walkToPriceFromStart(page: Page, remindDays: 1 | 2 = 1) {
  await walkProblem(page);
  await walkBenefits(page);
  await walkToPrice(page, remindDays);
}
