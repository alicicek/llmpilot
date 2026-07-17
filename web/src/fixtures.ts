import type { State } from "./api.ts";
import type { Schedule } from "./schedule.ts";

// Designed-state fixtures for board development, screenshots, and judging.
// Masked demo accounts only. ONE causally consistent day at 12:38 — every
// number on the board must be derivable from the story below; nothing is
// decoration:
//
//   alex — the morning workhorse. A 04:00 trigger opened a window (reset
//   09:00, ✓ ran), chained into a fresh 09:00 window (⛓ rides the reset).
//   Heavy agentic use filled it: 98% with 1:22 left until the 14:00 reset.
//   At 12:19 the autopilot saw alex cross the threshold and switched away.
//   kai  — ACTIVE now. His window started with the first prompt after the
//   12:19 switch, so it resets 17:19; 19 minutes in he sits at 9%.
//   mira — the fresh reserve. Nothing scheduled, nothing burned: the empty
//   lane invites "click a time to book one" (the README GIF does exactly
//   that).
//
// All instants are UTC ("Z") and the recorder pins the browser to UTC
// (timezoneId in web/scripts/readme-media.mjs), so authored times ARE the
// rendered times. An unpinned browser shifts every parsed timestamp by the
// machine's offset while FIXTURE_NOW_MINUTES stays fixed — bands drift off
// the now-line and the physics silently break (the 2026-07-17 README bug).
export const FIXTURE_NOW_MINUTES = 12 * 60 + 38;

// The fixture "today" — resets_at instants derive from it so renders are
// deterministic regardless of when tests run.
const DAY = "2026-07-10";
const at = (hm: string) => `${DAY}T${hm}:00Z`;
const MONDAY = "2026-07-13T20:00:00Z";

export const fixtureState: State = {
  active_id: "kai",
  as_of: at("12:37"),
  events: [
    { at: at("12:19"), kind: "switch", account_id: "kai", message: "switched to kai — alex at 96%" },
    { at: at("09:00"), kind: "trigger", account_id: "alex", message: "chained trigger fired — alex fresh until 14:00" },
    { at: at("04:00"), kind: "trigger", account_id: "alex", message: "04:00 trigger ran — window until 09:00" },
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
        as_of: at("12:37"),
        buckets: [
          { kind: "session", percent: 98, resets_at: at("14:00"), active: true },
          { kind: "weekly_all", percent: 62, resets_at: MONDAY },
          { kind: "weekly_scoped", scope: "fable", percent: 74, resets_at: MONDAY },
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
        as_of: at("12:37"),
        buckets: [
          { kind: "session", percent: 9, resets_at: at("17:19"), active: true },
          { kind: "weekly_all", percent: 31, resets_at: MONDAY },
          { kind: "weekly_scoped", scope: "fable", percent: 38, resets_at: MONDAY },
        ],
      },
    },
    {
      id: "mira",
      label: "mira",
      email: "mira@example.dev",
      config_dir: "",
      keychain_service: "",
      pinned: false,
      snapshot: {
        account_id: "mira",
        as_of: at("12:36"),
        buckets: [
          { kind: "session", percent: 0 },
          { kind: "weekly_all", percent: 12, resets_at: MONDAY },
          { kind: "weekly_scoped", scope: "fable", percent: 9, resets_at: MONDAY },
        ],
      },
    },
  ],
};

// alex's plan matches his reality: the 04:00 nudge ran (reset 09:00), and
// the 09:00 trigger chained onto that reset — it STARTED the live window the
// board shows in the "in use" band. kai and mira carry no bookings: kai got
// switched to, mira is the bookable reserve.
export const fixtureSchedules: Schedule[] = [
  { id: "alex-0400", account_id: "alex", hour: 4, minute: 0 },
  { id: "alex-0900", account_id: "alex", hour: 9, minute: 0 },
];

export const fixtureEmptyState: State = {
  active_id: "",
  as_of: at("12:37"),
  events: [],
  accounts: [],
};
