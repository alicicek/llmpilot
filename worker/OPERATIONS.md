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

Deploy in this order — the migration step is NOT optional when a migration
is pending (a deploy whose code reads a column the remote DB lacks 502s
every checkout until the migration lands):

1. `npm run check`, `npm test`, `npm run types`, `npx wrangler deploy --dry-run`.
2. `npm run migrate:remote` — apply pending D1 migrations FIRST. New columns
   arrive with defaults, so old code + new schema is safe; new code + old
   schema is not.
3. `npx wrangler deploy`.
4. Verify: `curl https://api.llmpilot.dev/v1/quote` reflects the deployed vars.

`node scripts/secrets-push.mjs` only describes its changes;
`--apply` reads concealed fields without printing them and uses secret bulk.
The `llmpilot` vault must contain the approved Cloudflare account id; the
script binds both that id and the `llmpilot` Wrangler profile before sending
any secret.

Transactional email goes out through Resend (`RESEND_API_KEY` secret; sender
`support@llmpilot.dev` on a Resend-verified `llmpilot.dev`). Chosen 2026-08-01
over the native Cloudflare binding for its deliverability track record and
per-message delivery logs — the pre-charge reminder is a consumer-law email
and the delivery log is the dispute evidence. Resend's dashboard shows every
send; a `not_configured` email_failed log means the secret is missing. The
hourly cron checks reminders. The daily cron repairs active or trialing
subscriptions missing `cancel_at` and emits a structured alarm count for
anything it cannot repair.

`TRIAL_DAYS` is deployed as 4 (code default 8). Every rung leads with the
trial; the full rung converts to its one lifetime charge at trial end. Stripe
supplies its own pre-charge reminder only for trials of 7 days or more, so
any shorter value activates the custom hourly sweep — never deploy such a
value until a test delivery through Resend is proven. Buyers
choose the reminder offset at checkout (`remind_days_before`: 1 or 2 days
before the charge); the sweep honors it per license.

Stripe SDK and webhook endpoints must stay on `2026-06-24.dahlia`. Create the
endpoint with that version pinned explicitly — an unpinned endpoint follows the
account default, and the payload shapes this Worker parses are version-
sensitive.

## Stripe catalog

The catalog the Worker sells is TWO Prices — `PRICE_FULL` and `PRICE_DISCOUNT`
(every non-full rung resolves to the discount Price). Both are yearly recurring
with a GBP base amount and a pinned USD currency option, and **both currencies
must be tax-inclusive**: `tax_behavior` on the base does not propagate into
`currency_options`, and an unspecified option falls back to the account's tax
default (exclusive) — a buyer would be charged tax on top of the number they
consented to. A currency option's tax behavior is immutable once specified;
get it right at creation.

Create them per key mode:

```
node scripts/catalog.mjs --only=full     --apply [--live]
node scripts/catalog.mjs --only=discount --apply [--live]
```

**`--live` is what selects the key mode** — without it the Price is created in
TEST mode and its id would end up in a production secret. The script refuses a
CLI whose observed mode disagrees with the flag, verifies the created Price's
own `livemode`, and treats a Stripe error body as failure (the CLI exits 0 on
HTTP errors). A bare `--apply` (no `--only=`) mints all three rungs including
`launch` — never what a normal cutover wants.

## Launch-price window (optional lever — currently CLOSED by owner decision)

The window is opened only by a deliberate, separate decision — it is NOT a
launch-day step. While it stays closed, `PRICE_LAUNCH` and `LAUNCH_ENDS_AT`
remain unset; that absence IS the closed state (both-or-neither is enforced).

When (and only when) a window is decided: the full rung sells at `PRICE_LAUNCH`
(£5.99/$7.99) until `LAUNCH_ENDS_AT`, then reverts to `PRICE_FULL` — resolved
per request from the clock, so closing needs no deploy and no cron.

1. `node scripts/catalog.mjs --only=launch --apply [--live]` (per key mode,
   like the catalog above) and put the printed Price id in
   `wrangler secret put PRICE_LAUNCH`.
2. `wrangler secret put LAUNCH_ENDS_AT` with the RFC 3339 end instant,
   exactly 14 days after the posts go out (honest urgency: the stated end
   date is the real one).

`GET /v1/quote` then serves the launch amounts as `prices.full` plus
`launch: { ends_at, regular_full }`; the site banner and the app paywall both
render from it, and a checkout echo priced on the wrong side of the boundary
refuses with `quote_stale`.
