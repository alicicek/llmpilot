import { useEffect, useRef, useState } from "react";
import { adoptAccount, fetchDetected, type DetectedDir, type State } from "../api.ts";
import { StepDots } from "./StepDots.tsx";

// Empty fleet = first run. Detect signed-in Claude accounts on this Mac,
// GROUP them by identity, and add them with one click — the UI flow IS
// onboarding; `llmpilot init` is the power-user shortcut, never the required
// path. Two folders holding the same account collapse into one row (one
// shared limit — watching both adds no headroom, so adding the identity adds
// its primary folder; doctor flags dual sign-ins as a problem, we don't
// create one). A genuinely separate account is named as what it is: the
// thing the autopilot switches to. onSkip renders ONLY in the zero-detected
// or failed state: with accounts on screen, adding is the point (owner
// 2026-07-31); with none found, the sign-in-later link keeps a stranger out
// of a dead end.

interface Group {
  email: string;
  dirs: DetectedDir[];
  /** the folder an add registers — ~/.claude when the identity holds it. */
  primary: DetectedDir;
}

function groupByEmail(candidates: DetectedDir[]): Group[] {
  const m = new Map<string, DetectedDir[]>();
  for (const d of candidates) {
    const list = m.get(d.email);
    if (list) list.push(d);
    else m.set(d.email, [d]);
  }
  return [...m.entries()].map(([email, dirs]) => ({
    email,
    dirs,
    primary: dirs.find((d) => d.config_dir.endsWith("/.claude")) ?? dirs[0],
  }));
}

/** Display-only: ~/.claude reads better than /Users/x/.claude (the popover
 *  shortens the same way via NSHomeDirectory). */
function tilde(path: string): string {
  return path.replace(/^\/Users\/[^/]+/, "~");
}

function sessionPercent(state: State, g: Group): number | null {
  const acct =
    state.accounts.find((a) => a.config_dir === g.primary.config_dir) ??
    state.accounts.find((a) => a.email === g.email);
  const s = acct?.snapshot?.buckets.find((b) => b.kind === "session" || b.kind === "five_hour");
  return s ? Math.round(s.percent) : acct ? 0 : null;
}

// The first sight of their own data: the freshly added row's meter fills to
// its real percentage — one 200ms ease-out fill, not a count-up.
function Meter({ pct }: { pct: number }) {
  const [shown, setShown] = useState(0);
  useEffect(() => {
    const id = requestAnimationFrame(() => setShown(pct));
    return () => cancelAnimationFrame(id);
  }, [pct]);
  return (
    <span className="flex items-center gap-2">
      <span className="h-[5px] w-[72px] overflow-hidden rounded-full bg-rail">
        <i
          className="block h-full origin-left rounded-full bg-accent transition-transform duration-200 ease-out"
          style={{ transform: `scaleX(${shown / 100})` }}
        />
      </span>
      <span className="w-[34px] text-right text-[11px] font-semibold tabular-nums text-sec">
        {pct}%
      </span>
    </span>
  );
}

