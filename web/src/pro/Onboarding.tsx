import { useEffect, useMemo, useRef, useState } from "react";
import type { DetectedDir, License, Quote, QuoteEcho, Rung, State } from "../api.ts";
import { fixtureState } from "../fixtures.ts";
import { StepDots } from "../shell/StepDots.tsx";
import { FirstRun } from "../shell/FirstRun.tsx";
import { BlindSpotScreen, WallScreen, WindowsScreen } from "./Education.tsx";
import { Paywall } from "./Paywall.tsx";
import { demoLanes, SwitchDemo } from "./SwitchDemo.tsx";

// The first-run ladder (SPEC-127, replacing 1.2.6's five screens): teach the
// problem before asking for anything, and defer the PRICE — not the trial —
// to the end.
//
//   ① the wall   ② the blind spot   ③ your accounts   ④ the switch
//   ⑤ fresh windows   ⑥ the receipt   ⑦ the reminder   ⑧ the price
//   ⑨ Pro is on
//
// ⑥–⑨ live inside Paywall.tsx. ③ exists only when the fleet was empty at
// flow start; the education and ask screens exist only on official builds
// (tour). ④ deliberately follows ③ so the switch demo runs on the accounts
// the user just added rather than on a masked fixture pair.
//
// ONE-WAY CORRIDOR (owner 2026-08-05): no screen before the price offers an
// exit. Every screen still offers a way FORWARD — that is not the same thing
// — and the price screen's ✕ is the flow's single door. Outside the guided
// flow (a paywall reopened later from the banner) every screen keeps its ✕;
// the corridor is a property of onboarding, not of the paywall.

interface OnboardingProps {
  license: License | null;
  /** the pro tour is available (official build, unlicensed, not dismissed). */
  tour: boolean;
  /** live daemon state — the switch demo runs on it when it holds two genuine accounts. */
  state: State;
  /** config dirs /v1/detect found, as the app already holds them. ② counts
   *  identities from these plus the fleet, so it never fetches its own. */
  detected: DetectedDir[];
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
  "mt-4 rounded-lg bg-acc-tx px-4 py-2 text-[13px] font-semibold text-white transition-colors duration-150 disabled:opacity-50 dark:bg-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-acc-bd";

type Phase = "wall" | "blind" | "accounts" | "switch" | "windows" | "ask";

export function OnboardingFlow(props: OnboardingProps) {
  // Frozen at mount: adding the first account flips the fleet non-empty, and
  // that would rewrite the ladder mid-walk (and the step dots with it).
  const startedEmpty = useRef(props.state.accounts.length === 0).current;

  // `tour` may only ever go UP. Freezing it outright was wrong in one
  // direction: an empty fleet mounts this flow the moment state arrives,
  // which can be BEFORE /v1/license answers — so `props.tour` is still false
  // on a perfectly normal unlicensed build. Freezing that left the ladder as
  // the accounts step alone, and once the licence landed `showOnboarding`
  // held the flow open while the only forward control called onExit: stuck.
  // Downgrades stay ignored, which is what the original freeze was for
  // (activating flips props.tour false mid-flow).
  const [tour, setTour] = useState(props.tour);
  useEffect(() => {
    if (props.tour && !tour) {
      setTour(true);
      // The ladder just gained its education screens and the user has been
      // looking at the accounts step for the length of a fetch: start at the
      // beginning rather than dropping them into the middle.
      setPhase("wall");
    }
  }, [props.tour, tour]);

  const phases = useMemo<Phase[]>(() => {
    const p: Phase[] = [];
    if (tour) p.push("wall", "blind");
    if (startedEmpty) p.push("accounts");
    if (tour) p.push("switch", "windows");
    return p;
  }, [tour, startedEmpty]);

  const [phase, setPhase] = useState<Phase>(() => (tour ? "wall" : startedEmpty ? "accounts" : "ask"));

  // ② asks one question: how many Claude identities does this Mac have? That
  // is the fleet's accounts plus any signed-in folder not yet added — and it
  // is answered from state the app already holds, so the screen makes no
  // request of its own and stays deterministic under the fixture harness.
  // Deduped case-INSENSITIVELY, keeping the first spelling seen. The fleet
  // and .claude.json can disagree on casing for one person, and a raw Set
  // would then count them twice — making ② announce a second account that
  // does not exist and offer headroom to match. First display form wins so
  // the address still renders the way its own config writes it.
  const identities = (() => {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const email of [
      ...props.state.accounts.map((a) => a.email),
      ...props.detected.filter((d) => d.signed_in !== false).map((d) => d.email),
    ]) {
      if (!email) continue;
      const key = email.toLowerCase();
      if (seen.has(key)) continue;
      seen.add(key);
      out.push(email);
    }
    return out;
  })();

