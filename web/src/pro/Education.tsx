import { useEffect, useRef, useState } from "react";
import type { Bucket } from "../api.ts";
import { avatarStyle } from "../board/avatar.ts";
import RunwayBar from "../board/RunwayBar.tsx";
import { useReducedMotion } from "../board/useReducedMotion.ts";
import { StepDots } from "../shell/StepDots.tsx";

// SPEC-127 screens ① ② ⑤ — the problem, the blind spot, the scheduled window.
// Every screen is built from SHIPPED product components, never onboarding-only
// art (owner 2026-08-05): the real RunwayBar computes its own severity from
// the percent we animate, so the bar turns amber at 70 and red at 90 because
// the PRODUCT says so, not because this file picked a colour. Identity discs
// reuse board/avatar.ts. The ⑤ board reproduces Axis/ChargeBlock/NowLine at a
// narrower scale: those three are locked to geometry.ts's 1160px track (a
// 1400px board in a 620px card), so their pixel spec is mirrored here rather
// than imported — the grammar is identical, the px-per-minute is not.
//
// Motion: one beat per screen, 400ms of stillness first, then a single
// ~1–2s play, then rest. Continue is live from the first frame; nobody is
// held. The 34ms climb tick is SwitchDemo's reviewed pacing, the same
// deliberate exemption from the 150–250ms state-motion budget. Reduced
// motion gets the settled last frame instead of the animation.

const CLIMB_TICK_MS = 34;
const REST_MS = 400;

const btnPrimary =
  "mt-5 rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

/** A synthesized session bucket: the shape RunwayBar already knows how to
 *  read, so the demo rides the real severity + terminus-tick logic. */
function sessionBucket(percent: number, resetsAt: string): Bucket {
  return { kind: "session", percent, resets_at: resetsAt, active: true };
}
/** No resets_at: RunwayBar then renders the percent alone. The weekly reset
 *  is a different DAY, and its "resets Wed 00:00" form wraps the bar's
 *  fixed-width label — noise on a screen that is about the session limit. */
function weeklyBucket(percent: number): Bucket {
  return { kind: "weekly_all", percent };
}

/** A reset instant N hours from now, on the hour. Always in the FUTURE: a
 *  fixed wall-clock hour would quietly start claiming a reset time in the
 *  past for anyone opening the app later in the day. Frozen per screen so
 *  the label does not shift under a re-render. */
function futureInstant(hoursFromNow: number): string {
  const d = new Date(Date.now() + hoursFromNow * 60 * 60 * 1000);
  d.setMinutes(0, 0, 0);
  return d.toISOString();
}

/** HH:MM for an instant, matching RunwayBar's own reset formatting so the
 *  status line and the bar never disagree. */