export function FirstRun({
  state,
  dots,
  continueLabel,
  onContinue,
  onSkip,
}: {
  state: State;
  dots?: { step: number; total: number };
  continueLabel: string;
  onContinue: () => void;
  onSkip?: () => void;
}) {
  const [detected, setDetected] = useState<DetectedDir[] | null>(null);
  const [busyEmail, setBusyEmail] = useState<string | null>(null);
  const [added, setAdded] = useState<ReadonlySet<string>>(new Set());
  const [optedOut, setOptedOut] = useState<ReadonlySet<string>>(new Set());
  const [errs, setErrs] = useState<Readonly<Record<string, string>>>({});

  // One snapshot: rows must NOT drop out as they register — the freshly
  // added row stays to show its gauge filling with the user's own data.
  // The timeout covers a daemon that accepts and never answers /v1/detect:
  // the loading frame has no controls, so it must not be able to last.
  useEffect(() => {
    const t = window.setTimeout(() => setDetected((d) => d ?? []), 5000);
    fetchDetected()
      // A dir that names an account but holds no sign-in cannot be added —
      // offering it on the very first screen would make the app's opening
      // move fail. Those folders live in Add account, where the remedy is.
      .then((d) => setDetected(d.filter((x) => !x.registered && x.signed_in !== false)))
      .catch(() => setDetected((d) => d ?? []));
    return () => window.clearTimeout(t);
  }, []);

  const groups = groupByEmail(detected ?? []);
  const toAdd = groups.filter((g) => !added.has(g.email) && !optedOut.has(g.email));
  const anyErr = Object.keys(errs).length > 0;

  // addAll runs across several awaits while checkboxes stay live — it must
  // honor an opt-out made mid-batch, not the render-time snapshot it
  // closed over (a Keychain-reading action on a row the user just
  // unchecked would ignore their choice).
  const optedOutRef = useRef(optedOut);
  optedOutRef.current = optedOut;

  const addAll = async () => {
    for (const g of toAdd) {
      if (optedOutRef.current.has(g.email)) continue;
      setBusyEmail(g.email);
      setErrs((e) => {
        const next = { ...e };
        delete next[g.email];
        return next;
      });
      try {
        await adoptAccount(g.primary.config_dir);
        setAdded((a) => new Set(a).add(g.email));
      } catch (e) {
        setErrs((prev) => ({ ...prev, [g.email]: e instanceof Error ? e.message : String(e) }));
      }
    }
    setBusyEmail(null);
  };

  return (
    <div className="w-[520px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      {dots && <StepDots {...dots} />}
      <h1 className="text-[15px] font-bold tracking-[-0.01em]">Your accounts</h1>
      <p className="mt-1.5 text-[12px] leading-relaxed text-sec">
        llmpilot found the Claude sign-ins on this Mac. Add them and it watches every limit live —
        switching before a wall, fresh windows on your schedule.
      </p>

      {detected === null ? (
        <p className="mt-5 text-[12px] text-ter">Looking for signed-in accounts…</p>
      ) : groups.length === 0 ? (
        <div className="mt-5 rounded-lg border border-hairsoft bg-panel px-4 py-3 text-[12px] leading-relaxed text-sec">
          No signed-in Claude accounts found. Sign one in from your terminal —{" "}
          <code className="font-semibold">llmpilot account add</code> — and it appears here on its
          own.
        </div>
      ) : (
        <ul className="mt-5 flex flex-col">
          {groups.map((g, i) => {
            const isAdded = added.has(g.email);
            const isBusy = busyEmail === g.email;
            const pct = isAdded ? sessionPercent(state, g) : null;
            return (
              <li
                key={g.email}
                className="flex items-start justify-between gap-3 border-b border-hairsoft py-3 last:border-b-0 animate-[rise-in_200ms_ease-out_both]"
                style={{ animationDelay: `${i * 60}ms` }}
              >
                <label className="flex min-w-0 cursor-pointer items-start gap-2.5">
                  <input
                    type="checkbox"
                    className="mt-[3px] h-3.5 w-3.5 flex-none accent-accent"
                    checked={!optedOut.has(g.email)}
                    disabled={isAdded || isBusy}
                    onChange={(e) =>
                      setOptedOut((prev) => {
                        const next = new Set(prev);
                        if (e.target.checked) next.delete(g.email);
                        else next.add(g.email);
                        return next;
                      })
                    }
                  />
                  <span className="min-w-0">
                    <span className="block truncate text-[12.5px] font-semibold">{g.email}</span>
                    {g.dirs.length > 1 ? (
                      <span className="mt-0.5 block text-[10.5px] leading-relaxed text-sec">
                        {g.dirs.length} folders · one shared limit — watching{" "}
                        {g.dirs.length === 2 ? "both" : "them all"} adds no headroom
                      </span>
                    ) : i > 0 ? (
                      <span className="mt-0.5 block text-[10.5px] leading-relaxed text-sec">
                        {i === 1 ? "A second account" : "Another account"} — this is what the
                        autopilot switches to.
                      </span>
                    ) : null}
                    <span className="mt-0.5 block truncate text-[10.5px] text-ter">
                      {g.dirs.map((d) => tilde(d.config_dir)).join(" · ")}
                    </span>
                    {errs[g.email] && (
                      <span className="mt-1 block rounded-md border border-warnbd bg-warnbg px-2 py-1 text-[10.5px] text-warn">
                        {errs[g.email]}
                      </span>
                    )}
                  </span>
                </label>
                <span className="flex-none pt-[2px]">
                  {isBusy ? (
                    <span className="text-[11px] text-ter">Adding…</span>
                  ) : pct !== null ? (
                    <Meter pct={pct} />
                  ) : isAdded ? (
                    <span className="text-[11px] text-sec">Added</span>
                  ) : null}
                </span>
              </li>
            );
          })}
        </ul>
      )}

      {groups.length > 0 && (
        <button
          // Opting out of every row keeps Continue LIVE — a disabled sole
          // control with the toolbar hidden was an unsignposted dead end
          // (reviewer P1). Continue-with-none is a deliberate, reversible
          // choice; the all-checked default still makes adding the path of
          // least resistance.
          disabled={busyEmail !== null}
          onClick={toAdd.length > 0 ? addAll : onContinue}
          className="mt-5 rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd"
        >
          {busyEmail !== null
            ? "Adding…"
            : toAdd.length > 1
              ? `Add ${toAdd.length} accounts`
              : toAdd.length === 1
                ? "Add account"
                : continueLabel}
        </button>
      )}

      <p className="mt-5 text-[10.5px] leading-relaxed text-ter">
        Adding reads each account's credential once — macOS asks with a Keychain prompt; choose
        "Always Allow" so the daemon can watch limits unattended. Tokens never leave this Mac.
      </p>
      <p className="mt-2 text-[10.5px] leading-relaxed text-ter">
        The menu bar icon lives at the top right of your screen. A menu bar manager — Ice,
        Bartender, Hidden Bar — may hide it.
      </p>

      {onSkip && detected !== null && (groups.length === 0 || anyErr) && (
        // The zero-detected state needs a forward path, and so does a FAILED
        // add (denied Keychain prompt) — without this, an error here is a
        // dead end with no in-app exit.
        <button className="mt-4 text-[11.5px] text-ter hover:underline" onClick={onSkip}>
          I'll sign in later
        </button>
      )}
    </div>
  );
}
