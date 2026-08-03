// Mirrors of the daemon's JSON shapes (internal/daemon/daemon.go,
// internal/store/store.go). Kind is an open string — unknown bucket kinds
// must render, never crash (bucket-agnostic rule).

import { authHeaders } from "./auth.ts";

export interface Account {
  id: string;
  label: string;
  email: string;
  config_dir: string;
  keychain_service: string;
  pinned: boolean;
}

export interface Bucket {
  kind: string;
  scope?: string;
  percent: number;
  resets_at?: string;
  severity?: string;
  active?: boolean;
}

export interface UsageSnapshot {
  account_id: string;
  as_of: string;
  buckets: Bucket[];
}

export interface DaemonEvent {
  at: string;
  kind: string;
  account_id?: string;
  message: string;
  late?: boolean;
}

export interface AccountState extends Account {
  snapshot?: UsageSnapshot;
  token_note?: string;
  /** the daemon's authoritative stale mark: the stored token expired while
   * idle, so `snapshot` is frozen at last-known until the account wakes. */
  stale?: boolean;
}

/** One preserved foreign credential (a swap found an unknown sign-in in the
 * global slot and kept it instead of guessing an owner). Metadata only —
 * the credential itself never rides the wire. `dead` marks a lineage the
 * token endpoint has rejected: adopting needs a fresh sign-in. */
export interface StashEntry {
  fingerprint: string;
  label?: string;
  stashed_at: string;
  dead?: boolean;
}

export interface State {
  accounts: AccountState[];
  active_id: string;
  events: DaemonEvent[];
  /** preserved sign-ins awaiting adopt/discard; [] when none (never null). */
  stash?: StashEntry[];
  as_of: string;
  /** rides State once the daemon serves it; SSE keeps it live. */
  schedules?: import("./schedule.ts").Schedule[];
  /** the daemon's status projection; a change signals a license refetch. */
  license_status?: string;
  /** last terminal licensing refusal code (seat_limit_reached, ...). */
  license_error?: string;
}

export type Connection = "connecting" | "live" | "down";

// Mirror of store.Config (internal/store/config.go), kept in sync by hand.
export interface Config {
  autopilot?: {
    disabled?: boolean;
    threshold_percent?: number;
    cooldown_minutes?: number;
  };
  notifications?: {
    disabled?: boolean;
    thresholds?: number[];
  };
  plan_cost_monthly?: Record<string, number>;
}

export interface DetectedDir {
  config_dir: string;
  email: string;
  registered: boolean;
  /** this dir's sign-in was already migrated into the fleet (its source
   *  copy retired) — informational only, never offer a verb on it. */
  moved: boolean;
}

export async function fetchConfig(): Promise<Config> {
  const res = await fetch("/v1/config");
  if (!res.ok) throw new Error(`config: HTTP ${res.status}`);
  return res.json();
}

export async function saveConfig(cfg: Config): Promise<void> {
  const res = await fetch("/v1/config", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(cfg),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `config: HTTP ${res.status}`);
  }
}

export async function fetchDetected(): Promise<DetectedDir[]> {
  const res = await fetch("/v1/detect");
  if (!res.ok) throw new Error(`detect: HTTP ${res.status}`);
  return ((await res.json()) as DetectedDir[] | null) ?? [];
}

export async function adoptAccount(configDir: string): Promise<void> {
  const res = await fetch("/v1/adopt", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ config_dir: configDir }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `adopt: HTTP ${res.status}`);
  }
}

/** Outcome of moving a detected sign-in into the fleet. `clone_suspect` means
 *  the move completed but a second copy of the credential may still exist —
 *  `note` explains why llmpilot will hold off switching to it. */
export interface AdoptMoveResult {
  account: Account;
  outcome: "complete" | "clone_suspect";
  note: string;
}

/** Move a detected sign-in into the fleet: copies the credential into
 *  llmpilot's own storage, registers the account switchable, and DELETES the
 *  sign-in from the source config dir. Destructive; auth-guarded exactly like
 *  stash adopt below. */