  // The switch demo's lanes freeze at first render: live SSE pushes would
  // otherwise re-derive the array and restart the loop before it ever
  // reaches the switch.
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

  const total = phases.length + (tour ? 4 : 0);
  const stepOf = (p: Phase) => phases.indexOf(p);
  // "ask" is never a member of phases, so an unguarded indexOf(-1) would
  // select phases[0] and send the user back to screen ① — a loop with no
  // exit now that the corridor has removed the per-screen ✕.
  const advance = () => {
    const i = phases.indexOf(phase);
    setPhase(i < 0 ? "ask" : (phases[i + 1] ?? "ask"));
  };

  if (phase === "wall") {
    return (
      <WallScreen
        step={stepOf("wall")}
        total={total}
        email={identities[0]}
        onContinue={advance}
      />
    );
  }

  if (phase === "blind") {
    return (
      <BlindSpotScreen
        step={stepOf("blind")}
        total={total}
        emails={identities}
        onContinue={advance}
      />
    );
  }

  if (phase === "accounts") {
    return (
      <FirstRun
        state={props.state}
        dots={{ step: stepOf("accounts"), total }}
        continueLabel={tour ? "Continue" : "Open the cockpit"}
        onContinue={tour ? advance : props.onExit}
        // The forward path must NOT depend on the tour: a source build (or
        // one failed license fetch) with nothing detected and no toolbar
        // behind the flow was a zero-control dead end (reviewer P0).
        onSkip={tour ? advance : props.onExit}
      />
    );
  }

  if (phase === "windows") {
    return (
      <WindowsScreen
        step={stepOf("windows")}
        total={total}
        email={identities[0]}
        onContinue={advance}
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
        dots={{ base: phases.length, total }}
        accountsWatched={props.state.accounts.length}
        accountsSwitchable={props.state.accounts.filter((a) => !a.pinned).length}
      />
    );
  }

  // ④ the switch — also the fallback while the ask has no license at all
  // (only reachable if the license was never fetched).
  if (frozenLanes.current === null) {
    const real = demoLanes(props.state);
    frozenLanes.current = real ?? demoLanes(fixtureState);
    frozenMasked.current = real === null;
  }
  const lanes = frozenLanes.current;
  const masked = frozenMasked.current;
  return (
    <section className="w-[620px] max-w-[92vw] animate-[rise-in_200ms_ease-out_both]">
      <StepDots step={stepOf("switch")} total={total} />
      <h1 className="text-[19px] font-semibold leading-[1.3] tracking-[-0.015em]">
        It moves you <span className="text-acc-tx">before</span> you hit the wall.
      </h1>
      <p className="mt-[9px] text-[12.5px] leading-relaxed text-sec">
        Watch it happen on {masked ? "a demo fleet" : "your own accounts"}. Nothing switches until
        you turn it on.
      </p>
      {lanes && <SwitchDemo lanes={lanes} />}
      <p className="mt-[18px] text-[12.5px] leading-relaxed text-text">
        You keep working. It handles the accounts.
      </p>
      {/* Reached as ④ (advance) or as the fallback for an "ask" with no
          licence at all. In that second case there is no ask to advance TO,
          so Continue would strand the user on a screen whose ✕ the corridor
          removed: the honest control there is the way out. */}
      <button className={btnPrimary} onClick={phase === "ask" ? props.onExit : advance}>
        {phase === "ask" ? "Open the cockpit" : "Continue"}
      </button>
    </section>
  );
}
