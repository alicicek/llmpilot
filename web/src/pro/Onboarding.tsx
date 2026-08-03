import { useState } from "react";
import type { License, Quote, QuoteEcho, Rung, State } from "../api.ts";
import { fixtureState } from "../fixtures.ts";
import { Paywall } from "./Paywall.tsx";

// First launch of the official build: pain framing → the autopilot shown
// working on a masked demo fleet → the paywall. Copy obeys VOICE.md (sentence
// case, no exclamation marks, no "unlock"/"premium"); the product is shown
// working, never sold with slides. Dismissible — the free tools stay free.

interface OnboardingProps {
  license: License;
  quote: Quote | null;
  quoteFailed?: boolean;
  onRetryQuote?: () => void;
  onCheckout: (rung: Rung, echo: QuoteEcho, remindDays: number) => void;
  onRecover: () => void;
  onDismiss: () => void;
  caughtThisWeek?: number;
  handoffURL?: string | null;
  checkoutError?: string | null;
  busy?: boolean;
  // demo overrides the built-in preview fleet (tests / real detected accounts).
  demo?: State;
}

const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

function topSession(state: State, id: string): number {
  const acct = state.accounts.find((a) => a.id === id);
  const s = acct?.snapshot?.buckets.find((b) => b.kind === "session" || b.kind === "five_hour");
  return s ? Math.round(s.percent) : 0;
}

export function Onboarding(props: OnboardingProps) {
  const [step, setStep] = useState<0 | 1 | 2>(0);
  const fleet = props.demo ?? fixtureState;
  const lastSwitch = fleet.events.find((e) => e.kind === "switch" || e.kind === "rotate");

  if (step === 2) {
    return (
      <Paywall
        license={props.license}
        quote={props.quote}
        quoteFailed={props.quoteFailed}
        onRetryQuote={props.onRetryQuote}
        onCheckout={props.onCheckout}
        onRecover={props.onRecover}
        onDismiss={props.onDismiss}
        caughtThisWeek={props.caughtThisWeek}
        handoffURL={props.handoffURL}
        checkoutError={props.checkoutError}
        busy={props.busy}
      />
    );
  }

  if (step === 1) {
    return (
      <section className="mx-auto mt-14 w-[500px] max-w-[92vw]">
        <h1 className="text-[16px] font-semibold">It switches before you are blocked</h1>
        <p className="mt-2 text-[12.5px] leading-relaxed text-sec">
          Here is a fleet the autopilot is watching. When one account nears its wall, it moves you to
          one with room — you keep working.
        </p>
        <ul className="mt-4 rounded-[11px] border border-hair bg-panel">
          {fleet.accounts.slice(0, 3).map((a) => {
            const pct = topSession(fleet, a.id);
            const hot = pct >= 70;
            return (
              <li
                key={a.id}
                className="flex items-center justify-between border-b border-hairsoft px-4 py-2.5 text-[12.5px] last:border-b-0"
              >
                <span className="text-text">{a.email}</span>
                <span className={hot ? "font-semibold text-warn" : "text-sec"}>{pct}% used</span>
              </li>
            );
          })}
        </ul>
        {lastSwitch && (
          <p className="mt-3 text-[12.5px] leading-relaxed text-text">
            <span aria-hidden="true">→ </span>
            {lastSwitch.message}
          </p>
        )}
        <button className={`mt-5 ${btnPrimary}`} onClick={() => setStep(2)}>
          Turn on the autopilot
        </button>
        <button
          className="mt-3 ml-4 text-[11.5px] text-ter hover:underline"
          onClick={props.onDismiss}
        >
          Keep using the free tools
        </button>
      </section>
    );
  }

  return (
    <section className="mx-auto mt-16 w-[500px] max-w-[92vw]">
      <h1 className="text-[18px] font-semibold">Never hit a wall mid-thought</h1>
      <p className="mt-3 text-[13px] leading-relaxed text-sec">
        You run more than one Claude account to stretch your limits. Keeping track of which one still
        has room — and switching before you are blocked — is a job. llmpilot does that job: it watches
        every account and moves you before you run out.
      </p>
      <button className={`mt-5 ${btnPrimary}`} onClick={() => setStep(1)}>
        Show me the autopilot
      </button>
      <button className="mt-3 ml-4 text-[11.5px] text-ter hover:underline" onClick={props.onDismiss}>
        Skip for now
      </button>
    </section>
  );
}