export async function adoptMove(configDir: string, label?: string): Promise<AdoptMoveResult> {
  const res = await fetch("/v1/adopt/move", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(label ? { config_dir: configDir, label } : { config_dir: configDir }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `move: HTTP ${res.status}`);
  }
  return (await res.json()) as AdoptMoveResult;
}

/** Adopt a stashed sign-in into the fleet. Auth-guarded mutation. */
export async function adoptStash(fingerprint: string, label?: string): Promise<void> {
  const res = await fetch("/v1/stash/adopt", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(label ? { fingerprint, label } : { fingerprint }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `adopt: HTTP ${res.status}`);
  }
}

/** Discard a stashed sign-in — deletes its stored credential. */
export async function discardStash(fingerprint: string): Promise<void> {
  const res = await fetch("/v1/stash/discard", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ fingerprint }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `discard: HTTP ${res.status}`);
  }
}

export interface LoginStart {
  authorize_url: string;
  state: string;
}

/** Begin an in-app sign-in: the daemon mints PKCE+state and returns the
 *  approval URL. The verifier never reaches this page. */
export async function startLogin(): Promise<LoginStart> {
  const res = await fetch("/v1/login/start", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: "{}",
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `sign-in start: HTTP ${res.status}`);
  }
  return (await res.json()) as LoginStart;
}

/** Begin the zero-paste browser sign-in: the daemon starts a loopback
 *  listener and returns the approval URL to open in the real browser plus an
 *  attempt id. The daemon completes the exchange itself when the browser
 *  redirects back — the caller polls fetchBrowserLoginStatus for THIS attempt
 *  (fleet-size inference never completes on a re-login). */
export async function startBrowserLogin(): Promise<{ authorize_url: string; attempt_id: string }> {
  const res = await fetch("/v1/login/browser", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: "{}",
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `sign-in start: HTTP ${res.status}`);
  }
  return (await res.json()) as { authorize_url: string; attempt_id: string };
}

export interface BrowserLoginStatus {
  status: "pending" | "done" | "failed";
  error?: string;
  account_id?: string;
}

/** One browser sign-in attempt's outcome. */
export async function fetchBrowserLoginStatus(attemptId: string): Promise<BrowserLoginStatus> {
  const res = await fetch(`/v1/login/browser/status?attempt=${encodeURIComponent(attemptId)}`, {
    headers: authHeaders(),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `sign-in status: HTTP ${res.status}`);
  }
  return (await res.json()) as BrowserLoginStatus;
}

/** Finish the sign-in with the code+state from the approval page. */
export async function completeLogin(code: string, state: string): Promise<Account> {
  const res = await fetch("/v1/login/complete", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ code, state }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `sign-in: HTTP ${res.status}`);
  }
  return (await res.json()) as Account;
}

// Go marshals nil slices as null — normalize so the UI never guards.
export function normalizeState(raw: State): State {
  return {
    ...raw,
    accounts: (raw.accounts ?? []).map((a) => ({
      ...a,
      snapshot: a.snapshot
        ? { ...a.snapshot, buckets: a.snapshot.buckets ?? [] }
        : a.snapshot,
    })),
    events: raw.events ?? [],
  };
}

export async function fetchState(): Promise<State> {
  const res = await fetch("/v1/state");
  if (!res.ok) throw new Error(`state: HTTP ${res.status}`);
  return normalizeState((await res.json()) as State);
}

// --- doctor (GET /v1/doctor — the read-only health sweep) -----------------

/** The remedy verbs the daemon emits. Each maps to a control that already
 *  exists here; "none" means there is nothing to press, said out loud. */
export type DoctorVerb =
  | "none"
  | "move_into_fleet"
  | "sign_in_again"
  | "switch"
  | "review_stash"
  | "install_daemon"
  | "install_statusline"
  | "register_account";

export interface DoctorRemedy {
  verb: DoctorVerb;
  label: string;
  target?: string;
  command?: string;
}

export interface DoctorFinding {
  id: string;
  check: string;
  severity: "critical" | "warning" | "info";
  title: string;
  detail: string;
  accounts: string[];
  remedy: DoctorRemedy;
}

/** A check that could NOT run reports "not_checked" with a reason. It must
 *  never render as passing — a partial sweep is not a clean bill. */
