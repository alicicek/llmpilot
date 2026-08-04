import { ApiError, normalizeState, type State } from "./api.ts";

// Mirror of store.Schedule (internal/store/schedule.go). Hour/Minute are the
// TRIGGER (nudge) wall-clock time; the reset lands 5h later — the UI always
// leads with the reset (outcome-first) and shows the nudge as fine print.
export interface Schedule {
  id: string;
  account_id: string;
  hour: number;
  minute: number;
  model?: string;
  effort?: string;
}

export const WINDOW_HOURS = 5;

// Circular day math (minutes since midnight); resets ≥ 5h15m apart.
export const DAY_MIN = 24 * 60;
export const MIN_GAP_MIN = 5 * 60 + 15;
export const SNAP_MIN = 15;

export function triggerMinutes(s: Schedule): number {
  return s.hour * 60 + s.minute;
}

export function resetMinutes(s: Schedule): number {
  return (triggerMinutes(s) + WINDOW_HOURS * 60) % DAY_MIN;
}

export function fmtHM(totalMinutes: number): string {
  const m = ((totalMinutes % DAY_MIN) + DAY_MIN) % DAY_MIN;
  const hh = String(Math.floor(m / 60)).padStart(2, "0");
  const mm = String(m % 60).padStart(2, "0");
  return `${hh}:${mm}`;
}

export function circularGap(aMin: number, bMin: number): number {
  const d = Math.abs(aMin - bMin) % DAY_MIN;
  return Math.min(d, DAY_MIN - d);
}

// First bookable reset for a lane: earliest snap-aligned time after
// (now + window) that clears every existing reset by MIN_GAP and, for a
// mid-window account, the earliest-fresh floor (active end + window).
export function nextBookableReset(opts: {
  nowMinutes: number;
  existingResets: number[];
  activeEndMinutes?: number;
}): { hour: number; minute: number } | null {
  const floorRaw = Math.max(
    opts.nowMinutes + WINDOW_HOURS * 60,
    opts.activeEndMinutes !== undefined
      ? opts.activeEndMinutes + WINDOW_HOURS * 60
      : 0,
  );
  const start = Math.ceil(floorRaw / SNAP_MIN) * SNAP_MIN;
  for (let t = start; t < start + DAY_MIN; t += SNAP_MIN) {
    const m = t % DAY_MIN;
    if (opts.existingResets.every((r) => circularGap(r, m) >= MIN_GAP_MIN)) {
      return { hour: Math.floor(m / 60), minute: m % 60 };
    }
  }
  return null; // lane is full (max 4/day makes this reachable)
}

export async function fetchSchedules(): Promise<Schedule[]> {
  const res = await fetch("/v1/schedules");
  if (!res.ok) throw new Error(`schedules: HTTP ${res.status}`);
  return ((await res.json()) as Schedule[] | null) ?? [];
}

async function mutate(path: string, method: string, body?: unknown): Promise<Response> {
  const res = await fetch(path, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) {
    // Keep the daemon's machine code: a tier boundary (pro_required) must
    // reach the UI as itself, not flattened into failure prose.
    const payload = (await res.json().catch(() => null)) as { error?: string; code?: string } | null;
    throw new ApiError(payload?.error ?? `${method} ${path}: HTTP ${res.status}`, payload?.code);
  }
  return res;
}

export async function createSchedule(input: {
  account_id: string;
  hour: number;
  minute: number;
  model?: string;
  effort?: string;
}): Promise<Schedule> {
  const res = await mutate("/v1/schedules", "POST", input);
  return (await res.json()) as Schedule;
}

export async function moveSchedule(id: string, hour: number, minute: number): Promise<Schedule> {
  const res = await mutate(`/v1/schedules/${encodeURIComponent(id)}`, "PUT", { hour, minute });
  return (await res.json()) as Schedule;
}

export async function deleteSchedule(id: string): Promise<void> {
  await mutate(`/v1/schedules/${encodeURIComponent(id)}`, "DELETE");
}

export { normalizeState };
export type { State };