function hhmm(iso: string): string {
  return new Date(iso).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** ⑤'s board illustrates one fixed day (its now-line is pinned at 07:40), so
 *  its hours are that day's, not the wall clock's. */
function boardHour(hour: number): string {
  const d = new Date();
  d.setHours(hour, 0, 0, 0);
  return d.toISOString();
}

/** Said once per demo screen: these lanes carry illustrative numbers on the
 *  user's real addresses, and the flow should not let that be mistaken for
 *  live data. Their actual usage is on the board a screen or two later. */
const EXAMPLE_NOTE = "Example numbers — your live ones are on the board.";

/** Runs one screen's beat and owns every timer it starts. `repeat` registers
 *  an interval so the SAME cleanup cancels it: reduced motion can flip
 *  mid-climb (it is a live media-query listener), which re-runs the beat —
 *  an interval tracked outside this hook would keep ticking under a
 *  reduced-motion preference, and a second flip would strand the first one
 *  running past unmount. */
function useBeat(
  run: (t: { after: (fn: () => void, ms: number) => void; repeat: (fn: () => void, ms: number) => void }) => void,
  deps: unknown[],
) {
  const timeouts = useRef<number[]>([]);
  const intervals = useRef<number[]>([]);
  useEffect(() => {
    run({
      after: (fn, ms) => void timeouts.current.push(window.setTimeout(fn, ms)),
      repeat: (fn, ms) => void intervals.current.push(window.setInterval(fn, ms)),
    });
    return () => {
      for (const t of timeouts.current) window.clearTimeout(t);
      for (const i of intervals.current) window.clearInterval(i);
      timeouts.current = [];
      intervals.current = [];
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/** The lane chrome LaneHeader renders: avatar disc, identity row, status
 *  line, then the bars. Values are supplied rather than derived so a screen
 *  can animate them. */
function DemoLane({
  id,
  email,
  badge,
  status,
  statusTone,
  children,
  className = "",
  style,
}: {
  id: string;
  email: string;
  badge?: "active" | "switch" | null;
  status: string;
  statusTone: "calm" | "warn" | "crit" | "idle";
  children?: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
}) {
  const dot =
    statusTone === "crit"
      ? "bg-crit"
      : statusTone === "warn"
        ? "bg-warnraw"
        : statusTone === "calm"
          ? "bg-ok"
          : "bg-graydot";
  return (
    <li
      className={`flex gap-[10px] rounded-[10px] border border-hairsoft bg-panel px-[15px] py-[13px] ${className}`}
      style={style}
    >
      <span
        className="mt-px flex h-[26px] w-[26px] shrink-0 items-center justify-center rounded-full text-[12px] font-bold text-white"
        style={avatarStyle(id)}
      >
        {email.slice(0, 1).toUpperCase()}
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-[6px]">
          <span className="truncate text-[12.5px] font-semibold tracking-[-0.01em]">{email}</span>
          {badge === "active" && (
            <span className="shrink-0 rounded-full bg-okbg px-[6px] py-px text-[8.5px] font-bold tracking-[0.04em] text-ok-tx">
              ACTIVE
            </span>
          )}
          {badge === "switch" && (
            // LaneHeader's SWITCH pill is tinted (acc-a + acc-tx), which
            // clears AA on the board's bg-win but not on these bg-panel
            // cards — the same 4.36:1 the reminder chips hit, and the same
            // fix the app already settled on: fill it.
            <span className="shrink-0 rounded-full bg-acc-tx px-[7px] py-px text-[9px] font-bold tracking-[0.04em] text-white dark:bg-accent">
              SWITCH
            </span>
          )}
        </span>
        <span className="mt-[3px] flex items-center gap-[5px] text-[10.5px] text-sec">
          <i className={`h-1.5 w-1.5 shrink-0 rounded-full ${dot}`} />
          <span className="truncate">{status}</span>
        </span>
        {children}
      </span>
    </li>
  );
}

function Frame({
  step,
  total,
  headline,
  keyPhrase,
  tail,
  lede,
  children,
  note,
  example,
  onContinue,
}: {
  step: number;
  total: number;
  headline: string;
  keyPhrase: string;
  tail?: string;
  lede: string;
  children: React.ReactNode;
  note: string;
  /** rendered under the demo lanes where the numbers are illustrative. */
  example?: boolean;
  onContinue: () => void;
}) {
  return (
    <section className="w-[620px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      <StepDots step={step} total={total} />
      <h1 className="text-[19px] font-semibold leading-[1.3] tracking-[-0.015em]">
        {headline}
        <span className="text-acc-tx">{keyPhrase}</span>
        {tail}
      </h1>
      <p className="mt-[9px] text-[12.5px] leading-relaxed text-sec">{lede}</p>
      {children}
      {example && <p className="mt-2.5 text-[10.5px] text-ter">{EXAMPLE_NOTE}</p>}
      <p className="mt-[18px] text-[12.5px] leading-relaxed text-text">{note}</p>
      <button className={btnPrimary} onClick={onContinue}>
        Continue
      </button>
    </section>
  );
}

// ——— ① THE WALL ———————————————————————————————————————————————
// The session bar climbs into its own ceiling and the notification lands.
// Nothing here is a claim: it is the state every Claude Code user has hit.
export function WallScreen({
  step,
  total,
  email,
  onContinue,
}: {
  step: number;
  total: number;
  /** the user's own first identity when one is known — this is their app, and
   *  a placeholder address on the opening screen reads like a brochure. */
  email?: string;
  onContinue: () => void;
}) {
  const reduced = useReducedMotion();
  const [pct, setPct] = useState(reduced ? 100 : 71);
  const [spent, setSpent] = useState(reduced);
  const reset = useRef(futureInstant(3)).current;

  useBeat(
    ({ after, repeat }) => {
      if (reduced) {
        setPct(100);
        setSpent(true);
        return;
      }
      setPct(71);
      setSpent(false);
      after(() => repeat(() => setPct((p) => Math.min(100, p + 1)), CLIMB_TICK_MS), REST_MS);
      after(() => setSpent(true), REST_MS + 30 * CLIMB_TICK_MS + 220);
    },
    [reduced],
  );

  return (
    <Frame
      step={step}
      total={total}
      headline="You know "
      keyPhrase="this moment"
      tail="."
      lede="Deep in a refactor. Claude has the whole thing in its head. And then it stops."
      note="Five hours of waiting. Or another login, and your place is gone."
      example
      onContinue={onContinue}
    >
      <ul className="mt-[22px] list-none" data-testid="edu-wall-lanes">
        <DemoLane
          id={email ?? "demo-one"}
          email={email ?? "Your Claude account"}
          badge="active"
          status={`${spent ? "Spent" : "Mid-window"} — resets ${hhmm(reset)}`}
          statusTone={spent ? "crit" : "warn"}
        >
          <RunwayBar bucket={sessionBucket(pct, reset)} refIso={reset} stale={false} />
          <RunwayBar bucket={weeklyBucket(34)} refIso={reset} stale={false} />
        </DemoLane>
      </ul>
      <p
        className={`mt-4 inline-flex items-center gap-2 rounded-[9px] bg-hudbg px-3 py-2 text-[11.5px] text-hudtx shadow-hud transition-opacity duration-200 ${
          spent ? "opacity-100" : "opacity-0"
        }`}
        role={spent ? "status" : undefined}
        data-testid="edu-wall-toast"
      >
        <i className="h-[7px] w-[7px] rounded-full bg-crit" />
        Usage limit reached · resets {hhmm(reset)}
      </p>
    </Frame>
  );
}

// ——— ② THE BLIND SPOT —————————————————————————————————————————
// Two shapes, decided by what detection actually found. With a second
// identity on this Mac the screen names it and reveals its headroom. With
// one, it never implies a second exists: the story becomes the glance —
// seeing the wall coming instead of being stopped by it.
export function BlindSpotScreen({
  step,
  total,
  emails: supplied,
  onContinue,
}: {
  step: number;
  total: number;
  /** every distinct Claude identity on this Mac: the fleet's accounts plus
   *  any signed-in folder not yet added. */
  emails: string[];
  onContinue: () => void;
}) {
  const reduced = useReducedMotion();
  const [revealed, setRevealed] = useState(reduced);
  // Frozen once it has something to say, so a late-landing detection cannot
  // swap the headline mid-view. But an EMPTY list is not an answer, it is a
  // pending one: /v1/detect has no timeout upstream and starts empty, so
  // freezing that would permanently show the one-account story to a genuine
  // two-account user. Empty upgrades; anything else holds.
  const frozen = useRef<string[]>(supplied);
  if (frozen.current.length === 0 && supplied.length > 0) frozen.current = supplied;
  const emails = frozen.current;
  const pair = emails.length >= 2;

  const lead = useRef(futureInstant(3)).current;
  const spare = useRef(futureInstant(6)).current;

  useBeat(
    ({ after }) => {
      if (reduced) {
        setRevealed(true);
        return;
      }
      setRevealed(false);
      after(() => setRevealed(true), 900);
    },
    [reduced, pair],
  );

  const reveal = `transition-all duration-500 ${revealed ? "opacity-100 translate-y-0" : "opacity-0 translate-y-2"}`;

  if (pair) {
    return (
      <Frame
        step={step}
        total={total}
        headline=""
        keyPhrase="More room"
        tail=" than you think."
        lede={`${emails.length} Claude accounts are signed in on this Mac. Until now, you could see one.`}
        note="That second account was sitting there the whole time."
        example
        onContinue={onContinue}
      >
        <ul className="mt-[22px] flex list-none flex-col gap-1.5" data-testid="edu-blind-pair">
          <DemoLane
            id={emails[0]}
            email={emails[0]}
            badge="active"
            status={`Spent — resets ${hhmm(lead)}`}
            statusTone="crit"
          >
            <RunwayBar bucket={sessionBucket(100, lead)} refIso={lead} stale={false} />
          </DemoLane>
          <DemoLane
            id={emails[1]}
            email={emails[1]}
            badge="switch"
            status="Idle — no active window"
            statusTone="calm"
            className={reveal}
          >
            <RunwayBar bucket={sessionBucket(12, spare)} refIso={lead} stale={false} />
          </DemoLane>
        </ul>
      </Frame>
    );
  }

  return (
    <Frame
      step={step}
      total={total}
      headline="The wall "
      keyPhrase="doesn't warn you"
      tail="."
      lede="You find out you hit the limit when it stops you. llmpilot sees it coming."
      note="Session and weekly limits, live. No tab to check, no surprise."
      example
      onContinue={onContinue}
    >
      <ul className="mt-[22px] flex list-none flex-col gap-1.5" data-testid="edu-blind-solo">
        <DemoLane
          id={emails[0] ?? "demo-one"}
          email={emails[0] ?? "Your Claude account"}
          badge="active"
          status={`Mid-window — resets ${hhmm(lead)}`}
          statusTone="warn"
        >
          <RunwayBar bucket={sessionBucket(71, lead)} refIso={lead} stale={false} />
          <RunwayBar bucket={weeklyBucket(34)} refIso={lead} stale={false} />
        </DemoLane>
      </ul>
      <p
        className={`mt-4 inline-flex items-center gap-[10px] rounded-lg border border-hairsoft bg-panel px-3 py-[7px] text-[11px] text-sec ${reveal}`}
        data-testid="edu-glance"
      >
        <span>Always in your menu bar</span>
        <span className="h-[5px] w-[34px] overflow-hidden rounded-sm bg-rail">
          <i className="block h-full w-[71%] bg-warnraw" />
        </span>
        <span className="tabular-nums">71%</span>
      </p>
    </Frame>
  );
}

// ——— ⑤ THE SCHEDULED WINDOW ———————————————————————————————————
// The board, at onboarding scale: the 24h axis, a booked 5-hour ChargeBlock,
// the now-line past its trailing edge, and the lane's own session bar
// draining to zero as the window resets. The bar IS the payoff — a "full
// tank" line with nothing behind it was the first mock's mistake.
// geometry.ts uses HEADER_PX 240 against a 1160px track. The header keeps
// close to that width because RunwayBar's own label columns (15px + 104px)
// are fixed: take much off and the bar itself is what gets squeezed out.
const HDR_PX = 228;
const pctOfDay = (minutes: number) => (minutes / (24 * 60)) * 100;
const NOW_MIN = 7 * 60 + 40;
const NOW_LABEL = "07:40";
const BLOCK_START = 60;
const BLOCK_END = 6 * 60;

export function WindowsScreen({
  step,
  total,
  email,
  onContinue,
}: {
  step: number;
  total: number;
  email?: string;
  onContinue: () => void;
}) {
  const reduced = useReducedMotion();
  const [booked, setBooked] = useState(reduced);
  const [ran, setRan] = useState(reduced);

  useBeat(
    ({ after }) => {
      if (reduced) {
        setBooked(true);
        setRan(true);
        return;
      }
      setBooked(false);
      setRan(false);
      after(() => setBooked(true), 900);
      after(() => setRan(true), 2100);
    },
    [reduced],
  );

  // The board's own day, not the wall clock: 06:00 is where the drawn block
  // ends, and the now-line is pinned at 07:40 to match.
  const reset = boardHour(6);
  return (
    <Frame
      step={step}
      total={total}
      headline="Your next window opens "
      keyPhrase="while you sleep"
      tail="."
      lede="A window is a 5-hour block. Book one on the board and llmpilot has it fresh and waiting."
      note="Wake up to a full tank instead of a wait."
      onContinue={onContinue}
    >
      <div
        className="mt-[22px] overflow-hidden rounded-[10px] border border-hairsoft bg-panel"
        data-testid="edu-windows-board"
      >
        {/* Axis.tsx offsets every tick by HEADER_PX: the hour grid starts
            where the TRACK starts, not at the board's left edge. */}
        <div className="relative h-[30px] border-b border-hair">
          <div className="absolute inset-y-0 right-0" style={{ left: HDR_PX }}>
            {Array.from({ length: 25 }, (_, h) => (
              <i
                key={h}
                className="absolute bottom-0 h-[5px] w-px bg-hair"
                style={{ left: `${pctOfDay(h * 60)}%` }}
              />
            ))}
            {Array.from({ length: 10 }, (_, i) => i * 2).map((h) => (
              <span
                key={h}
                className="absolute top-[9px] -translate-x-1/2 text-[9.5px] tabular-nums text-ter"
                style={{ left: `${pctOfDay(h * 60)}%` }}
              >
                {String(h).padStart(2, "0")}
              </span>
            ))}
          </div>
          <span className="absolute right-2 top-[9px] text-[9.5px] text-ter">24h · local</span>
        </div>
        <div className="relative flex h-[98px]">
          <div
            className="shrink-0 border-r border-hairsoft px-3 pt-[11px]"
            style={{ width: HDR_PX }}
          >
            <div className="truncate text-[11.5px] font-semibold tracking-[-0.01em]">
              {email ?? "Your Claude account"}
            </div>
            <div className="mt-[3px] flex items-center gap-[5px] text-[10.5px] text-sec">
              <i
                className={`h-1.5 w-1.5 shrink-0 rounded-full ${
                  ran ? "bg-ok" : booked ? "bg-accent" : "bg-warnraw"
                }`}
              />
              <span className="truncate" data-testid="edu-windows-status">
                {ran ? "Idle — no active window" : booked ? "Window booked — 01:00" : "Mid-window"}
              </span>
            </div>
            <RunwayBar
              bucket={sessionBucket(ran ? 0 : 86, reset)}
              refIso={reset}
              stale={false}
            />
          </div>
          <div className="relative flex-1">
            <div
              className="pointer-events-none absolute inset-y-0 left-0 bg-wash"
              style={{ width: `${pctOfDay(NOW_MIN)}%` }}
            />
            {/* ChargeBlock.tsx: 30px tall, radius 7, the app's one gradient,
                acc-bd border, centred 5:00 watermark. */}
            <div
              className={`pointer-events-none absolute top-[30px] flex h-[30px] items-center justify-center rounded-[7px] border border-acc-bd bg-linear-to-r from-acc-a to-acc-b transition-all duration-300 ease-out ${
                booked ? "scale-100 opacity-100" : "scale-[.97] opacity-0"
              }`}
              style={{
                left: `${pctOfDay(BLOCK_START)}%`,
                width: `${pctOfDay(BLOCK_END - BLOCK_START)}%`,
              }}
              data-testid="edu-windows-block"
            >
              <span className="text-[9px] font-semibold tracking-[0.04em] text-acc-tx opacity-55">
                5:00
              </span>
            </div>
            {/* NowLine.tsx: the line spans the lanes and its bubble sits at
                the board's top edge, over the axis — same overlap the real
                board has. Without the stamp a bare red rule reads as an
                error rather than as "now". */}
            <div
              className="pointer-events-none absolute inset-y-0 z-[7] w-[1.5px] bg-crit opacity-90"
              style={{ left: `${pctOfDay(NOW_MIN)}%` }}
            />
            <div
              className="pointer-events-none absolute top-[-22px] z-[8] -translate-x-1/2 whitespace-nowrap rounded-full bg-crit-deep px-[7px] py-px text-[9.5px] font-bold tabular-nums text-white"
              style={{ left: `${pctOfDay(NOW_MIN)}%` }}
            >
              {NOW_LABEL}
            </div>
          </div>
        </div>
      </div>
    </Frame>
  );
}