export interface DoctorCheck {
  id: string;
  title: string;
  state: "ok" | "finding" | "not_checked";
  why?: string;
}

export interface DoctorReport {
  as_of: string;
  clean: boolean;
  problems: number;
  findings: DoctorFinding[];
  checks: DoctorCheck[];
}

export async function fetchDoctor(): Promise<DoctorReport> {
  const res = await fetch("/v1/doctor");
  if (!res.ok) throw new Error(`doctor: HTTP ${res.status}`);
  const raw = (await res.json()) as DoctorReport;
  // A sweep always runs a fixed list of checks, so a document with none is not
  // a health report — rendering it would print "all 0 checks ran", which says
  // nothing about the fleet while looking like an answer.
  if (!Array.isArray(raw.checks) || raw.checks.length === 0) {
    throw new Error("the daemon answered without a single health check");
  }
  // Defensive, same reason as normalizeState: a null list must not crash a
  // panel whose whole job is telling the truth about the fleet.
  return {
    ...raw,
    findings: (raw.findings ?? []).map((f) => ({ ...f, accounts: f.accounts ?? [] })),
    checks: raw.checks,
  };
}

// --- statusline editor (internal/statusline mirrors) ---------------------

export interface SLOptionSpec {
  key: string;
  label: string;
  type: "bool" | "enum" | "string" | "color";
  values?: string[];
  default?: unknown;
}

export interface SLSegmentSpec {
  id: string;
  name: string;
  desc: string;
  deps?: string[];
  priority: number;
  fleet?: boolean;
  options?: SLOptionSpec[];
}

export interface SLSegmentConfig {
  id: string;
  options?: Record<string, unknown>;
}

export interface SLConfig {
  version: number;
  preset?: string;
  separator?: string;
  flex?: string;
  color?: string;
  /** coexist mode: a kept pre-existing statusline command, rendered above
   *  the llmpilot line by the binary (set via `statusline install --keep`). */
  keep?: { command: string };
  segments: SLSegmentConfig[];
}

export interface SLPreset {
  id: string;
  name: string;
  desc: string;
  config: SLConfig;
}

export async function fetchStatuslineMeta(): Promise<{
  segments: SLSegmentSpec[];
  presets: SLPreset[];
}> {
  const res = await fetch("/v1/statusline/segments");
  if (!res.ok) throw new Error(`statusline segments: HTTP ${res.status}`);
  return res.json();
}

export async function fetchStatuslineConfig(): Promise<{
  config: SLConfig;
  load_error?: string;
}> {
  const res = await fetch("/v1/statusline/config");
  if (!res.ok) throw new Error(`statusline config: HTTP ${res.status}`);
  return res.json();
}

export async function saveStatuslineConfig(cfg: SLConfig): Promise<void> {
  const res = await fetch("/v1/statusline/config", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(cfg),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `statusline config: HTTP ${res.status}`);
  }
}

/** The live preview is rendered by the daemon's REAL Go renderer — the same
 *  bytes the binary prints (preview==production). */
export async function previewStatusline(
  cfg: SLConfig,
  width: number,
  tier: string,
): Promise<{ line: string; plain: string }> {
  const params = new URLSearchParams({
    config: JSON.stringify(cfg),
    width: String(width),
    tier,
  });
  const res = await fetch(`/v1/statusline/preview?${params}`);
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `preview: HTTP ${res.status}`);
  }
  return res.json();
}

export async function switchAccount(accountId: string): Promise<void> {
  const res = await fetch("/v1/switch", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ account_id: accountId }),
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => null)) as { error?: string } | null;
    throw new Error(body?.error ?? `switch: HTTP ${res.status}`);
  }
}

// --- licensing (internal/daemon/license.go mirrors) ----------------------

export interface TrialInfo {
  ends_at: string;
  charge_date?: string;
  days_left: number;
}

