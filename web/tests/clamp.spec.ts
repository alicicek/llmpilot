import { test, expect } from "@playwright/test";
import { clampMove, canBookAt } from "../src/board/clamp.ts";
import { MIN_GAP_MIN, DAY_MIN, SNAP_MIN } from "../src/schedule.ts";

// Unit coverage for the 5h15 circular-spacing physics — the enforcement
// mechanism for a stated wave requirement (verifier P2, 2026-07-10). Pure
// node tests; no browser.

const GAP = MIN_GAP_MIN; // 315

test("no-op when nothing moved", () => {
  expect(clampMove([540, 900], [540, 900], 0)).toBeNull();
});

test("free move inside legal range does not clamp", () => {
  const out = clampMove([540, 900], [540, 915], 0)!;
  expect(out.values[1]).toBe(915);
  expect(out.hitWall).toBe(false);
  expect(out.flashZone).toBeNull();
});

test("wall: moving right thumb into the left neighbor clamps to gap and flashes", () => {
  // left at 09:00 (540); right dragged to 540+300 (violates 315 gap)
  const out = clampMove([540, 900], [540, 840], 0)!;
  expect(out.values[1]).toBe(540 + GAP);
  expect(out.hitWall).toBe(true);
  expect(out.flashZone).not.toBeNull();
});

test("wall: moving left thumb into the right neighbor clamps symmetrically", () => {
  const out = clampMove([540, 900], [660, 900], 0)!;
  expect(out.values[0]).toBe(900 - GAP);
  expect(out.hitWall).toBe(true);
});

test("midnight seam: first thumb cannot wrap into the last thumb's window", () => {
  // last at 23:00 (1380); first dragged to 00:30 (30) — circular gap 90 < 315
  const out = clampMove([120, 1380], [30, 1380], 0)!;
  expect(out.values[0]).toBe(1380 - (DAY_MIN - GAP)); // = 255 → 04:15
  expect(out.hitWall).toBe(true);
});

test("midnight seam: last thumb cannot wrap into the first thumb's window", () => {
  // first at 01:00 (60); last dragged to 23:45 (1425) — circular gap 75 < 315
  const out = clampMove([60, 900], [60, 1420], 0)!;
  expect(out.values[1]).toBe(60 + (DAY_MIN - GAP)); // = 1185 → 19:45
  expect(out.hitWall).toBe(true);
});

test("mid-window floor locks moves below earliest fresh reset", () => {
  // active window ends 16:05 (965) → floor 21:05 (1265)
  const floor = 965 + 300;
  const out = clampMove([1290], [1200], floor)!;
  expect(out.values[0]).toBe(floor);
  expect(out.hitWall).toBe(true);
});

test("top of day clamps to DAY_MIN - SNAP_MIN", () => {
  const out = clampMove([600], [DAY_MIN + 15], 0)!;
  expect(out.values[0]).toBe(DAY_MIN - SNAP_MIN);
});

test("canBookAt: rejects inside the gap of an existing reset (both sides)", () => {
  expect(canBookAt(900 - GAP + 15, [900], 0)).not.toBeNull();
  expect(canBookAt(900 + GAP - 15, [900], 0)).not.toBeNull();
  expect(canBookAt(900 + GAP, [900], 0)).toBeNull();
});

test("canBookAt: circular — 23:30 conflicts with 01:00 across midnight", () => {
  expect(canBookAt(1410, [60], 0)).not.toBeNull();
});

test("canBookAt: below the mid-window floor is rejected with the locked zone", () => {
  expect(canBookAt(600, [], 1265)).toEqual([0, 1265]);
});

test("three thumbs: middle is boxed by both neighbors", () => {
  const prev = [200, 600, 1000];
  const lo = clampMove(prev, [200, 400, 1000], 0)!;
  expect(lo.values[1]).toBe(200 + GAP);
  const hi = clampMove(prev, [200, 800, 1000], 0)!;
  expect(hi.values[1]).toBe(1000 - GAP);
});
