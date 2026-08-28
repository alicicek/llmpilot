// The app-facing endpoints. Auth model: a license id is a 128-bit random
// bearer capability; a session id proves checkout possession. /v1/recover
// answers identically whether or not the email exists — the email DB is
// never enumerable from outside.

import type Stripe from "stripe";
import type { WorkerEnv } from "../env.ts";
import { getStripe } from "../lib/stripe.ts";
import { lapseTrial, licenseBy, licensesByEmail, mintFor, type LicenseRow } from "../lib/licenses.ts";
import { recordSeat, seatExists, seatLimit, seatUnderCap, trimSeatsToCap, validInstallID } from "../lib/seats.ts";
import { fulfillSession } from "./webhook.ts";
import { sendEmail } from "../lib/email.ts";
import { sha256, takeRateLimit } from "../lib/rate-limit.ts";

function tokenBearing(lic: LicenseRow): boolean {
  return lic.status === "lifetime" || lic.status === "trialing";
}

function licenseView(lic: LicenseRow, entitlement?: string): Record<string, unknown> {
  return {
    license: lic.id,
    status: lic.status,
    ...(lic.trial_end ? { trial_end: lic.trial_end } : {}),
    // Revoked and lapsed rows serve no token: the app treats a missing
    // entitlement as "features off" with honest copy. The explicit argument
    // carries a token freshly minted for the CALLING install; the stored
    // column is only the checkout Mac's mint-time token.
    ...((entitlement ?? lic.entitlement) && tokenBearing(lic)
      ? { entitlement: entitlement ?? lic.entitlement }
      : {}),
  };
}

/** POST /v1/activate {session_id, install_id?} — the silent-activation
 *  confirm: runs the same idempotent fulfillment as the webhook (whoever is
 *  first wins). The daemon sends its install id; the worker-served checkout
 *  host page omits it and falls back to the checkout-time binding. A
 *  DIFFERENT install replaying a known session id may seat itself only under
 *  the cap — the (cap+1)th device is refused toward email recovery. */
export async function activateRoute(
  env: WorkerEnv,
  body: { session_id?: string; install_id?: string },
  stripeClient?: Stripe,
): Promise<Response> {
  const stripe = stripeClient ?? getStripe(env);
  if (!stripe) return Response.json({ error: "billing_not_configured" }, { status: 500 });
  const sessionId = (body.session_id ?? "").trim();
  if (!sessionId.startsWith("cs_")) return Response.json({ error: "invalid_input" }, { status: 400 });
  if (body.install_id !== undefined && !validInstallID(body.install_id)) {
    return Response.json({ error: "invalid_input" }, { status: 400 });
  }
  try {
    const { lic, state, sessionStatus } = await fulfillSession(env, stripe, sessionId);
    if (!lic) return Response.json({ error: "unknown_session" }, { status: 404 });
    if (state === "trial_email_used") return Response.json({ error: "trial_email_used" }, { status: 409 });
    // declined rides the pending answer: the daemon's activation poll arms
    // the win-back on it and keeps polling (a history-back payment can still
    // land and supersedes the back-out). session_expired ends that polling —
    // an expired session can never pay.
    if (state === "not_paid") {
      return Response.json({
        pending: true,
        status: lic.status,
        ...(lic.declined_at ? { declined: true } : {}),
        ...(sessionStatus === "expired" ? { session_expired: true } : {}),
      });
    }
    const install = body.install_id ?? lic.install_id;
    if (!tokenBearing(lic) || !install || install === lic.install_id) {
      return Response.json(licenseView(lic));
    }
    const now = new Date();
    if (!(await seatUnderCap(env.ENT_DB, lic.id, install, seatLimit(env), now))) {
      return Response.json({ error: "seat_limit_reached" }, { status: 409 });
    }
    return Response.json(licenseView(lic, await mintFor(env, lic, install, now)));
  } catch {
    return Response.json({ error: "activate_failed" }, { status: 502 });
  }
}

/** POST /v1/validate {license, install_id} — current status + a freshly
 *  signed token for the calling seat. The app verifies offline day-to-day
 *  and re-validates weekly; the re-sign advances the signed issued_at that
 *  anchors the offline-grace window, and a revocation lands here. A caller
 *  whose install holds no seat gets a refusal, never a silent seat — the
 *  sanctioned path onto a new Mac is email recovery. */
export async function validateRoute(
  env: WorkerEnv,
  body: { license?: string; install_id?: string },
): Promise<Response> {
  const id = (body.license ?? "").trim();
  if (!id.startsWith("lic_") || !validInstallID(body.install_id)) {
    return Response.json({ error: "invalid_input" }, { status: 400 });
  }
  const lic = await licenseBy(env.ENT_DB, "id", id);
  if (!lic) return Response.json({ error: "unknown_license" }, { status: 404 });
  if (!tokenBearing(lic)) return Response.json(licenseView(lic));
  if (!(await seatExists(env.ENT_DB, lic.id, body.install_id))) {
    return Response.json({ error: "install_not_activated" }, { status: 403 });
  }
  const now = new Date();
  await recordSeat(env.ENT_DB, lic.id, body.install_id, now);
  return Response.json(licenseView(lic, await mintFor(env, lic, body.install_id, now)));
}

/** POST /v1/cancel {license} — the one-click trial cancel (Settings →
 *  License). Cancels the subscription immediately: no charge, clean lapse
 *  (the subscription.deleted webhook records it). */
