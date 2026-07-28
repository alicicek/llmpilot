# llmpilot.dev — landing site

Static marketing page for llmpilot. Astro (islands architecture) with the
cockpit's design tokens; the interactive statusline, install tabs, copy chip,
and demo overlay are client-hydrated React islands with Motion.

## Stack (verified latest stable, as-of 2026-07-12)

- **Astro 7.0.7** — static output (`output: "static"`), no SSR adapter. Deploys
  to **Cloudflare Workers (Static Assets)** — Cloudflare's and Astro's
  recommended path for new sites (`wrangler.jsonc` → `assets.directory: ./dist`).
- **Tailwind 4.3.2** via `@tailwindcss/vite` — utilities bound to the design
  tokens in `src/styles/global.css` (`@theme inline`). Matches `web/`'s Tailwind.
- **React 19.2.7 + @astrojs/react 6.0.1** — islands only (`client:visible`).
- **shadcn/ui convention** — `radix-ui` primitives + `cn()` (`src/lib/utils.ts`),
  themed to llmpilot tokens (not shadcn defaults). Used for Button + install Tabs.
- **Motion 12.42.2** — the statusline `Reorder` (drag) + demo overlay fade.
- **@astrojs/sitemap** — `sitemap-index.xml` at build.

Design tokens are the cockpit's `-dark` twins verbatim (`src/styles/tokens.css`),
— one source of truth, no drift with the app.

## Develop

```sh
pnpm install
pnpm dev        # http://localhost:4321 with HMR
pnpm build      # → dist/  (static)
pnpm preview    # serve the built dist/
```

Type-check note: `pnpm check` currently fails on a `@astrojs/language-server`
+ TypeScript 7 incompatibility (a tooling bug, not a code error) — `astro build`
generates types fine, and `tsc` on the islands passes clean.

## Deploy (Cloudflare Workers — Static Assets)

Live at **https://llmpilot.dev** (and `www`), served by the `llmpilot-site`
Worker (assets-only, `dist/`). The separate `llmpilot-api` Worker serves the
money API — this page does not touch it. Deploy from THIS machine (not hosted
CI, per the local-first release rule):

```sh
pnpm build
wrangler deploy          # reads wrangler.jsonc → uploads dist/ as static assets
```

The custom domains `llmpilot.dev` + `www.llmpilot.dev` are already bound to the
`llmpilot-site` Worker; `wrangler deploy` publishes a new version to them
immediately. Preview any version at `llmpilot-site.<subdomain>.workers.dev`.
(Migrated from Cloudflare Pages → Workers Static Assets on 2026-07-12, matching
Cloudflare's and Astro's current recommendation for new static sites.)

## Content laws (bind every edit)

- REAL numbers only — every digit traces to a masked fixture screenshot or a
  verifiable fact. No invented stats, counts, testimonials, or prices.
- Product imagery only from `public/assets/product/` (masked demo accounts).
  The full cockpit-history PNG was deliberately removed — its Projects card
  named a real sibling repo. Only the cropped burn-rate card ships.
- Voice: dispatcher register; sentence case; no "!";
  "switched" not "rotated"; banned-word list). Color is meaning, one gradient
  budget (zero CSS gradients here), one typeface, tabular numerals, rotation 0°.
- The hero demo slot stays an honest empty frame until the real recording
  exists (HyperFrames later). Never a screenshot posing as video.

## Still TODO before launch (W9/W10)

- `install.sh` at the site root (curl tab references it — marked "at launch").
- npm publish (npm tab — marked "at launch").
- Wire the Pro CTA to the `llmpilot-api` checkout when monetization goes live.
- Re-shoot product screenshots at retina if desired (current are 1×).
