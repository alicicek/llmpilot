# llmpilot

**your Claude accounts, on autopilot** — a multi-account companion for Claude Code on macOS.

```sh
brew install alicicek/tap/llmpilot        # the CLI + daemon
brew install --cask alicicek/tap/llmpilot # the menu bar app
```

[![CI](https://github.com/alicicek/llmpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/alicicek/llmpilot/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/alicicek/llmpilot/badge)](https://scorecard.dev/viewer/?uri=github.com/alicicek/llmpilot)
[![release](https://img.shields.io/github/v/tag/alicicek/llmpilot?label=release&sort=semver)](https://github.com/alicicek/llmpilot/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg)

> **Signed & notarized by Apple** (Developer ID, Team `6UUS5FCSJ3`) — installs
> with no Gatekeeper warning. **Zero telemetry. Your account tokens never leave
> your Mac** — the cache holds only usage percentages and reset timestamps, and
> account traffic goes only to Anthropic. Beyond that the app reaches the network
> only for Sparkle updates (GitHub) and, on Pro, the licensing worker and
> Stripe's hosted checkout. Open source, MIT.

One daemon watches every account's real usage, switches to the account with
headroom before you hit a wall, and starts your 5-hour windows on schedule.
Five thin surfaces over one brain: a native menu bar app, a native cockpit
window, a statusline, a CLI, and the autopilot itself.

Built for people who run more than one Claude Max plan and are tired of the
`/login` dance, guessing which account has room left, and waking up to windows
that never opened.

Core is free forever, MIT-licensed. The autopilot is [Pro](#free-and-pro) —
a one-time £9.99 / $12.99, not a subscription.

![the cockpit — every account's runway and today's planned windows on one board](docs/media/cockpit.png)

## What it does

- **See every account at a glance.** Live usage for all your accounts — 5-hour,
  weekly, and per-model buckets — read straight from Anthropic's usage endpoint
  with an honest "as of" timestamp. When a login goes stale, the dashboard
  shows the last-known numbers marked stale, never old numbers in live colors.
- **Switch before the wall.** When the account you're on runs low, llmpilot
  switches you to one with headroom and tells you after — switch first, notify
  second. Credential writes are lock-first and backed up, so a switch never
  corrupts a login.
- **Start windows on time.** Schedule a fresh 5-hour window to open at a set
  time on a chosen account, so your overnight or early-morning capacity isn't
  wasted. It only *starts* a window; it never advances one you're already in.
- **Bring every sign-in into the fleet.** `llmpilot init` registers the
  accounts already signed in on your Mac. A sign-in living in its own folder
  (`CLAUDE_CONFIG_DIR`) can be adopted as a watched account, or moved into the
  fleet — backed up first, then made switchable — from the cockpit or the menu
  bar. You can also sign in to a new account from inside the app, on
  Anthropic's own page.
- **Diagnose it honestly.** `llmpilot doctor` checks the fleet — duplicate
  sign-ins, frozen logins, the refresh budget, unproven migrations, the
  install — and names what is wrong, what it could not check, and the one
  thing that fixes each finding. It only looks; it never writes.
- **Keep a CI token.** `llmpilot token add/list/copy/remove` stores long-lived
  headless tokens (the `claude setup-token` kind) in your Keychain. The only
  way a token leaves it is an explicit `token copy` to the clipboard.
- **Read it anywhere.** The same live state renders in the menu bar, the
  native cockpit window, a Claude Code statusline, and `llmpilot status`. On a
  CLI-only install with no app, `llmpilot open` puts the same cockpit in your
  browser instead.

![drag a reset time — llmpilot computes the start and refuses times that physically can't happen](docs/media/scheduler.gif)

## How it works

llmpilot is one Go binary. The **daemon** polls each account's usage — every
3 minutes in steady state, never more than 28 requests per account per rolling
hour, backing off on rate limits — caches percentages and reset times locally,
and drives the autopilot. The menu bar, cockpit, and CLI read that one daemon
over a loopback socket; the statusline reads the snapshots the daemon writes —
asking the daemon for burn-rate history when it's up — inside its 50 ms render
budget. Nothing is duplicated, nothing disagrees.

llmpilot never runs a background token-refresh loop. It refreshes a login only
when something needs it: about 10 minutes before a switch (yours or the
autopilot's), when the autopilot revives a stale account, or when you sign in
from the app. Refreshes
are capped at 2 attempts per account per rolling 24 hours, and one rate-limit
answer from the token endpoint pauses all refreshes for 24 hours. A login that
goes stale anyway is shown stale — last-known numbers, marked — until a
switch, a revive, or a re-login proves it live again.

Credentials are Claude Code's own. llmpilot reads and writes the macOS Keychain
item Claude Code already uses, under Claude Code's own lock files, so it
cooperates with a running `claude` session instead of racing it.

The first Keychain read from a freshly built binary triggers one macOS prompt —
click **Always Allow** to grant that binary persistent access. Homebrew installs
a stable binary path, so the grant sticks; if you build from source, use
`make build` rather than `go run` for the same reason.

## Free and Pro

Core is **free forever**, MIT-licensed, and does the whole read side: live usage
for every account, manual switching, the cockpit, the statusline, and analytics.

**Pro** adds the autopilot — automatic switching before the wall, window
scheduling, and waking the Mac for scheduled starts. It is a one-time purchase
(£9.99 / $12.99), not a subscription.

Official signed builds include Pro; builds you compile from source are the free
app. The split is stated here on day one so nothing gets pulled out from under
you later.

## Privacy and security

- **Your tokens never leave your machine.** llmpilot talks only to Anthropic's
  own endpoints (the same ones Claude Code uses) and, for Pro, a licensing
  worker that never sees a Claude token.
- **No telemetry, ever.** Cache files hold usage percentages and reset
  timestamps only — never tokens.
- **Updates:** the menu bar app checks a GitHub-hosted appcast via Sparkle
  (GET only) and downloads updates from GitHub releases. The CLI never checks
  for updates — Homebrew updates it.

See [SECURITY.md](SECURITY.md) for the full model and how to report a
vulnerability.

## A note on Anthropic's terms

llmpilot uses the OAuth credential Claude Code stores on your Mac. Anthropic's
policy (as of February 2026) limits that credential to *"ordinary use of Claude
Code and native Anthropic applications."* The ban on using it *"on behalf of
their users"* is aimed at hosted SaaS proxies; a local, personal tool like this
is not addressed either way. Running several Max plans and switching between them
is not explicitly prohibited, but it lives in a gray zone, and some multi-account
users have reported automated account actions. llmpilot never sends your
credentials anywhere — but you should decide, informed, whether this fits your
use. The [FAQ](docs/FAQ.md) has the full picture.

## Develop

```sh
make build   # go build -o ./llmpilot ./cmd/llmpilot
make test    # go test ./...
make lint    # golangci-lint run
make check   # all of the above
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the open-core layout and conventions.

## Documentation

- [FAQ](docs/FAQ.md) — install, the Anthropic terms, wake limitations, the
  undocumented usage endpoint, and what happens if a plan changes.
- [SECURITY.md](SECURITY.md) — security model and disclosure.
- [CONTRIBUTING.md](CONTRIBUTING.md) — build, test, and how the open-core split
  is laid out.

## License

MIT — see [LICENSE](LICENSE). The source in this repository is yours under MIT;
the "llmpilot" name and the official signed builds are the maintainer's.
