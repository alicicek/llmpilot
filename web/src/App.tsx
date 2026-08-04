import { useEffect, useRef, useState } from "react";
import {
  ApiError,
  fetchDetected,
  startCheckout,
  switchAccount,
  type DetectedDir,
  type QuoteEcho,
  type Rung,
  type State,
} from "./api.ts";
import { useDaemonState } from "./useDaemonState.ts";
import { useLicense } from "./pro/useLicense.ts";
import { useQuote } from "./pro/useQuote.ts";
import { OnboardingFlow } from "./pro/Onboarding.tsx";
import { Paywall } from "./pro/Paywall.tsx";
import { licenseErrorCopy } from "./pro/errors.ts";
import { fixtureActivatedLicense, proFixtureParam } from "./pro/fixtures.ts";
import {
  createSchedule,
  deleteSchedule,
  fetchSchedules,
  moveSchedule,
  nextBookableReset,
  resetMinutes,
  DAY_MIN,
  WINDOW_HOURS,
  type Schedule,
} from "./schedule.ts";
import {
  FIXTURE_NOW_MINUTES,
  fixtureSchedules,
  fixtureState,
  fixtureEmptyState,
  fixtureSoloState,
} from "./fixtures.ts";
import Board from "./board/Board.tsx";
import { Toolbar } from "./shell/Toolbar.tsx";
import { History } from "./shell/History.tsx";
import { StashPanel } from "./shell/StashPanel.tsx";
import { Tour, type TourStep } from "./shell/Tour.tsx";
import { DoctorPanel } from "./shell/DoctorPanel.tsx";
import { AddAccountDialog } from "./shell/AddAccountDialog.tsx";
import { SettingsDialog, showHistoryPref, HISTORY_PREF_KEY } from "./shell/SettingsDialog.tsx";
import { StatuslineDialog } from "./shell/StatuslineDialog.tsx";

// doctorKey changes exactly when something the sweep would report changes.
// Fleet size alone missed real health flips — a re-login clears a quarantine,
// a move flips a lane from watched to switchable, a poll marks an account
// stale — all of which ride State without changing a count.
//
// Deliberately NOT state.as_of: that changes on every SSE push, and each sweep
// costs one Keychain read per account. This refetches on health, not on the
// clock. (The refresh budget and the 429 breaker live only in the sweep, so a
// breaker that trips while the page sits open still needs a reload — the
// panel's own header is the honest place to notice that.)
function doctorKey(state: State): string {
  const accounts = state.accounts
    .map((a) => `${a.id}:${a.stale ? 1 : 0}:${a.pinned ? 1 : 0}:${a.token_note ? 1 : 0}`)
    .join(",");
  const stash = state.stash ?? [];
  return `${accounts}|${stash.length}:${stash.filter((e) => e.dead).length}`;
}

function nowMinutesLocal(): number {
  const d = new Date();
  return d.getHours() * 60 + d.getMinutes();
}

function ageLabel(iso: string): string {
  const mins = Math.max(0, Math.round((Date.now() - Date.parse(iso)) / 60_000));
  if (mins < 60) return `${mins} min ago`;
  return `${Math.round(mins / 6) / 10} h ago`;
}

// URL harness: ?fixtures=1 renders designed states at the fixed 14:32 clock;
// ?fixtures=empty renders the first-run screen (screenshots + Playwright).
const fixturesParam = new URLSearchParams(window.location.search).get("fixtures");
const fixturesMode = fixturesParam !== null;

const proFixtureMode = proFixtureParam !== null;
const ONBOARDED_KEY = "llmpilot.pro.onboarded";
const TOUR_KEY = "llmpilot.tour.seen";
// ?tour=1 forces the guide open (tests, and a way to see it without clearing
// storage); the fixture harnesses otherwise never start it, so every existing
// spec keeps its unobstructed board.
const tourForced = new URLSearchParams(window.location.search).get("tour") === "1";

