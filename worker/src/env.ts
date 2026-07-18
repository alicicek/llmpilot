// worker-configuration.d.ts is generated from wrangler.jsonc. Keep this alias
// so domain modules can import one name without hand-maintaining bindings.
export type WorkerEnv = Omit<Env, "ENVIRONMENT" | "TRIAL_DAYS" | "SEAT_LIMIT"> & {
  ENVIRONMENT: string;
  TRIAL_DAYS: string;
  SEAT_LIMIT: string;
  STRIPE_SECRET_KEY: string;
  STRIPE_WEBHOOK_SECRET: string;
  STRIPE_PUBLISHABLE_KEY: string;
  ENT_SIGNING_KEY: string;
  ENT_SIGNING_KEY_ID: string;
  PRICE_FULL: string;
  PRICE_DISCOUNT: string;
  // Launch-price window (both set ⇒ the full rung sells at PRICE_LAUNCH
  // until LAUNCH_ENDS_AT). Optional: absent means no window.
  PRICE_LAUNCH?: string;
  LAUNCH_ENDS_AT?: string;
};
