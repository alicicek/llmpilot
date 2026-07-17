import { spawnSync } from "node:child_process";

export const stripeProfile = "llmpilot";
export const approvedStripeAccount = "acct_1TsAkS4I1JUJg08r";

export function assertApprovedStripeIdentity() {
  const identity = spawnSync(
    "stripe",
    ["-p", stripeProfile, "get", "/v1/account"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  );
  if (identity.status !== 0) process.exit(identity.status ?? 1);
  let parsed;
  try {
    parsed = JSON.parse(identity.stdout);
  } catch {
    throw new Error("Stripe account response was not JSON");
  }
  if (parsed.id !== approvedStripeAccount || parsed.livemode === true) {
    throw new Error("Stripe profile is not the approved test-mode account");
  }
}
