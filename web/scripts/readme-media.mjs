// Produce the README media from the masked demo fixtures (?fixtures=1):
// a static cockpit screenshot (retina) and a scheduler interaction recording
// (webm; the wrapper script converts it to a GIF). Driven against the REAL
// binary serving the embedded cockpit — never a dev server.
//
// The browser timezone is PINNED to UTC: fixture instants are authored in
// UTC and FIXTURE_NOW_MINUTES is timezone-free, so an unpinned browser
// renders every parsed timestamp shifted by the machine's offset while the
// now-line stays put — the physics silently break (the 2026-07-17 bug).
import fs from "node:fs";
import { chromium } from "@playwright/test";

const base = process.env.MEDIA_BASE_URL;
const out = process.env.MEDIA_OUT_DIR;
if (!base || !out) throw new Error("MEDIA_BASE_URL and MEDIA_OUT_DIR are required");

const VIEW = { width: 1400, height: 980 };
let boardHeight = 640; // measured in the screenshot pass, reused for video
const browser = await chromium.launch();

async function openBoard(ctx) {
  const page = await ctx.newPage();
  await page.goto(`${base}/?fixtures=1`);
  await page.getByText("kai@example.dev").waitFor();
  await page.waitForTimeout(600); // fonts + bar transitions settle
  return page;
}

// The board's time->x mapping. The Slider.Root spans the full 1160px track,
// so x(t) = trackLeft + t/1440*1160; trackLeft derives from a lane email's
// box (boardLeft + px-3 pad 12 + avatar 26 + gap 10 = email.x - 48, then
// + HEADER_PX 240). Thumb boxes are NOT a valid calibration source — their
// visual center sits half a detent off the slider's value position.
async function calibrate(page) {
  const emailBox = await page.getByText("alex@example.dev").boundingBox();
  if (!emailBox) throw new Error("alex lane not found for calibration");
  const trackLeft = emailBox.x - 48 + 240;
  const xOf = (minutes) => trackLeft + (minutes / 1440) * 1160;
  const laneY = async (email) => {
    const box = await page.getByText(email).boundingBox();
    if (!box) throw new Error(`lane ${email} not found`);
    return box.y - 15 + 50; // lane top (email has 15px top pad) + track row
  };
  return { xOf, laneY };
}

// --- static cockpit screenshot (board only, retina) ---
{
  const ctx = await browser.newContext({
    viewport: VIEW,
    deviceScaleFactor: 2,
    colorScheme: "dark",
    timezoneId: "UTC",
  });
  const page = await openBoard(ctx);
  const history = await page.locator('section[aria-label="History"]').boundingBox();
  if (history) boardHeight = Math.round(history.y / 2) * 2; // even, for video/gif encoders
  await page.screenshot({
    path: `${out}/cockpit.png`,
    clip: { x: 0, y: 0, width: VIEW.width, height: boardHeight },
  });
  await ctx.close();
  console.log(`cockpit.png written (${VIEW.width}x${boardHeight})`);
}

// --- scheduler interaction recording ---
// Four beats, all on the real Track physics:
//   1. try to book on kai (mid-window) — the board refuses: locked zone flash
//   2. book on mira (fresh): hover ghost "+ 20:00" -> click -> block draws
//   3. drag the new reset (feint 22:00, settle 21:00), the HUD streaming
//   4. release opens the inspector's honest terms; Esc closes, rest
{
  const ctx = await browser.newContext({
    viewport: { width: VIEW.width, height: boardHeight },
    colorScheme: "dark",
    timezoneId: "UTC",
    recordVideo: { dir: out, size: { width: VIEW.width, height: boardHeight } },
  });
  const page = await openBoard(ctx);
  const { xOf, laneY } = await calibrate(page);
  const kaiY = await laneY("kai@example.dev");
  const miraY = await laneY("mira@example.dev");

  await page.waitForTimeout(1000); // opening rest

  // beat 1 — kai is mid-window until 17:19: a 15:30 reset can't exist
  await page.mouse.move(xOf(930), kaiY, { steps: 24 });
  await page.waitForTimeout(400);
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForTimeout(1300); // locked-zone flash plays out

  // beat 2 — mira is fresh: ghost preview, click books 20:00
  await page.mouse.move(xOf(1200), miraY, { steps: 26 });
  await page.waitForTimeout(900); // "+ 20:00" ghost visible
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForTimeout(800); // block draws

  // beat 3 — drag the new reset: feint to 22:00, settle on 21:00
  const thumb = page.getByRole("slider").nth(2);
  const box = await thumb.boundingBox();
  if (!box) throw new Error("mira's booked thumb not found");
  const ty = box.y + box.height / 2;
  await page.mouse.move(xOf(1200), ty, { steps: 8 });
  await page.mouse.down();
  await page.mouse.move(xOf(1320), ty, { steps: 24 });
  await page.waitForTimeout(300);
  await page.mouse.move(xOf(1260), ty, { steps: 16 });
  await page.waitForTimeout(350);
  await page.mouse.up();

  // beat 4 — the release selects the booking: inspector states the terms
  await page.waitForTimeout(1700);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(1300); // closing rest

  const video = page.video();
  await ctx.close();
  const vpath = await video.path();
  fs.renameSync(vpath, `${out}/scheduler.webm`);
  console.log("scheduler.webm written");
}

await browser.close();
