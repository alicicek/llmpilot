import { spawnSync } from "node:child_process";

export const stripeProfile = "llmpilot";
export const approvedStripeAccount = "acct_1TsAkS4I1JUJg08r";

/** Stripe CLI argv for a profile-scoped call. `--live` selects the live key
 *  FROM THE PROFILE — but a STRIPE_API_KEY env var or --api-key flag would
 *  override both the profile and the mode (CLI resolves env first). That is
 *  why assertApprovedStripeIdentity verifies the OBSERVED mode instead of
 *  trusting this argv: the guard runs through the identical environment, so
 *  an env-key override is caught as a mode/account mismatch. */
export function stripeArgs(args, live = false) {
  return ["-p", stripeProfile, ...args, ...(live ? ["--live"] : [])];
}

function defaultExec(args) {
  return spawnSync("stripe", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
}

function getJSON(path, live, exec) {
  const result = exec(stripeArgs(["get", path], live));
  if (result.error) throw new Error(`stripe CLI failed to run: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`stripe get ${path} exited ${result.status}`);
  }
  try {
    return JSON.parse(result.stdout);
  } catch {
    throw new Error(`Stripe response for ${path} was not JSON`);
  }
}

/** Refuse (throw) unless the CLI resolves to the approved account AND is in
 *  the key mode the caller asked for. Returns the verified mode so callers
 *  report it instead of asserting it.
 *
 *  The mode check deliberately does NOT come from /v1/account. That object
 *  carries no `livemode` field at all (verified against the live API
 *  2026-07-29), so a `parsed.livemode === true` test is always false — and
 *  the account id is IDENTICAL in live and test, so on its own it can never
 *  tell the two apart. /v1/balance does report livemode, in both modes, so
 *  the mode is read from an object that actually states it.
 *
 *  `exec` is injectable for tests only; production callers omit it. */
export function assertApprovedStripeIdentity({ live = false, exec = defaultExec } = {}) {
  const account = getJSON("/v1/account", live, exec);
  if (account.id !== approvedStripeAccount) {
    throw new Error(
      `Stripe profile resolved to ${account.id}, not the approved account`,
    );
  }
  const balance = getJSON("/v1/balance", live, exec);
  if (typeof balance.livemode !== "boolean") {
    throw new Error("Stripe balance response carried no livemode flag");
  }
  if (balance.livemode !== live) {
    throw new Error(
      `Stripe CLI is in ${balance.livemode ? "LIVE" : "test"} mode but ` +
        `${live ? "live" : "test"} was requested`,
    );
  }
  return { account: account.id, livemode: balance.livemode };
}
