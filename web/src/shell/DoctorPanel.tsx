import { useCallback, useEffect, useState } from "react";
import { fetchDoctor, switchAccount, type DoctorFinding, type DoctorReport } from "../api.ts";
import { findingSeverity, type Severity } from "../board/severity.ts";

// The health sweep, rendered. It shows exactly what `llmpilot doctor` prints —
// one check engine on the daemon, two surfaces — and it repairs nothing
// itself: every button here is a verb the engine already accepts.
//
// The one rule that outranks tidiness: a check that could not run is shown as
// NOT CHECKED, never folded into the all-clear. "No problems found" is only
// printed when every check actually ran.

const SEVERITY_STYLE: Record<Severity, string> = {
  crit: "border-crit text-crit",
  warn: "border-warnbd text-warn",
  calm: "border-hairsoft text-sec",
};

const SEVERITY_WORD: Record<Severity, string> = {
  crit: "Critical",
  warn: "Warning",
  calm: "Note",
};

export function DoctorPanel({
  onAddAccount,
  onReviewStash,
  reloadKey,
}: {
  onAddAccount: () => void;
  onReviewStash: () => void;
  reloadKey?: unknown;
}) {
  const [report, setReport] = useState<DoctorReport | null>(null);
  // A sweep that could not run is itself news. Hiding the panel would render
  // as "nothing to report" — the false all-clear, by omission.
  const [sweepErr, setSweepErr] = useState<string | null>(null);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const [reloads, setReloads] = useState(0);
  const load = useCallback(() => {
    let live = true;
    fetchDoctor()
      .then((r) => {
        if (!live) return;
        setReport(r);
        setSweepErr(null);
      })
      .catch((e: Error) => {
        if (!live) return;
        setReport(null);
        setSweepErr(e.message);
      });
    return () => {
      live = false;
    };
  }, []);

  useEffect(() => load(), [load, reloadKey, reloads]);

  if (sweepErr) {
    return (
      <section
        aria-label="Fleet health"
        className="mx-auto mt-4 w-[720px] max-w-[94vw] rounded-lg border border-warnbd bg-warnbg px-4 py-3"
      >
        <h2 className="text-[12.5px] font-bold tracking-[-0.01em] text-warn">
          llmpilot could not check the fleet
        </h2>
        <p className="mt-0.5 text-[11px] leading-relaxed text-warn">
          {sweepErr} — nothing below is a clean bill of health. Run{" "}
          {/* The terminal names the exact command for the shape it observed,
              with the uid already resolved. Repeating a guess here would mean
              a second, shell-dependent string that can drift from it — and it
              would offer a hard kill for a daemon that may be working fine. */}
          <code className="font-semibold">llmpilot doctor</code> in a terminal to see
          what llmpilot found and what fixes it.
        </p>
      </section>
    );
  }
  if (!report) return null;

  const notChecked = report.checks.filter((c) => c.state === "not_checked");
  const ran = report.checks.filter((c) => c.state !== "not_checked");
  const notes = report.findings.length - report.problems;

  // The headline can never overstate coverage: with anything unchecked it says
  // so instead of claiming a clean fleet.
  // Defence in depth: the all-clear needs BOTH the engine's verdict and no
  // unchecked item in the list the user can see. A future daemon that got the
  // flag wrong cannot print a clean bill over a visible blind spot.
  const allClear = report.clean && notChecked.length === 0 && report.problems === 0;
  const headline = allClear
    ? `No problems found — all ${report.checks.length} checks ran.`
    : report.problems > 0
      ? `${report.problems} problem${report.problems === 1 ? "" : "s"} found`
      : notChecked.length > 0
        ? `No problems found, but ${notChecked.length} of ${report.checks.length} checks could not run`
        : // No problems, nothing unchecked, and still not clean: the document
          // contradicts itself, so say that rather than print a count that
          // means nothing. The terminal says the same sentence.
          "This report does not add up — llmpilot cannot confirm the fleet is healthy.";

  const action = (f: DoctorFinding) => {
    switch (f.remedy.verb) {
      case "move_into_fleet":
      case "sign_in_again":
      case "register_account":
        return () => onAddAccount();
      case "review_stash":
        return () => onReviewStash();
      case "switch":
        // The engine refuses a pinned target, and the daemon never emits this
        // verb for one — so this button can only ever call a switch it accepts.
        return () => {
          if (!f.remedy.target) return;
          setBusy(f.id);
          setErr(null);
          switchAccount(f.remedy.target)
            .then(() => setReloads((n) => n + 1)) // a resolved finding must not linger
            .catch((e: Error) => setErr(e.message))
            .finally(() => setBusy(null));
        };
      default:
        return null;
    }
  };

  return (
    <section
      aria-label="Fleet health"
      className="mx-auto mt-4 w-[720px] max-w-[94vw] rounded-lg border border-hairsoft bg-panel px-4 py-3"
    >
      <div className="flex items-baseline justify-between gap-3">
        <h2 className="text-[12.5px] font-bold tracking-[-0.01em]">{headline}</h2>
        <button
          className="text-[11px] font-semibold text-sec hover:text-text"
          onClick={() => setOpen((o) => !o)}
        >
          {open ? "Hide what was checked" : "What was checked"}
        </button>
      </div>
      {notes > 0 && (
        <p className="mt-0.5 text-[11px] text-ter">
          {notes} note{notes === 1 ? "" : "s"} below.
        </p>
      )}

      {report.findings.length > 0 && (
        <ul className="mt-2 flex flex-col">
          {report.findings.map((f) => {
            const run = action(f);
            return (
              <li
                key={`${f.id}:${f.accounts.join(",")}:${f.remedy.target ?? ""}`}
                className="flex items-start justify-between gap-3 border-b border-hairsoft py-2 last:border-b-0"
              >
                <div className="min-w-0">
                  <div className="flex items-center gap-2">
                    <span
                      className={`rounded border px-1.5 py-px text-[9.5px] font-bold uppercase tracking-wide ${SEVERITY_STYLE[findingSeverity(f.severity)]}`}
                    >
                      {SEVERITY_WORD[findingSeverity(f.severity)]}
                    </span>
                    <span className="truncate text-[12px] font-semibold">{f.title}</span>
                  </div>
                  <p className="mt-0.5 text-[11px] leading-relaxed text-sec">{f.detail}</p>
                  {!run && (
                    <p className="mt-0.5 text-[10.5px] text-ter">
                      {f.remedy.label}
                      {f.remedy.command && (
                        <>
                          {" · "}
                          <code className="font-semibold">{f.remedy.command}</code>
                        </>
                      )}
                    </p>
                  )}
                </div>
                {run && (
                  <button
                    disabled={busy !== null}
                    onClick={run}
                    className="shrink-0 rounded-md bg-acc-tx px-2.5 py-1 text-[11px] font-semibold text-white disabled:opacity-50 dark:bg-accent"
                  >
                    {busy === f.id ? "Working…" : f.remedy.label}
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}

      {notChecked.length > 0 && (
        <div className="mt-2 rounded-lg border border-warnbd bg-warnbg px-3 py-2">
          <p className="text-[11px] font-semibold text-warn">
            Not checked ({notChecked.length}) — llmpilot could not look at{" "}
            {notChecked.length === 1 ? "this" : "these"}:
          </p>
          <ul className="mt-1 flex flex-col gap-0.5">
            {notChecked.map((c) => (
              <li key={c.id} className="text-[10.5px] leading-relaxed text-warn">
                {c.title} — {c.why}
              </li>
            ))}
          </ul>
        </div>
      )}

      {open && (
        <p className="mt-2 text-[10.5px] leading-relaxed text-ter">
          Checked: {ran.map((c) => c.title).join(" · ")}
        </p>
      )}
      {err && (
        <p className="mt-2 rounded-lg border border-warnbd bg-warnbg px-3 py-2 text-[11px] text-warn">
          {err}
        </p>
      )}
    </section>
  );
}