// License mirrors the daemon's GET /v1/license view. The signed entitlement
// token is never served here; the full id appears only when reveal is asked.
export interface License {
  available: boolean;
  active: boolean;
  status: string; // none | trialing | lifetime | lapsed | revoked | unavailable
  kind?: string; // trial | lifetime
  features?: string[];
  seats?: number;
  expires_at?: string;
  trial?: TrialInfo;
  last_validated?: string;
  license_id?: string; // only present under reveal
  license_id_masked?: string;
  nocard_trial_used: boolean;
  /** last terminal licensing refusal code; mapped to copy in pro/errors.ts. */
  error_code?: string;
}

export type Rung = "full" | "discount_trial" | "nocard_trial";

/** ApiError keeps the daemon's machine code beside the human message so the
 *  pro surfaces can render specific copy instead of generic failure prose. */
export class ApiError extends Error {
  code?: string;
  constructor(message: string, code?: string) {
    super(message);
    this.code = code;
  }
}

async function licenseError(res: Response, fallback: string): Promise<Error> {
  const body = (await res.json().catch(() => null)) as { error?: string; code?: string } | null;
  return new ApiError(body?.error ?? fallback, body?.code);
}

export async function fetchLicense(reveal = false): Promise<License> {
  const res = await fetch(`/v1/license${reveal ? "?reveal=1" : ""}`, {
    headers: reveal ? authHeaders() : {},
  });
  if (!res.ok) throw await licenseError(res, `license: HTTP ${res.status}`);
  return res.json();
}

// Quote mirrors the worker's GET /v1/quote (proxied by the daemon): the
// authoritative pre-checkout terms. The paywall renders ONLY these values —
// prices are currency → minor units from the live Stripe Price.
export interface Quote {
  trial_days: number;
  charge_date: string;
  prices: {
    full: Record<string, number>;
    discount: Record<string, number>;
  };
}

/** QuoteEcho is the consent statement the buyer saw, echoed into checkout so
 *  the worker can refuse terms that drifted (409, code quote_stale). */
export interface QuoteEcho {
  trial_days?: number;
  currency?: string;
  amount_minor?: number;
}

export async function fetchQuote(): Promise<Quote> {
  const res = await fetch("/v1/license/quote");
  if (!res.ok) throw await licenseError(res, `quote: HTTP ${res.status}`);
  const q = (await res.json()) as Quote;
  // A quote that cannot state a price or a parseable charge date must never
  // render a paywall — "Invalid Date" is not consent copy.
  if (
    !Number.isInteger(q.trial_days) ||
    Number.isNaN(Date.parse(q.charge_date ?? "")) ||
    !Object.keys(q.prices?.full ?? {}).length ||
    !Object.keys(q.prices?.discount ?? {}).length
  ) {
    throw new ApiError("quote: malformed terms");
  }
  return q;
}

// startCheckout returns the URL to open. The native cockpit window intercepts
// the off-daemon navigation and hands it to the clean checkout window; a plain
// browser just follows it. Activation completes silently in the daemon poller.
// The echo carries the exact terms the buyer consented to; remindDaysBefore is
// the reminder-timing choice (1 or 2 days before the charge) the sweep honors.
export async function startCheckout(
  rung: Rung,
  quote: QuoteEcho,
  remindDaysBefore: number,
): Promise<{ url: string; session_id: string }> {
  const res = await fetch("/v1/license/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ rung, quote, remind_days_before: remindDaysBefore }),
  });
  if (!res.ok) throw await licenseError(res, "Checkout could not start — try again.");
  return res.json();
}

export async function cancelTrial(): Promise<void> {
  const res = await fetch("/v1/license/cancel", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: "{}",
  });
  if (!res.ok) throw await licenseError(res, "Cancel could not complete — try again.");
}

export async function recoverLicense(email: string): Promise<void> {
  const res = await fetch("/v1/license/recover", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ email }),
  });
  if (!res.ok) throw await licenseError(res, "Could not send the recovery email — try again.");
}

// claimRecovery redeems the one-shot code from the recovery email. A loopback
// page cannot reach the daemon, so the code is pasted into the app by hand.
export async function claimRecovery(token: string): Promise<void> {
  const res = await fetch("/v1/license/recover/claim", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ token }),
  });
  if (!res.ok) throw await licenseError(res, "This recovery code is invalid or expired.");
}
