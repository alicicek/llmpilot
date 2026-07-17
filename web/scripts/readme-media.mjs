// Produce the README media from the masked demo fixtures (?fixtures=1):
// a static cockpit screenshot (retina) and a scheduler drag recording
// (webm; the wrapper script converts it to a GIF). Driven against the
// REAL binary serving the embedded cockpit — never a dev server.
import fs from "node:fs";
import { chromium } from "@playwright/test";

const base = process.env.MEDIA_BASE_URL;
const out = process.env.MEDIA_OUT_DIR;
if (!base || !out) throw new Error("MEDIA_BASE_URL and MEDIA_OUT_DIR are required");

const browser = await chromium.launch();

// --- static cockpit screenshot ---
{
  const ctx = await browser.newContext({
    viewport: { width: 1460, height: 940 },
    deviceScaleFactor: 2,
    colorScheme: "dark",
  });
  const page = await ctx.newPage();
  await page.goto(`${base}/?fixtures=1`);
  await page.getByText("kai@example.dev").waitFor();
  await page.waitForTimeout(500); // fonts + bar transitions settle
  await page.screenshot({ path: `${out}/cockpit.png` });
  await ctx.close();
  console.log("cockpit.png written");
}

// --- scheduler interaction recording (drag a reset dot) ---
{
  const ctx = await browser.newContext({
    viewport: { width: 1460, height: 940 },
    colorScheme: "dark",
    recordVideo: { dir: out, size: { width: 1460, height: 940 } },
  });
  const page = await ctx.newPage();
  await page.goto(`${base}/?fixtures=1`);
  await page.getByText("kai@example.dev").waitFor();
  await page.waitForTimeout(800);

  // mira's 19:00 booking (idle lane): sliders in DOM order are
  // alex 04:00, alex 09:00, kai 20:00, mira 11:00, mira 19:00.
  const thumb = page.getByRole("slider").nth(4);
  await thumb.waitFor();
  const box = await thumb.boundingBox();
  if (!box) throw new Error("no slider thumb to drag");
  const startX = box.x + box.width / 2;
  const startY = box.y + box.height / 2;
  const hour = 1460 / 26; // the strip spans roughly the viewport; close enough for choreography

  // hover (flag + burn trace reveal) → drag left past the now-line (the
  // locked zone flashes) → drag right to a valid evening slot → release.
  await page.mouse.move(startX, startY, { steps: 14 });
  await page.waitForTimeout(700);
  await page.mouse.down();
  await page.mouse.move(startX - 6 * hour, startY, { steps: 34 });
  await page.waitForTimeout(650);
  await page.mouse.move(startX + 2 * hour, startY, { steps: 40 });
  await page.waitForTimeout(650);
  await page.mouse.up();
  await page.waitForTimeout(1000);

  const video = page.video();
  await ctx.close();
  const vpath = await video.path();
  fs.renameSync(vpath, `${out}/scheduler.webm`);
  console.log("scheduler.webm written");
}

await browser.close();
