import type { License, Quote } from "../api.ts";

// ?pro=<state> injects a fixture License so onboarding, the paywall ladder, and
// the License settings render deterministically without a daemon — the same
// philosophy as the ?fixtures= board harness (network-idle, screenshot-stable).
// Combine with ?fixtures=1 for a fleet behind the paywall.
export const proFixtureParam = new URLSearchParams(window.location.search).get("pro");

const TRIAL_ENDS = "2026-07-20T09:00:00Z";

// fixtureLicense maps a ?pro= value to a License. null means no fixture (the
// app fetches the real daemon view).
export function fixtureLicense(param: string | null): License | null {
  switch (param) {
    case "paywall":
      return { available: true, active: false, status: "none", nocard_trial_used: false };
    case "trial":
      return fixtureActivatedLicense();
    case "paused":
      return {
        available: true, active: false, status: "lapsed",
        license_id_masked: "lic_••••4f2a", nocard_trial_used: true,
      };
    case "lifetime":
      return {
        available: true, active: true, status: "lifetime", kind: "lifetime",
        features: ["autopilot", "scheduling", "wake"], seats: 1,
        last_validated: "2026-07-12T12:00:00Z", license_id_masked: "lic_••••9c3d",
        nocard_trial_used: false,
      };
    case "seatlimit":
      // The activation poller's terminal refusal: paywall + Settings render
      // the seat-limit copy with the recover-by-email path.
      return {
        available: true, active: false, status: "none",
        nocard_trial_used: false, error_code: "seat_limit_reached",
      };
    case "source":
      return { available: false, active: false, status: "unavailable", nocard_trial_used: false };
    default:
      return null;
  }
}

// fixtureQuote mirrors the worker quote the paywall would fetch: the shipped
// terms (4-day trial, £9.99/$12.99 full, £5.99/$7.99 decline offer) so the
// consent copy renders deterministically without a daemon.
export function fixtureQuote(): Quote {
  return {
    trial_days: 4,
    charge_date: TRIAL_ENDS,
    prices: {
      full: { gbp: 999, usd: 1299 },
      discount: { gbp: 599, usd: 799 },
    },
  };
}

// fixtureActivatedLicense is the trialing grant the activation poller would
// produce — used to simulate the silent SSE flip after a fixture checkout.
export function fixtureActivatedLicense(): License {
  return {
    available: true, active: true, status: "trialing", kind: "trial",
    features: ["autopilot", "scheduling", "wake"], seats: 1,
    trial: { ends_at: TRIAL_ENDS, charge_date: TRIAL_ENDS, days_left: 3 },
    expires_at: "2026-07-23T09:00:00Z", last_validated: "2026-07-12T12:00:00Z",
    license_id_masked: "lic_••••4f2a", nocard_trial_used: false,
  };
}
