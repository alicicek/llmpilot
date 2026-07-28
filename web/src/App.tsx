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
import { Onboarding } from "./pro/Onboarding.tsx";
import { Paywall } from "./pro/Paywall.tsx";
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
import { FIXTURE_NOW_MINUTES, fixtureSchedules, fixtureState, fixtureEmptyState } from "./fixtures.ts";
import Board from "./board/Board.tsx";
import { Toolbar } from "./shell/Toolbar.tsx";
import { History } from "./shell/History.tsx";
import { FirstRun } from "./shell/FirstRun.tsx";
import { StashPanel } from "./shell/StashPanel.tsx";
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
  const [onboarded, setOnboarded] = useState(
    () => !proFixtureMode && localStorage.getItem(ONBOARDED_KEY) === "yes",
  );
  // Adopt-first funnel: with an empty fleet the adopt screen renders before
  // any pitch; skip is the forward path when nothing was detected (session
  // state only — the adopt screen returns after onboarding).
  const [adoptSkipped, setAdoptSkipped] = useState(false);
  const [paywallOpen, setPaywallOpen] = useState(false);
  const [handoffURL, setHandoffURL] = useState<string | null>(null);
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
      : fixtureState
    : live.state;
  const conn = fixturesMode ? "live" : live.conn;
  const schedules = fixturesMode ? fixSchedules : (live.state?.schedules ?? liveSchedules);
  const nowMinutes = fixturesMode ? FIXTURE_NOW_MINUTES : nowMin;

  const report = (e: unknown) =>
    setFlash(e instanceof Error ? e.message : "That didn't take — try again.");

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
  const showProBanner = proUnlicensed && !showOnboarding && !paywallOpen && state !== null;
  const caughtThisWeek = state
    ? state.events.filter(
        (e) => (e.kind === "switch" || e.kind === "rotate") && Date.now() - Date.parse(e.at) < 7 * 864e5,
      ).length
    : 0;

  const dismissOnboarding = () => {
    setOnboarded(true);
    if (!proFixtureMode) localStorage.setItem(ONBOARDED_KEY, "yes");
  };

  // onCheckout opens the checkout URL. The native cockpit window intercepts the
  // off-daemon navigation and hands it to the clean checkout window; a plain
  // browser follows it. In ?pro= fixture mode nothing navigates — it records the
  // handoff and simulates the silent SSE activation the daemon poller performs.
  const onCheckout = (rung: Rung, echo: QuoteEcho) => {
    // Single-flight: a double-click must not create two billable Checkout
    // Sessions. The success path navigates away (component unmounts), so the
    // guard only resets on failure or in fixture mode.
    if (checkoutInFlight.current) return;
    checkoutInFlight.current = true;
    if (proFixtureMode) {
      setHandoffURL(`https://checkout.stripe.com/c/pay/${rung}`);
      window.setTimeout(() => {
        setLicense(fixtureActivatedLicense());
        setHandoffURL(null);
        checkoutInFlight.current = false;
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
    startCheckout(rung, echo)
      .then(({ url }) => {
        setHandoffURL(url);
        window.location.assign(url);
      })
      .catch((e) => {
        checkoutInFlight.current = false; // allow a retry after a failed start
        if (e instanceof ApiError && e.code === "quote_stale") {
          // The worker refused terms that drifted from what was shown. Never
          // auto-retry a purchase: refresh the quote, re-render, and require
          // a fresh human click on the new terms.
          reloadQuote();
          setFlash("The price or trial terms changed — review the new terms and confirm.");
          return;
        }
        report(e);
      });
  };

  const openPaywall = () => {
    dismissOnboarding();
    setPaywallOpen(true);
  };

  return (
    <div className="flex min-h-screen flex-col bg-win">
      <Toolbar
        conn={conn}
        state={state}
        asOfAge={conn === "down" ? asOfAge : null}
        detectedCount={detected.filter((d) => !d.registered).length}
        onFreshWindow={bookFreshWindow}
        onAddAccount={() => setAddOpen(true)}
        onSettings={() => setSettingsOpen(true)}
      />
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
      {showProBanner && license && (
        <div className="flex items-center justify-between gap-4 border-b border-hair bg-panel px-4 py-1.5 text-[11.5px]">
          <span className="text-sec">
            {license.status === "lapsed" || license.status === "revoked"
              ? "The autopilot is paused — your schedules are kept."
              : "The autopilot is off — turn it on to watch your windows."}
          </span>
          <button
            className="font-semibold text-acc-tx hover:underline"
            onClick={() => setPaywallOpen(true)}
          >
            Turn on the autopilot
          </button>
        </div>
      )}
      <main className="flex-1">
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
        ) : showOnboarding && license && (!firstRun || adoptSkipped) ? (
          // Adopt-first: the pitch runs AFTER adoption, on the user's own
          // fleet — the demo fixtures appear only when adoption was skipped.
          <Onboarding
            license={license}
            quote={quote}
            quoteFailed={quoteFailed}
            onRetryQuote={reloadQuote}
            onCheckout={onCheckout}
            onRecover={() => setSettingsOpen(true)}
            onDismiss={dismissOnboarding}
            caughtThisWeek={caughtThisWeek || undefined}
            handoffURL={handoffURL}
            demo={state.accounts.length > 0 ? state : undefined}
          />
        ) : firstRun && !adoptSkipped ? (
          <FirstRun onSkip={showOnboarding ? () => setAdoptSkipped(true) : undefined} />
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
            <Board state={state} schedules={schedules} nowMinutes={nowMinutes} {...actions} />
            {showHistory && <History state={state} fixturesMode={fixturesMode} defaultOpen={fixturesMode} />}
          </>
        )}
      </main>
      {paywallOpen && license && (
        <div className="fixed inset-0 z-40 overflow-y-auto bg-win/95 backdrop-blur-sm">
          <div className="flex min-h-full items-start justify-center pb-10">
            <Paywall
              license={license}
              quote={quote}
              quoteFailed={quoteFailed}
              onRetryQuote={reloadQuote}
              onCheckout={onCheckout}
              onRecover={() => {
                setPaywallOpen(false);
                setSettingsOpen(true);
              }}
              onDismiss={() => setPaywallOpen(false)}
              caughtThisWeek={caughtThisWeek || undefined}
              handoffURL={handoffURL}
            />
          </div>
        </div>
      )}
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