// The guide points at the user's OWN cockpit. Each step names one thing on
// screen and what it means for them — a step whose target is absent (no
// second account to switch to) is skipped by the Tour itself.
const TOUR_STEPS: TourStep[] = [
  {
    target: "runway",
    title: "This is your real usage",
    body: "Live limits for the account you are on — session and weekly, straight from Claude. When a bar fills, that account is done until it resets.",
  },
  {
    target: "switch",
    title: "Move to an account with room",
    body: "One click switches you. Your place is kept and there is no re-login — the autopilot does this for you before you hit a wall.",
  },
  {
    target: "fresh-window",
    title: "Open a window on your own clock",
    body: "Book a fresh 5-hour window ahead of time and it opens unattended, so your limits reset when you actually work.",
  },
  {
    target: "daemon",
    title: "It keeps running without this window",
    body: "Watching continues in the background. The icon lives at the top right of your screen — a menu bar manager like Ice or Bartender may hide it.",
  },
];

export default function App() {
  const live = useDaemonState(fixturesMode);
  const { license, setLicense, reload: reloadLicense } = useLicense(
    live.state ? `${live.state.license_status ?? ""}|${live.state.license_error ?? ""}` : undefined,
  );
  // The paywall's consent terms: prefetched once the app knows it's unlicensed.
  const {
    quote,
    failed: quoteFailed,
    reload: reloadQuote,
  } = useQuote(license?.available === true && !license.active);
  const [fixSchedules, setFixSchedules] = useState<Schedule[]>(fixtureSchedules);
  const [liveSchedules, setLiveSchedules] = useState<Schedule[]>([]);
  const [nowMin, setNowMin] = useState(nowMinutesLocal());
  const [addOpen, setAddOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [statuslineOpen, setStatuslineOpen] = useState(false);
  const [showHistory, setShowHistory] = useState(showHistoryPref());
  const [flash, setFlash] = useState<string | null>(null);
  // The autopilot-only action a free buyer just reached for. Rendered as an
  // offer card, not an alert.
  const [proPrompt, setProPrompt] = useState<string | null>(null);
  const [onboarded, setOnboarded] = useState(
    () => !proFixtureMode && localStorage.getItem(ONBOARDED_KEY) === "yes",
  );
  // The first-run flow stays mounted through checkout so the activation
  // facts screen can show (activation itself flips showOnboarding false —
  // without the latch the flow would unmount mid-story). flowClosed is
  // session-only: the accounts screen returns on the next visit if the
  // fleet is still empty (same semantics the old adoptSkipped had).
  const [flowLatched, setFlowLatched] = useState(false);
  const [flowClosed, setFlowClosed] = useState(false);
  // The guide runs once, the first time a real board is on screen — never
  // over the first-run flow (which is its own guided path) and never in the
  // fixture harnesses unless asked for.
  const [tourOpen, setTourOpen] = useState(false);
  const [tourSeen, setTourSeen] = useState(
    () => !tourForced && localStorage.getItem(TOUR_KEY) === "yes",
  );
  const [paywallOpen, setPaywallOpen] = useState(false);
  const [handoffURL, setHandoffURL] = useState<string | null>(null);
  const [checkoutError, setCheckoutError] = useState<string | null>(null);
  // True from click until the guard releases — the button shows busy instead
  // of looking dead while the POST fans out daemon → worker → Stripe.
  const [checkoutPending, setCheckoutPending] = useState(false);
  const checkoutInFlight = useRef(false);
  // Detected-but-unregistered config dirs on this Mac — the toolbar badge and
  // the Add-account dialog's "already signed in" section both read this, so
  // one adopt/move anywhere refreshes both instantly instead of drifting out
  // of sync.
  const [detected, setDetected] = useState<DetectedDir[]>([]);
  const refreshDetected = () => {
    fetchDetected()
      .then(setDetected)
      .catch(() => {});
  };

  useEffect(() => {
    if (fixturesMode) return;
    const t = setInterval(() => setNowMin(nowMinutesLocal()), 30_000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    if (fixturesMode) return;
    refreshDetected();
    // Re-check whenever the fleet's size changes (adopted via FirstRun, the
    // CLI, or this dialog) so the badge never shows a stale count.
  }, [fixturesMode, live.state?.accounts.length]);

  // Schedules ride State once the daemon serves them; until then fetch once.
  useEffect(() => {
    if (fixturesMode || live.state?.schedules) return;
    fetchSchedules()
      .then(setLiveSchedules)
      .catch(() => setLiveSchedules([]));
  }, [live.state?.schedules]);

  const state: State | null = fixturesMode
    ? fixturesParam === "empty"
      ? fixtureEmptyState
      : fixturesParam === "solo"
        ? fixtureSoloState
        : fixtureState
    : live.state;
  const conn = fixturesMode ? "live" : live.conn;
  const schedules = fixturesMode ? fixSchedules : (live.state?.schedules ?? liveSchedules);
  const nowMinutes = fixturesMode ? FIXTURE_NOW_MINUTES : nowMin;

  // A tier boundary is an offer, not a failure: pro_required gets the calm
  // card, never the warn flash. Everything else keeps the flash.
  const report = (e: unknown) => {
    if (e instanceof ApiError && (e.code === "pro_required" || e.code === "pro_unavailable")) {
      setProPrompt(e.code);
      return;
    }
    setFlash(e instanceof Error ? e.message : "That didn't take — try again.");
  };

  const actions = fixturesMode
    ? {
        onSwitch: async () => {},
        onCreate: async (input: { account_id: string; hour: number; minute: number }) => {
          setFixSchedules((s) => [
            ...s,
            { id: `fix-${input.hour}-${input.minute}-${s.length}`, ...input },
          ]);
        },
        onMove: async (id: string, hour: number, minute: number) => {
          setFixSchedules((s) => s.map((x) => (x.id === id ? { ...x, hour, minute } : x)));
        },
        onDelete: async (id: string) => {
          setFixSchedules((s) => s.filter((x) => x.id !== id));
        },
      }
    : {
        onSwitch: (id: string) => switchAccount(id).catch(report),
        onCreate: async (input: { account_id: string; hour: number; minute: number }) => {
          await createSchedule(input).catch(report);
        },
        onMove: async (id: string, hour: number, minute: number) => {
          await moveSchedule(id, hour, minute).catch(report);
        },
        onDelete: (id: string) => deleteSchedule(id).catch(report),
      };

  const bookFreshWindow = (accountId: string) => {
    const lane = schedules.filter((s) => s.account_id === accountId);
    const acct = state?.accounts.find((a) => a.id === accountId);
    const session = acct?.snapshot?.buckets.find(
      (b) => (b.kind === "session" || b.kind === "five_hour") && b.resets_at,
    );
    const activeEnd = session?.resets_at
      ? new Date(session.resets_at).getHours() * 60 + new Date(session.resets_at).getMinutes()
      : undefined;
    const slot = nextBookableReset({
      nowMinutes,
      existingResets: lane.map(resetMinutes),
      activeEndMinutes: session?.active ? activeEnd : undefined,
    });
    if (!slot) {
      setFlash(`${acct?.label ?? accountId} is fully booked — resets must sit ≥ 5 h 15 min apart.`);
      return;
    }
    const trigger = (slot.hour * 60 + slot.minute - WINDOW_HOURS * 60 + DAY_MIN) % DAY_MIN;
    void actions.onCreate({
      account_id: accountId,
      hour: Math.floor(trigger / 60),
      minute: trigger % 60,
    });
  };

  const asOfAge = !fixturesMode && state ? ageLabel(state.as_of) : null;
  const firstRun = state !== null && state.accounts.length === 0;

  // Pro gating. showOnboarding is the first-launch hard paywall (official build,
  // no entitlement yet); the banner + paywall overlay handle later prompts and
  // the honest paused state. Source builds (available=false) never see any of it.
  const proAvailable = license?.available === true;
  const proUnlicensed = proAvailable && !license.active;
  const showOnboarding = proUnlicensed && license.status === "none" && !onboarded && state !== null;
  // One path during first run: the flow owns the screen (no toolbar, no
  // board) from the accounts step through the activation facts.
  const wantFlow = (firstRun && !flowClosed) || showOnboarding;
  const showFlow = state !== null && (wantFlow || flowLatched);
  const showProBanner = proUnlicensed && !showFlow && !paywallOpen && state !== null;
  // The board is up and unobstructed: the moment the guide has something real
  // to point at.
  const boardVisible = state !== null && !showFlow && !paywallOpen;
  // Never over a fixture board unless asked: the README recorder drives
  // ?fixtures=1 with its own browser context and would otherwise film the
  // guide sitting on top of the product, eating the first drag.
  const canGuide =
    boardVisible && state.accounts.length > 0 && (!fixturesMode || tourForced);
  const caughtThisWeek = state
    ? state.events.filter(
        (e) => (e.kind === "switch" || e.kind === "rotate") && Date.now() - Date.parse(e.at) < 7 * 864e5,
      ).length
    : 0;

  // One rule: the first time a real board is on screen, the guide opens.
  useEffect(() => {
    if (!canGuide || tourSeen || tourOpen) return;
    setTourOpen(true);
  }, [canGuide, tourSeen, tourOpen]);

  // The latch arms whenever the flow becomes wanted and holds through the
  // activation flip; only an explicit close releases it.
  useEffect(() => {
    if (wantFlow) setFlowLatched(true);
  }, [wantFlow]);

  const closeFlow = () => {
    setFlowLatched(false);
    setFlowClosed(true);
  };

  const endTour = () => {
    setTourOpen(false);
    setTourSeen(true);
    // Looking at the guide through a harness must not disable it for the
    // real cockpit on this origin (same rule dismissOnboarding follows).
    if (!fixturesMode && !tourForced) localStorage.setItem(TOUR_KEY, "yes");
  };

  const dismissOnboarding = () => {
    setOnboarded(true);
    // A refusal from a previous attempt must not greet the next visit.
    setCheckoutError(null);
    closeFlow();
    if (!proFixtureMode) localStorage.setItem(ONBOARDED_KEY, "yes");
  };

  // onCheckout opens the checkout URL. The native cockpit window intercepts the
  // off-daemon navigation and hands it to the clean checkout window; a plain
  // browser follows it. In ?pro= fixture mode nothing navigates — it records the
  // handoff and simulates the silent SSE activation the daemon poller performs.
  const onCheckout = (rung: Rung, echo: QuoteEcho, remindDays: number) => {
    // Single-flight: a double-click must not create two billable Checkout
    // Sessions. NOTE the success path does NOT unmount here — the native
    // cockpit intercepts the checkout navigation into a separate window —
    // so the guard is released on a timer below, never assumed away.
    if (checkoutInFlight.current) return;
    checkoutInFlight.current = true;
    setCheckoutPending(true);
    setCheckoutError(null);
    if (proFixtureMode) {
      // The fixture handoff encodes what would ride the real POST, so tests
      // can assert the reminder choice is a real control, not chrome.
      setHandoffURL(`https://checkout.stripe.com/c/pay/${rung}?remind=${remindDays}`);
      window.setTimeout(() => {
        setLicense(fixtureActivatedLicense());
        setHandoffURL(null);
        checkoutInFlight.current = false;
        setCheckoutPending(false);
      }, 600);
      return;
    }
    if (rung === "nocard_trial") {
      // Signal the native cockpit to set its synchronizable no-card-trial
      // marker. Guarded — a no-op in a plain browser; the checkout window stays
      // script-free.
      (
        window as unknown as {
          webkit?: { messageHandlers?: { trialMarker?: { postMessage: (m: string) => void } } };
        }
      ).webkit?.messageHandlers?.trialMarker?.postMessage("nocard");
    }
    startCheckout(rung, echo, remindDays)
      .then(({ url }) => {
        setHandoffURL(url);
        // In a plain browser this page unloads before the timer fires. In the
        // NATIVE cockpit the window intercepts the navigation into the
        // separate Checkout window and nothing unmounts — without this reset
        // the guard stays stuck forever and every later buy click on any rung
        // dies silently. The handoff line is KEPT: clearing it made the
        // paywall look idle while a live payment window held an open Session,
        // inviting a re-click that would orphan that Session's activation
        // poll (reviewer 2026-07-30). 2.5s still swallows a double-click.
        // Timer armed BEFORE the assign so even a throwing navigation can
        // never freeze the busy state permanently.
        window.setTimeout(() => {
          checkoutInFlight.current = false;
          setCheckoutPending(false);
        }, 2500);
        window.location.assign(url);
      })
      .catch((e) => {
        checkoutInFlight.current = false; // allow a retry after a failed start
        setCheckoutPending(false);
        if (e instanceof ApiError && e.code === "quote_stale") {
          // The worker refused terms that drifted from what was shown. Never
          // auto-retry a purchase: refresh the quote, re-render, and require
          // a fresh human click on the new terms. Rendered IN the paywall —
          // a flash paints under the overlay and is unreadable exactly here.
          reloadQuote();
          setCheckoutError("The price or trial terms changed — review the new terms and confirm.");
          return;
        }
        // Surface the failure NEXT TO the button that was pressed — a flash
        // under the paywall overlay reads as a dead button (hit live: a
        // post-update stale session token 401'd every buy click with no
        // visible word). Known codes get their remedy copy.
        setCheckoutError(
          (e instanceof ApiError && licenseErrorCopy(e.code)) ||
            (e instanceof Error ? e.message : "That didn't take — try again."),
        );
      });
  };

  // Clearing on OPEN (not just dismiss) covers every path a stale refusal
  // could ride back in — banner reopen, restore-then-reopen, all of them.
  const openPaywall = () => {
    dismissOnboarding();
    setCheckoutError(null);
    setPaywallOpen(true);
  };

  return (
    <div className="flex min-h-screen flex-col bg-win">
      {/* One path during first run: the toolbar's competing CTAs (Add
          account, Fresh window) stay off screen until the flow closes. */}
      {!showFlow && (
        <Toolbar
          conn={conn}
          state={state}
          asOfAge={conn === "down" ? asOfAge : null}
          detectedCount={detected.filter((d) => !d.registered).length}
          onFreshWindow={bookFreshWindow}
          onAddAccount={() => setAddOpen(true)}
          onSettings={() => setSettingsOpen(true)}
          onGuide={canGuide ? () => setTourOpen(true) : undefined}
        />
      )}
      {flash && (
        <div
          role="status"
          className="flex items-center justify-between border-b border-warnbd bg-warnbg px-4 py-1.5 text-[11.5px] text-warn"
        >
          {flash}
          <button className="font-semibold" onClick={() => setFlash(null)} aria-label="Dismiss">
            ✕
          </button>
        </div>
      )}
      {proPrompt && (
        // VOICE scope rule: one bold fact line, the consequence in plain
        // words, then the action. No warn colors — nothing went wrong.
        <div
          role="status"
          data-testid="pro-prompt"
          className="flex items-start justify-between gap-4 border-b border-hair bg-panel px-4 py-3"
        >
          <div className="max-w-[640px]">
            <p className="text-[12.5px] font-semibold">
              Fresh windows run on your schedule — that is the autopilot's job.
            </p>
            <p className="mt-0.5 text-[11.5px] leading-relaxed text-sec">
              {proPrompt === "pro_unavailable"
                ? "This build was compiled without it. Watching, switching, the statusline, and history keep working here — the app at llmpilot.dev adds the autopilot."
                : "Watching every account, switching by hand, the statusline, and history stay free. The autopilot books your windows and moves you before a wall, unattended."}
            </p>
          </div>
          <div className="flex flex-none items-center gap-3">
            {proPrompt === "pro_required" && (
              <button
                className="rounded-lg bg-acc-tx px-3 py-1.5 text-[11.5px] font-semibold text-white dark:bg-accent"
                onClick={() => {
                  setProPrompt(null);
                  openPaywall();
                }}
              >
                Try it free for 4 days
              </button>
            )}
            <button
              className="text-[11.5px] text-sec hover:underline"
              onClick={() => setProPrompt(null)}
              aria-label="Dismiss"
            >
              Not now
            </button>
          </div>
        </div>
      )}
      {showProBanner && !proPrompt && license && (
        <div className="flex items-center justify-between gap-4 border-b border-hair bg-panel px-4 py-1.5 text-[11.5px]">
          <span className="text-sec">
            {license.status === "lapsed" || license.status === "revoked"
              ? "The autopilot is paused — your schedules are kept."
              : "The autopilot is off — turn it on to watch your windows."}
          </span>
          <button
            className="font-semibold text-acc-tx hover:underline"
            onClick={openPaywall}
          >
            Turn on the autopilot
          </button>
        </div>
      )}
      <main
        className={
          showFlow
            ? // The flow sits vertically centred — mt-16 stranded it at the
              // top of a full-height window (owner's fresh-user sweep).
              "flex flex-1 flex-col items-center justify-center overflow-y-auto py-10"
            : "flex-1"
        }
      >
        {conn === "down" && !state ? (
          <div className="mx-auto mt-16 w-[440px] max-w-[92vw] text-[12.5px] leading-relaxed">
            <p className="font-semibold">Daemon not running — nothing here is live.</p>
            <p className="mt-1 text-sec">
              Start it: <code className="font-semibold">llmpilot daemon install</code> (or
              foreground: <code className="font-semibold">llmpilot daemon run</code>), then
              reload.
            </p>
          </div>
        ) : !state ? (
          <p className="p-6 text-[12.5px] text-ter">Connecting to the daemon…</p>
        ) : showFlow ? (
          <>
            {/* The toolbar (and its daemon pill) is hidden behind the flow —
                a dead daemon must still be named, or the wall animates live
                colors over stale numbers. */}
            {conn !== "live" && (
              <p className="mb-4 text-[11px] text-ter" role="status">
                {conn === "connecting"
                  ? "Connecting to the daemon…"
                  : asOfAge
                    ? `Daemon down — numbers as of ${asOfAge}`
                    : "Daemon not running."}
              </p>
            )}
            {/* Add-first: the accounts screen runs before any pitch, the
                wall runs on the user's own fleet once two genuine accounts
                exist, and the ask comes last. */}
            <OnboardingFlow
              license={license}
              tour={showOnboarding}
              state={state}
              quote={quote}
              quoteFailed={quoteFailed}
              onRetryQuote={reloadQuote}
              onCheckout={onCheckout}
              onRecover={() => setSettingsOpen(true)}
              onDismiss={dismissOnboarding}
              onExit={closeFlow}
              caughtThisWeek={caughtThisWeek || undefined}
              handoffURL={handoffURL}
              checkoutError={checkoutError}
              busy={checkoutPending}
            />
          </>
        ) : (
          <>
            {!fixturesMode && (
              <DoctorPanel
                onAddAccount={() => setAddOpen(true)}
                onReviewStash={() =>
                  document.getElementById("kept-signins")?.scrollIntoView({ block: "center" })
                }
                reloadKey={doctorKey(state)}
              />
            )}
            <StashPanel stash={state.stash ?? []} />
            <Board
              state={state}
              schedules={schedules}
              nowMinutes={nowMinutes}
              canSchedule={!proUnlicensed}
              {...actions}
            />
            {showHistory && <History state={state} fixturesMode={fixturesMode} defaultOpen={fixturesMode} />}
          </>
        )}
      </main>
      {paywallOpen && license && (
        <div className="fixed inset-0 z-40 overflow-y-auto bg-win/95 backdrop-blur-sm">
          <div className="flex min-h-full items-start justify-center py-14">
            <Paywall
              accountsWatched={state?.accounts.length ?? 0}
              license={license}
              quote={quote}
              quoteFailed={quoteFailed}
              onRetryQuote={reloadQuote}
              onCheckout={onCheckout}
              onRecover={() => {
                setPaywallOpen(false);
                setSettingsOpen(true);
              }}
              onDismiss={() => {
                setPaywallOpen(false);
                setCheckoutError(null);
              }}
              caughtThisWeek={caughtThisWeek || undefined}
              handoffURL={handoffURL}
              checkoutError={checkoutError}
              busy={checkoutPending}
            />
          </div>
        </div>
      )}
      {tourOpen && canGuide && <Tour steps={TOUR_STEPS} onDone={endTour} />}
      <AddAccountDialog
        open={addOpen}
        onOpenChange={setAddOpen}
        detected={detected}
        fleetDir={(state?.accounts ?? []).find((a) => !a.pinned)?.config_dir ?? ""}
        onDetectedChange={refreshDetected}
      />
      <SettingsDialog
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        state={state}
        offline={fixturesMode || conn !== "live"}
        showHistory={showHistory}
        onShowHistory={(on) => {
          localStorage.setItem(HISTORY_PREF_KEY, on ? "on" : "off");
          setShowHistory(on);
        }}
        onOpenStatusline={() => setStatuslineOpen(true)}
        license={license}
        onTurnOn={openPaywall}
        onReloadLicense={reloadLicense}
      />
      <StatuslineDialog
        open={statuslineOpen}
        onOpenChange={setStatuslineOpen}
        offline={fixturesMode || conn !== "live"}
      />
    </div>
  );
}
