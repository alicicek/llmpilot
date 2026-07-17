// Per-lane schedule geometry + the honesty classification that drives chip
// dot color, suffix copy, and trigger fine print. Derived entirely from
// (trigger, reset, now, mid-window) — no hardcoded per-fixture cases, so it
// stays correct for any BoardProps the daemon eventually sends.
import type { Schedule } from "../schedule.ts";
import {
  DAY_MIN,
  WINDOW_HOURS,
  circularGap,
  fmtHM,
  resetMinutes,
  triggerMinutes,
} from "../schedule.ts";

export interface LaneSchedule {
  schedule: Schedule;
  trigger: number;
  reset: number;
  /** trigger === the immediately-preceding (by reset order) schedule's reset. */
  chained: boolean;
}

/** This lane's schedules sorted by reset time, with chain pairs detected. */
export function laneSchedules(schedules: Schedule[], accountId: string): LaneSchedule[] {
  const mine = schedules
    .filter((s) => s.account_id === accountId)
    .map((s) => ({ schedule: s, trigger: triggerMinutes(s), reset: resetMinutes(s) }))
    .sort((a, b) => a.reset - b.reset);
  return mine.map((m, i) => {
    if (mine.length < 2) return { ...m, chained: false };
    const prev = mine[(i - 1 + mine.length) % mine.length]!;
    const chained = prev.reset !== m.reset && circularGap(m.trigger, prev.reset) === 0;
    return { ...m, chained };
  });
}

/** The lane's currently-active session window, if any (kai's mid-window). */
export interface MidWindow {
  start: number;
  end: number;
}

export type ChipClass = "ran" | "blocked" | "missed" | "charging" | "upcoming";

function inWindow(t: number, mid: MidWindow): boolean {
  return t >= mid.start && t < mid.end;
}

export function classify(ls: LaneSchedule, nowMinutes: number, mid: MidWindow | null): ChipClass {
  if (mid && inWindow(ls.trigger, mid)) return "blocked";
  if (ls.reset <= nowMinutes) return "ran";
  if (ls.trigger <= nowMinutes) return ls.chained ? "charging" : "missed";
  return "upcoming";
}

export type Dot = "gray" | "green" | "amber";

// green = chained/guaranteed (mechanism); amber = an honesty-risk state is
// live right now (blocked/missed); gray = a standalone nudge, outcome TBD.
export function chipDot(cls: ChipClass, chained: boolean): Dot {
  if (chained) return "green";
  if (cls === "blocked" || cls === "missed") return "amber";
  return "gray";
}

export interface ChipCopy {
  suffix: string | null;
  suffixTone: "ok" | "amber" | "sec";
  trigLine: string;
  trigTone: "ter" | "amber";
}

export function chipCopy(ls: LaneSchedule, cls: ChipClass, mid: MidWindow | null): ChipCopy {
  const t = fmtHM(ls.trigger);
  switch (cls) {
    case "ran":
      return {
        suffix: "✓︎ ran today",
        suffixTone: "ok",
        trigLine: ls.chained ? `⛓︎ ${t} · rides the reset` : `▲︎ ${t}`,
        trigTone: "ter",
      };
    case "blocked": {
      const retries = fmtHM(mid!.end);
      const landsAt = fmtHM((mid!.end + WINDOW_HOURS * 60) % DAY_MIN);
      return {
        suffix: `today ≈ ${landsAt} ⚠︎`,
        suffixTone: "amber",
        trigLine: `▲︎ ${t} → blocked today · retries ${retries}`,
        trigTone: "amber",
      };
    }
    case "missed":
      return {
        suffix: "from tomorrow",
        suffixTone: "sec",
        trigLine: `▲︎ ${t} · missed today`,
        trigTone: "amber",
      };
    case "charging":
      return {
        suffix: null,
        suffixTone: "ok",
        trigLine: `⛓︎ ${t} · rides the reset`,
        trigTone: "ter",
      };
    case "upcoming":
      return {
        suffix: ls.chained ? null : "assumes idle",
        suffixTone: "sec",
        trigLine: ls.chained ? `⛓︎ ${t} · rides the reset` : `▲︎ ${t}`,
        trigTone: "ter",
      };
  }
}
