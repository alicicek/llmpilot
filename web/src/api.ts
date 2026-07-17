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
}

export interface State {
  accounts: AccountState[];
  active_id: string;
  events: DaemonEvent[];
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
// The echo carries the exact terms the buyer consented to.
export async function startCheckout(rung: Rung, quote: QuoteEcho): Promise<{ url: string; session_id: string }> {
  const res = await fetch("/v1/license/checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ rung, quote }),
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
