import { useRef, useState } from "react";
import type { License, Quote, QuoteEcho, Rung, State } from "../api.ts";
import { fixtureState } from "../fixtures.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { FirstRun } from "../shell/FirstRun.tsx";
import { CloseButton } from "./CloseButton.tsx";
import { Paywall } from "./Paywall.tsx";
import { demoLanes, SwitchDemo } from "./SwitchDemo.tsx";

// The first-run flow (SPEC 1.2.6): your accounts → the wall (the switch shown
// happening) → the offer → the reminder → Pro is on. One path, step dots, no
// toolbar behind it. The accounts step exists only when the fleet was empty
// at flow start; the ask steps exist only on official builds (tour). Copy
// obeys VOICE.md; the product is shown working, never sold with slides.

interface OnboardingProps {
  license: License | null;
  /** the pro tour is available (official build, unlicensed, not dismissed). */
  tour: boolean;
  /** live daemon state — the wall runs on it when it holds two genuine accounts. */
  state: State;
  quote: Quote | null;
  quoteFailed?: boolean;
  onRetryQuote?: () => void;
  onCheckout: (rung: Rung, echo: QuoteEcho, remindDays: number) => void;
  onRecover: () => void;
  /** dismisses the tour for good (writes the onboarded mark). */
  onDismiss: () => void;
  /** closes an accounts-only flow (no tour to dismiss). */
  onExit: () => void;
  caughtThisWeek?: number;
  handoffURL?: string | null;
  checkoutError?: string | null;
  busy?: boolean;
}

const btnPrimary =
  "rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

type Phase = "accounts" | "wall" | "ask";

export function OnboardingFlow(props: OnboardingProps) {
  // Sticky: adding the first account flips the fleet non-empty, but the
  // accounts screen must stay up to show the gauges filling.
  const startedEmpty = useRef(props.state.accounts.length === 0);
  const [phase, setPhase] = useState<Phase>(startedEmpty.current ? "accounts" : "wall");
  // The wall's lanes freeze at first render: live SSE pushes re-render the
  // flow with fresh state, and a re-derived lanes array would restart the
  // demo loop before it ever reaches the switch. The story runs on one
  // consistent snapshot.
  const frozenLanes = useRef<ReturnType<typeof demoLanes>>(null);
  const frozenMasked = useRef(false);
  // The ask must survive a transient license failure: useLicense nulls the
  // license on any failed fetch — and it refetches exactly during checkout
  // activation. With the toolbar and board suppressed behind the flow, a
  // null here once rendered a fully blank window (reviewer P0). The last
  // known license carries the screen through the gap.
  const lastLicense = useRef<License | null>(null);
  if (props.license) lastLicense.current = props.license;
  const license = props.license ?? lastLicense.current;
  const total = (startedEmpty.current ? 1 : 0) + 4;
  const wallStep = startedEmpty.current ? 1 : 0;

  if (phase === "accounts") {
    return (
      <FirstRun
        state={props.state}
        dots={props.tour ? { step: 0, total } : undefined}
        continueLabel={props.tour ? "Continue" : "Open the cockpit"}
        onContinue={props.tour ? () => setPhase("wall") : props.onExit}
        // The exit must NOT depend on the tour: a source build (or one
        // failed license fetch) with nothing detected and no toolbar behind
        // the flow was a zero-control dead end (reviewer P0).
        onSkip={props.tour ? () => setPhase("wall") : props.onExit}
      />
    );
  }

  if (phase === "ask" && license) {
    return (
      <Paywall
        license={license}
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
        dots={{ base: wallStep + 1, total }}
        accountsWatched={props.state.accounts.length}
      />
    );
  }

  // The wall — also the fallback while the ask has no license at all (only
  // reachable if the license was never fetched).
  if (frozenLanes.current === null) {
    const real = demoLanes(props.state);
    frozenLanes.current = real ?? demoLanes(fixtureState);
    frozenMasked.current = real === null;
  }
  const lanes = frozenLanes.current;
  const masked = frozenMasked.current;
  return (
    <section className="relative w-[600px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      <StepDots step={wallStep} total={total} />
      {/* The screen behind this one is suppressed, so the wall owes the same
          escape the offer gives — the ✕ is that escape here too. */}
      <CloseButton onClick={props.onDismiss} label="Close" testId="wall-close" />
      <h1 className="text-[18px] font-semibold">Never hit a wall mid-thought</h1>
      <p className="mt-2 text-[12.5px] leading-relaxed text-sec">
        You know the wall: Claude stops, and it's a 5 h wait — or another login and your place
        lost. Watch the autopilot handle it — a preview{" "}
        {masked ? "on a demo fleet" : "of your own accounts"}; nothing switches until it's on.
      </p>
      {lanes && <SwitchDemo lanes={lanes} />}
      <p className="mt-5 text-[12.5px] leading-relaxed text-text">
        Watching and switching by hand are free, forever. The autopilot is the part that does it
        for you.
      </p>
      <button className={`mt-4 ${btnPrimary}`} onClick={() => setPhase("ask")}>
        Turn on the autopilot
      </button>
    </section>
  );
}
