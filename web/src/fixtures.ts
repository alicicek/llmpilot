import type { State } from "./api.ts";
import type { Schedule } from "./schedule.ts";

// Designed-state fixtures for board development, screenshots, and judging.
// Fixed clock: 14:32 (mockup's moment). Masked demo accounts only.
export const FIXTURE_NOW_MINUTES = 14 * 60 + 32;

// The fixture "today" — resets_at instants derive from it so renders are
// deterministic regardless of when tests run.
const DAY = "2026-07-10";
const at = (hm: string) => `${DAY}T${hm}:00+01:00`;

export const fixtureState: State = {
  active_id: "alex",
  as_of: at("14:31"),
  events: [
    { at: at("14:02"), kind: "switch", account_id: "alex", message: "switched to alex — kai at 91%" },
    { at: at("04:00"), kind: "trigger", account_id: "alex", message: "04:00 nudge ran — fresh 09:00" },
  ],
  accounts: [
    {
      id: "alex",
      label: "alex",
      email: "alex@example.dev",
      config_dir: "",
      keychain_service: "",
      pinned: false,
      snapshot: {
        account_id: "alex",
        as_of: at("14:31"),
        buckets: [
          { kind: "session", percent: 23, resets_at: at("19:00"), active: true },
          { kind: "weekly_all", percent: 41, resets_at: "2026-07-13T20:00:00+01:00" },
          { kind: "weekly_scoped", scope: "fable", percent: 12, resets_at: "2026-07-13T20:00:00+01:00" },
        ],
      },
    },
    {
      id: "kai",
      label: "kai",
      email: "kai@example.dev",
      config_dir: "",
      keychain_service: "",
      pinned: false,
      snapshot: {
        account_id: "kai",
        as_of: at("14:29"),
        buckets: [
          { kind: "session", percent: 78, resets_at: at("16:05"), severity: "warning", active: true },
          { kind: "weekly_all", percent: 64, resets_at: "2026-07-14T09:00:00+01:00" },
          { kind: "weekly_scoped", scope: "fable", percent: 67, resets_at: "2026-07-13T20:00:00+01:00" },
        ],
      },
    },
    {
      id: "mira",
      label: "mira",
      email: "mira@example.dev",
      config_dir: "",
      keychain_service: "",
      pinned: true,
      snapshot: {
        account_id: "mira",
        as_of: at("14:30"),
        buckets: [
          { kind: "session", percent: 0 },
          { kind: "weekly_all", percent: 9, resets_at: "2026-07-13T20:00:00+01:00" },
          { kind: "weekly_scoped", scope: "fable", percent: 4, resets_at: "2026-07-13T20:00:00+01:00" },
        ],
      },
    },
    {
      id: "noor",
      label: "noor",
      email: "noor@example.dev",
      config_dir: "",
      keychain_service: "",
      pinned: false,
      // Stale on purpose (07:12): the lane must drain colors + stamp the age
      // (pack rule 5 — stale is never color-judged).
      snapshot: {
        account_id: "noor",
        as_of: at("07:12"),
        buckets: [
          { kind: "session", percent: 0 },
          { kind: "weekly_all", percent: 2, resets_at: "2026-07-13T20:00:00+01:00" },
        ],
      },
    },
  ],
};

// alex: 04:00 nudge (reset 09:00) chained to 09:00 (reset 14:00 — "fresh now").
// kai: 15:00 nudge (reset 20:00) — blocked today, mid-window until 16:05.
// mira: 06:00 (reset 11:00) + 14:00 (reset 19:00, assumes idle — 14:00 already
// passed at 14:32, so today's is missed → catch-up offer).
export const fixtureSchedules: Schedule[] = [
  { id: "alex-0400", account_id: "alex", hour: 4, minute: 0 },
  { id: "alex-0900", account_id: "alex", hour: 9, minute: 0 },
  { id: "kai-1500", account_id: "kai", hour: 15, minute: 0 },
  { id: "mira-0600", account_id: "mira", hour: 6, minute: 0 },
  { id: "mira-1400", account_id: "mira", hour: 14, minute: 0 },
];

export const fixtureEmptyState: State = {
  active_id: "",
  as_of: at("14:31"),
  events: [],
  accounts: [],
};
