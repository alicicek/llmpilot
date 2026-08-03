import type { WorkerEnv } from "../env.ts";

// Resend delivers the worker's transactional email (owner pick 2026-08-01:
// deliverability track record and per-message delivery logs on the
// pre-charge reminder; the prior Cloudflare binding was never onboarded and
// failed silently). This file is the ONE place buyer email addresses leave
// the worker — SECURITY.md discloses it.
const RESEND_ENDPOINT = "https://api.resend.com/emails";

/** "sent" = accepted now · "duplicate" = a request with this idempotency
 *  key was already accepted (or is in flight) so the email EXISTS — callers
 *  must treat it as delivered, never retry into a 409 loop · "failed" =
 *  retry later. */
export type SendOutcome = "sent" | "duplicate" | "failed";

export async function sendEmail(
  env: WorkerEnv,
  to: string,
  subject: string,
  text: string,
  template: "recovery" | "trial_reminder",
  // Resend dedupes on this for 24h — the sweep passes one per license so a
  // false-negative send result can never double-remind.
  idempotencyKey?: string,
): Promise<SendOutcome> {
  if (!env.RESEND_API_KEY) {
    console.error(JSON.stringify({ event: "email_failed", template, code: "not_configured" }));
    return "failed";
  }
  try {
    // EMAIL_HTTP is the test seam (the stripeOverride idiom) — production
    // never sets it and the real global fetch runs.
    const doFetch = env.EMAIL_HTTP ?? fetch;
    const res = await doFetch(RESEND_ENDPOINT, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
        ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
      },
      body: JSON.stringify({
        from: `llmpilot <${env.EMAIL_FROM}>`,
        to: [to],
        reply_to: "support@llmpilot.dev",
        subject,
        text,
        html: `<pre style="font:inherit;white-space:pre-wrap">${text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!)}</pre>`,
      }),
    });
    if (res.status === 409) {
      // Both Resend 409s (invalid_idempotent_request / concurrent_
      // idempotent_requests) prove a request with this key was accepted —
      // and our payload legitimately drifts between attempts (the subject
      // flips to "tomorrow" at the 24h boundary), so a retry can NEVER
      // clear a 409. Treating it as failure would loop hourly and never
      // stamp the reminder as sent.
      return "duplicate";
    }
    if (!res.ok) {
      // Status only — a provider error body can echo the recipient address.
      console.error(JSON.stringify({ event: "email_failed", template, code: `http_${res.status}` }));
      return "failed";
    }
    return "sent";
  } catch {
    console.error(JSON.stringify({ event: "email_failed", template, code: "network" }));
    return "failed";
  }
}
