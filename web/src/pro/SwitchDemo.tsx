import { useEffect, useRef, useState } from "react";
import type { AccountState, State } from "../api.ts";
import { useReducedMotion } from "../board/useReducedMotion.ts";

// The switch story on repeat, ported from the reviewed design mock
// (design/onboarding-preview.html ?b=2): the active account's gauge climbs to
// 99%, the autopilot fires, ACTIVE moves to the account with headroom, the
// gauge drops to that account's low number, the spent account rests — then it
// climbs again. Two GENUINE accounts (distinct emails) show their own data;
// otherwise the masked fixture pair carries the story. The climb is a
// demonstration of the future, so its pacing (34ms ticks) is the mock's,
// deliberately outside the 150–250ms state-motion budget — reduced motion
// gets the story as a single settled frame instead.

interface Lane {
  email: string;
  /** the lane's resting number — its real session percent at render. */
  low: number;
  /** HH:MM the lane's live window resets, when the snapshot knows it. */
  resets: string | null;
}

function sessionBucket(a: AccountState) {
  return a.snapshot?.buckets.find((b) => b.kind === "session" || b.kind === "five_hour");
}

function toLane(a: AccountState): Lane {
  const s = sessionBucket(a);
  const resets = s?.resets_at
    ? new Date(s.resets_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false })
    : null;
  return { email: a.email, low: Math.round(s?.percent ?? 0), resets };
}

/** The two lanes of the story: the active account, then the genuinely
 *  separate account with the most headroom. null when the fleet cannot tell
 *  the story (fewer than two distinct emails). */
export function demoLanes(state: State): [Lane, Lane] | null {
  const byEmail = new Map<string, AccountState>();
  for (const a of state.accounts) {
    if (a.email && !byEmail.has(a.email)) byEmail.set(a.email, a);
  }
  const uniq = [...byEmail.values()];
  if (uniq.length < 2) return null;
  const active = uniq.find((a) => a.id === state.active_id) ?? uniq[0];
  const target = uniq
    .filter((a) => a !== active)
    .sort((x, y) => (sessionBucket(x)?.percent ?? 0) - (sessionBucket(y)?.percent ?? 0))[0];
  return [toLane(active), toLane(target)];
}

// Mock timings, ported verbatim: 34ms climb tick, 1500ms on the switch line
// before ACTIVE moves, 2200ms until the spent lane rests, 500ms to re-climb.
const TICK_MS = 34;
const SWITCH_MS = 1500;
const REST_MS = 2200;
const RESUME_MS = 500;

export function SwitchDemo({ lanes }: { lanes: [Lane, Lane] }) {
  const reduced = useReducedMotion();
  const [active, setActive] = useState(0);
  const [pct, setPct] = useState(() => Math.max(5, lanes[0].low));
  const [spentPct, setSpentPct] = useState(lanes[1].low);
  const [switchLine, setSwitchLine] = useState<string | null>(null);
  const timers = useRef<number[]>([]);

  useEffect(() => {
    if (reduced) {
      // One settled frame tells the same story: the switch just happened.
      setActive(1);
      setPct(Math.max(5, lanes[1].low));
      setSpentPct(99);
      setSwitchLine(lineFor(lanes, 0, 1));
      return;
    }
    // Entering (or re-entering, after a reduced-motion flip) the animated
    // branch resets to the opening frame — stale "post-switch" state from
    // the reduced branch would make the first cycle announce a switch to
    // the lane that is already ACTIVE.
    let act = 0;
    let p = Math.max(5, lanes[0].low);
    setActive(0);
    setPct(p);
    setSpentPct(lanes[1].low);
    setSwitchLine(null);
    const later = (fn: () => void, ms: number) => {
      timers.current.push(window.setTimeout(fn, ms));
    };
    const climb = () => {
      const t = window.setInterval(() => {
        p = Math.min(99, p + 1);
        setPct(p);
        if (p >= 99) {
          window.clearInterval(t);
          fire();
        }
      }, TICK_MS);
      timers.current.push(t);
    };
    const fire = () => {
      const spent = act;
      const next = act === 1 ? 0 : 1;
      setSwitchLine(lineFor(lanes, spent, next));
      later(() => {
        act = next;
        p = Math.max(5, lanes[next].low);
        setActive(next);
        setPct(p);
        setSpentPct(99);
        // the spent account rests while the other one works
        later(() => setSpentPct(lanes[spent].low), REST_MS);
        later(climb, RESUME_MS);
      }, SWITCH_MS);
    };
    climb();
    const pending = timers.current;
    return () => {
      pending.forEach((t) => {
        window.clearTimeout(t);
        window.clearInterval(t);
      });
      timers.current = [];
    };
  }, [reduced, lanes]);

  const gaugeColor = pct >= 90 ? "var(--warnraw)" : "var(--accent)";
  return (
    <div className="mt-5 flex items-center gap-8">
      <div className="relative h-[132px] w-[132px] flex-none" aria-hidden="true">
        <div
          className="h-full w-full rounded-full"
          style={{
            background: `conic-gradient(${gaugeColor} 0 ${pct}%, var(--rail) ${pct}% 100%)`,
            WebkitMask: "radial-gradient(circle 49px, transparent 97%, #000 100%)",
            mask: "radial-gradient(circle 49px, transparent 97%, #000 100%)",
          }}
        />
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-0.5">
          <span className="text-[24px] font-bold tabular-nums">{pct}%</span>
          <span className="max-w-[88px] truncate text-[10px] text-ter">{lanes[active].email}</span>
        </div>
      </div>
      <div className="min-w-0 flex-1">
        {lanes.map((lane, i) => {
          const isActive = i === active;
          const p = isActive ? pct : spentPct;
          return (
            <div
              key={lane.email}
              className="mt-2.5 flex items-center gap-2.5 rounded-[10px] border border-hairsoft bg-panel px-3 py-2.5 first:mt-0"
            >
              <span className="w-[132px] flex-none truncate text-[12px] font-semibold">
                {lane.email}
              </span>
              <span className="h-[6px] min-w-0 flex-1 overflow-hidden rounded-[3px] bg-rail">
                <i
                  className="block h-full origin-left rounded-[3px]"
                  style={{
                    transform: `scaleX(${p / 100})`,
                    background: isActive ? gaugeColor : "var(--ok)",
                    transition: "transform 180ms linear, background-color 200ms",
                  }}
                />
              </span>
              <span className="w-[34px] flex-none text-right text-[11px] tabular-nums text-sec">
                {p}%
              </span>
              <span
                className={`flex-none rounded-full border border-okbd bg-okbg px-[6px] py-px text-[8.5px] font-bold tracking-[0.04em] text-ok-tx ${
                  isActive ? "" : "invisible"
                }`}
              >
                ACTIVE
              </span>
            </div>
          );
        })}
        {/* Deliberately NOT a live region — the loop repeats forever and
            would re-announce every cycle; the surrounding copy tells the
            same story in prose. */}
        <p
          className="mt-3 min-h-[18px] text-[12px] tabular-nums text-text transition-opacity duration-250"
          style={{ opacity: switchLine ? 1 : 0 }}
        >
          {switchLine && (
            <>
              <span aria-hidden="true">→ </span>
              {switchLine}
            </>
          )}
        </p>
      </div>
    </div>
  );
}

function lineFor(lanes: [Lane, Lane], spent: number, next: number): string {
  const rest = lanes[spent].resets
    ? `${lanes[spent].email} rests until ${lanes[spent].resets}`
    : `${lanes[spent].email} rests until its window resets`;
  return `Switched to ${lanes[next].email} — ${rest}`;
}