export async function cancelRoute(
  env: WorkerEnv,
  body: { license?: string },
  stripeClient?: Stripe,
): Promise<Response> {
  const stripe = stripeClient ?? getStripe(env);
  if (!stripe) return Response.json({ error: "billing_not_configured" }, { status: 500 });
  const id = (body.license ?? "").trim();
  if (!id.startsWith("lic_")) return Response.json({ error: "invalid_input" }, { status: 400 });
  const lic = await licenseBy(env.ENT_DB, "id", id);
  if (!lic) return Response.json({ error: "unknown_license" }, { status: 404 });
  if (lic.status !== "trialing" || !lic.subscription_id) {
    return Response.json({ error: "not_cancellable", status: lic.status }, { status: 409 });
  }
  try {
    await stripe.subscriptions.cancel(lic.subscription_id);
  } catch {
    return Response.json({ error: "cancel_failed" }, { status: 502 });
  }
  // Lapse the row now rather than waiting for subscription.deleted: until
  // that webhook lands, /v1/validate would keep re-serving the trial token
  // for a subscription the buyer just cancelled. The webhook's lapseTrial
  // is a no-op on an already-lapsed row.
  await lapseTrial(env.ENT_DB, lic.id);
  return Response.json({ ok: true, status: "lapsed" });
}

/** POST /v1/recover {email} — receipt email is the recovery path. Constant
 *  response shape regardless of matches. */
const RECOVERY_WINDOW_MS = 60 * 60 * 1000;
const RECOVERY_LIMIT = 5;

function randomToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function recoverRoute(
  env: WorkerEnv,
  body: { email?: string },
  request?: Request,
  defer?: (task: Promise<unknown>) => void,
): Promise<Response> {
	const started = performance.now();
  const email = (body.email ?? "").trim().toLowerCase();
  const valid = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) && email.length <= 254;
  const normalized = valid ? email : "invalid@example.invalid";
  const ip = request?.headers.get("cf-connecting-ip") ?? "unknown";
  const now = new Date();
  const [emailAllowed, ipAllowed] = await Promise.all([
    takeRateLimit(env.ENT_DB, "recovery-email", normalized, now, RECOVERY_LIMIT, RECOVERY_WINDOW_MS),
    takeRateLimit(env.ENT_DB, "recovery-ip", ip, now, RECOVERY_LIMIT, RECOVERY_WINDOW_MS),
  ]);
  const rows = valid ? await licensesByEmail(env.ENT_DB, email) : [];
  const usable = rows.filter((r) => r.status === "lifetime" || r.status === "trialing");
  if (valid && emailAllowed && ipAllowed && usable[0]) {
    const token = randomToken();
    const [tokenHash, emailHash] = await Promise.all([sha256(token), sha256(`email:${email}`)]);
    const expires = new Date(now.getTime() + 15 * 60 * 1000).toISOString();
    await env.ENT_DB.prepare(
      "INSERT INTO recovery_requests (token_hash, email_hash, license_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
    ).bind(tokenHash, emailHash, usable[0].id, expires, now.toISOString()).run();
    const link = `${env.PUBLIC_ORIGIN}/recover?token=${encodeURIComponent(token)}`;
    const task = sendEmail(env, email, "Restore llmpilot Pro", [
      "Use this secure link to restore llmpilot Pro:",
      link,
      "",
      "This link expires in 15 minutes and can be used once.",
    ].join("\n"), "recovery");
    if (defer) defer(task); else await task;
  }
	// A fixed response floor hides the small D1 and email-dispatch difference
	// between a known address, an unknown address, and a limited request.
	const remaining = 200 - (performance.now() - started);
	if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining));
  // Deliberately identical for invalid, limited, known, and unknown requests.
  return Response.json({ ok: true }, { status: 202 });
}

/** POST /v1/recover/claim {token, install_id} — redeem the magic link ON the
 *  new Mac (the daemon claims; a browser can't hold a seat). Proof of email
 *  ownership always seats the claimer: at the cap it evicts the seat with
 *  the oldest last_seen, which is remote "deactivate a Mac" semantics. */
export async function claimRecoveryRoute(
  env: WorkerEnv,
  body: { token?: string; install_id?: string },
): Promise<Response> {
  if (!validInstallID(body.install_id)) return Response.json({ error: "invalid_input" }, { status: 400 });
  const token = (body.token ?? "").trim();
  const tokenHash = await sha256(token || "invalid");
  const now = new Date().toISOString();
  const row = await env.ENT_DB.prepare(
    `UPDATE recovery_requests SET claimed_at = ?
     WHERE token_hash = ? AND claimed_at IS NULL AND expires_at > ?
     RETURNING license_id`,
  ).bind(now, tokenHash, now).first<{ license_id: string | null }>();
  if (!row?.license_id) return Response.json({ error: "invalid_or_expired" }, { status: 400 });
  const lic = await licenseBy(env.ENT_DB, "id", row.license_id);
  if (!lic) return Response.json({ error: "invalid_or_expired" }, { status: 400 });
  if (!tokenBearing(lic)) return Response.json(licenseView(lic));
  const db = env.ENT_DB;
  const install = body.install_id;
  // Always seat the claimer (freshest last_seen), then trim to the newest
  // `limit` seats. Two atomic statements that converge, instead of a
  // check-count-evict-insert sequence that concurrent claims could race into
  // over-eviction or cap+1.
  const minted = new Date();
  await recordSeat(db, lic.id, install, minted);
  await trimSeatsToCap(db, lic.id, seatLimit(env));
  return Response.json(licenseView(lic, await mintFor(env, lic, install, minted)));
}
