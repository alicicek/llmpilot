# Entitlement Worker operations

This service accepts Stripe test events, issues short-lived trial entitlements,
and issues lifetime entitlements only after a paid subscription-cycle invoice.
Production deployment requires an explicit environment and secret push.

## Local setup

1. Run `npm ci`.
2. Generate `.dev.vars` with `op inject -f -i .dev.vars.template -o .dev.vars`.
3. Apply local migrations with `npm run migrate:local`.
4. Start `npm run dev` and the Stripe listener shown by `node scripts/e2e.mjs`.

The Worker refuses keys with a live prefix whenever `ENVIRONMENT` is not
`production`, and refuses test-prefixed keys when `ENVIRONMENT` is
`production` (a test key there would let test-mode payments mint real
entitlements). Never weaken either direction for local testing — a deployed
worker that should run on test keys needs a non-production `ENVIRONMENT`.

## Signing-key lifecycle

`node scripts/key-lifecycle.mjs` is a dry run. With `--generate`, it creates an
Ed25519 keypair in a private temporary directory without printing key material.
Move the PKCS8 value and key id into concealed fields on the `entitlement` vault
item, then securely delete the temporary directory.

Rotation order is mandatory: ship an app release containing the new public key
and key id; switch the Worker signing key; retain every prior public key so old
entitlements continue to verify. A compromised key requires revocation, a new
app key set, and re-issuance through the recovery flow.

## Deployment

Run `npm run check`, `npm test`, `npm run types`, and
`npx wrangler deploy --dry-run`. Apply D1 migrations before
traffic. `node scripts/secrets-push.mjs` only describes its changes;
`--apply` reads concealed fields without printing them and uses secret bulk.
The `llmpilot` vault must contain the approved Cloudflare account id; the
script binds both that id and the `llmpilot` Wrangler profile before sending
any secret.

The native `EMAIL` binding must be enabled for `llmpilot.dev`; sender access is
restricted to `support@llmpilot.dev`. The hourly cron checks reminders. The daily
cron repairs active or trialing subscriptions missing `cancel_at` and emits a
structured alarm count for anything it cannot repair.

`TRIAL_DAYS` defaults to 8, so Stripe supplies the pre-charge reminder and the
custom hourly reminder is dormant. Change it to 3 only after a test delivery from
the native email binding is proven; that configuration activates the custom sweep.

Stripe SDK and webhook endpoints must stay on `2026-06-24.dahlia`. The
Prices are yearly recurring Prices with GBP base amounts and pinned USD currency
options. Catalog and end-to-end scripts default to dry-run and every Stripe CLI
command uses the `llmpilot` profile.

## Launch-price window

For the 14-day launch sale the full rung sells at `PRICE_LAUNCH`
(£5.99/$7.99) until `LAUNCH_ENDS_AT`, then reverts to `PRICE_FULL` — resolved
per request from the clock, so closing needs no deploy and no cron. Opening
the window on launch day:

1. `node scripts/catalog.mjs --only=launch --apply` (once per key mode) and
   put the printed Price id in `wrangler secret put PRICE_LAUNCH`.
2. `wrangler secret put LAUNCH_ENDS_AT` with the RFC 3339 end instant,
   exactly 14 days after the posts go out (honest urgency: the stated end
   date is the real one).

`GET /v1/quote` then serves the launch amounts as `prices.full` plus
`launch: { ends_at, regular_full }`; the site banner and the app paywall both
render from it, and a checkout echo priced on the wrong side of the boundary
refuses with `quote_stale`.
