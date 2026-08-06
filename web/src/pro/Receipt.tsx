import type { Quote } from "../api.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { CloseButton } from "./CloseButton.tsx";

// SPEC-127 screen ⑥ — the receipt, and the screen that ANNOUNCES the trial.
//
// Two jobs. First, state the free/paid boundary plainly: the free column is
// honestly full for watching, hand-switching, statusline and analytics,
// because it is. A user who reads this and stays on free has been told the
// truth, and that is the trust the ask rides on.
//
// Second — and this is why it sits BEFORE the reminder — it establishes that
// a free trial exists. Duolingo announces the trial on its first screen and
// defers only the PRICE; an earlier draft of this flow deferred both, and the
// reminder screen then arrived asking "when should we remind you?" about
// nothing the user had been told (owner caught it on the mock, 2026-08-05).
// The price itself still waits for ⑧.

const btnPrimary =
  "mt-5 rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

interface Row {
  what: string;
  free: boolean;
}
const ROWS: Row[] = [
  { what: "Watch every limit, live", free: true },
  { what: "Switch accounts by hand", free: true },
  { what: "Statusline and analytics", free: true },
  { what: "Switches you before the wall", free: false },
  { what: "Books fresh windows on a schedule", free: false },
];

/** The only claim this screen makes about the user's own setup is one it can
 *  count. Below two accounts there is no headroom multiple to state, so it
 *  states nothing — never an invented statistic (VOICE.md). The count is of
 *  SWITCHABLE accounts: a watch-only lane is headroom the autopilot cannot
 *  reach, and this line is the justification for buying the autopilot. */
function headline(switchable: number): { lead: string; key: string; tail: string } {
  if (switchable >= 2) {
    return {
      lead: `${switchable} accounts. `,
      key: switchable === 2 ? "Twice the headroom." : `${switchable}× the headroom.`,
      tail: "",
    };
  }
  return { lead: "What the ", key: "autopilot", tail: " adds." };
}

export function Receipt({
  quote,
  accountsSwitchable,
  onContinue,
  onClose,
  dots,
}: {
  quote: Quote;
  /** accounts the autopilot can switch to — watch-only lanes excluded. */
  accountsSwitchable?: number;
  onContinue: () => void;
  /** Absent inside the guided flow: the corridor's only door is ⑧ (SPEC-127
   *  D9). A paywall reopened later from the banner passes it. */
  onClose?: () => void;
  dots?: { step: number; total: number };
}) {
  const h = headline(accountsSwitchable ?? 0);
  return (
    <section className="relative mx-auto w-[620px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      {dots && <StepDots {...dots} />}
      {onClose && <CloseButton onClick={onClose} />}
      <h2 className="text-[19px] font-semibold leading-[1.3] tracking-[-0.015em]">
        {h.lead}
        <span className="text-acc-tx">{h.key}</span>
        {h.tail}
      </h2>
      <p className="mt-[9px] text-[12.5px] leading-relaxed text-sec">
        Here is exactly what changes when the autopilot is on.
      </p>

      <table className="mt-5 w-full border-collapse text-[12.5px]" data-testid="receipt-table">
        <thead>
          <tr>
            <th />
            <th className="w-[66px] px-2 py-1.5 text-[9.5px] font-bold tracking-[0.09em] text-ter">
              FREE
            </th>
            <th className="w-[66px] rounded-t-md bg-acc-a px-2 py-1.5 text-[9.5px] font-bold tracking-[0.09em] text-acc-tx">
              PRO
            </th>
          </tr>
        </thead>
        <tbody>
          {ROWS.map((r) => (
            <tr key={r.what}>
              <td className="border-t border-hairsoft px-2 py-2.5 text-text">{r.what}</td>
              <td className="border-t border-hairsoft px-2 py-2.5 text-center">
                {r.free ? (
                  <span className="font-bold text-ok-tx" aria-label="included">
                    ✓
                  </span>
                ) : (
                  <span className="text-ter" aria-label="not included">
                    –
                  </span>
                )}
              </td>
              <td className="border-t border-hairsoft bg-acc-a px-2 py-2.5 text-center">
                <span className="font-bold text-ok-tx" aria-label="included">
                  ✓
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <p
        className="mt-[18px] rounded-[10px] border border-acc-bd bg-acc-a px-4 py-2.5 text-[12.5px] text-text"
        data-testid="receipt-trial"
      >
        Everything in the Pro column is{" "}
        <b className="font-semibold tabular-nums">free for {quote.trial_days} days</b>. No payment
        today.
      </p>
      <p className="mt-[18px] text-[12.5px] leading-relaxed text-text">
        Watching and switching by hand stay free, forever.
      </p>
      <button className={btnPrimary} onClick={onContinue}>
        Continue
      </button>
    </section>
  );
}
