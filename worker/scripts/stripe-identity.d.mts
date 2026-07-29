export declare const stripeProfile: string;
export declare const approvedStripeAccount: string;

/** Stripe CLI argv for a profile-scoped call; `--live` selects the live key
 *  from the profile. NOTE: a STRIPE_API_KEY env var or --api-key flag
 *  overrides both — assertApprovedStripeIdentity exists to catch that. */
export declare function stripeArgs(args: string[], live?: boolean): string[];

export interface StripeIdentity {
  account: string;
  /** The mode the CLI was OBSERVED in, read from /v1/balance — not assumed. */
  livemode: boolean;
}

export interface ExecResult {
  status: number | null;
  stdout: string;
  error?: Error;
}

/** Throws unless the CLI resolves to the approved account in the requested
 *  key mode (a failed or non-JSON CLI invocation also throws — it never
 *  terminates the process). Returns the verified identity.
 *  `exec` is injectable for tests only. */
export declare function assertApprovedStripeIdentity(options?: {
  live?: boolean;
  exec?: (args: string[]) => ExecResult;
}): StripeIdentity;
