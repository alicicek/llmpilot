# Security

## The short version

- llmpilot runs entirely on your Mac.
- Your Claude tokens never leave the machine. There is no telemetry.
- The only requests llmpilot itself makes are to Anthropic's own endpoints
  (the same ones Claude Code uses), to the licensing worker for Pro (which
  never sees a Claude token), and — in the menu bar app only — a Sparkle
  update check against GitHub. Signing in from the app opens Anthropic's own
  sign-in page, in your browser or in an app window depending on where you
  start it; buying Pro opens Stripe's hosted checkout in your browser (an app window
  only if the browser cannot be opened).

## What llmpilot touches

- **The macOS Keychain** — llmpilot reads and writes the credential item Claude
  Code already stores. It does so under Claude Code's own lock files, so it
  cooperates with a running `claude` session rather than racing its token
  refresh. Credential writes are lock-first, backed up, and verified, so an
  interrupted switch cannot corrupt a login. llmpilot also keeps items of its
  own in your login keychain: per-account credential backups and kept foreign
  sign-ins under the `llmpilot-backups` service, and long-lived setup tokens
  (the `llmpilot token` verbs) under `llmpilot-setup-tokens`. None of these
  ever leave the machine; the only egress any verb offers is an explicit
  `token copy` to the clipboard.
- **`~/.claude.json` and per-account config dirs** — read for identity, written
  to switch the active account (atomic, tempfile + rename). "Move into the
  fleet", which asks first and names the folder, also removes the credential
  from the folder the sign-in moved out of.
- **`~/.claude/settings.json`** — written only when you install or uninstall
  the statusline (the app's Install statusline button, or `llmpilot
  statusline install` / `uninstall`). Only the `statusLine` value changes,
  but the file is rewritten as a whole: key order and indentation are
  normalized, and `&`, `<`, `>` inside strings are written as `&`-style
  escapes (same meaning to Claude Code). A statusline that is not llmpilot's
  is never replaced or wrapped until you choose Keep both or Replace it.
  Before llmpilot first adds its line, the original file is saved as
  `settings.json.orig`, and a replaced line is saved to
  `~/.llmpilot/statusline-replaced.json`.
- **Local cache under `$LLMPILOT_HOME`** (default `~/.llmpilot`) — usage
  percentages, reset timestamps, and schedules. **Never tokens.**
- **A loopback socket** — every surface reads the daemon over `127.0.0.1` / a
  unix socket: the menu bar, the cockpit (a native window in the app, or a
  browser page opened with `llmpilot open` on a CLI-only install), the
  statusline, and the CLI. Every API route requires an install-scoped
  `Authorization: Bearer` token — the same token either cockpit form, the
  statusline and the CLI present. That covers every change — switching the
  active account, adding an account or moving a sign-in into the fleet,
  adopting or discarding a kept sign-in, creating, moving or removing a
  schedule, saving settings, saving the statusline's line (which can name
  commands the statusline runs), installing the statusline into
  `~/.claude/settings.json`, signing in, and changing your license — and
  every read: account emails, usage, schedules, settings, detected Claude
  folders, project activity, the statusline's line and its commands, the
  doctor report, and your license. A web page or another user's process can
  neither change nor read any of it. A process running as you can: the
  token is a file only your user can read, under `~/.llmpilot`. Two things
  answer without the token: the cockpit's static page, which holds no data
  until it presents the token, and the sign-in callback a browser sign-in
  opens for ten minutes, which accepts only the request carrying that
  sign-in's one-time state. The one path any local
  actor can *initiate* is the `llmpilot://recover` link (the recovery
  email's one-click restore): it carries no authority of its own — it can
  only attempt a restore with a token the initiator already holds, and the
  app requires an explicit in-app confirmation ("Restore Pro on this Mac?")
  before that restore runs, so an unrequested link changes nothing on a
  decline.

## Network egress, in full

| To | Why | Carries a token? |
|----|-----|------------------|
| `api.anthropic.com` (usage / profile) | read your usage | your own Claude access token, over TLS |
| `platform.claude.com` (OAuth token) | refresh a login when something needs it: ~10 min before a switch (yours or the autopilot's), an autopilot revive of a stale account, or an in-app sign-in — never a background loop; at most 2 attempts per account per 24 h, and any 429 pauses all refreshes for 24 h | your own refresh token (or a one-time authorization code), over TLS |
| `claude.com` (hosted sign-in page) | only when you sign in from the app — you authenticate on Anthropic's own page; llmpilot never sees your password | no |
| `api.llmpilot.dev` (the licensing worker) | Pro purchase and entitlement | never a Claude token |
| `checkout.stripe.com` / `llmpilot.dev` (checkout) | only when you buy Pro — Stripe's hosted checkout, opened in your browser (an app window only if the browser cannot be opened); `llmpilot.dev` serves the page you land on after paying or backing out | never a Claude token |
| `github.com` (menu bar app only) | Sparkle update check (GET) and update downloads | no |

The Anthropic endpoints are the same ones Claude Code itself calls; llmpilot
sends your credential there and nowhere else. The sign-in row is a page in
your browser or in an app window, depending on where you start it; the
checkout row is a page in your browser, in an app window only as a fallback.
Like any web page, they load what Anthropic's and Stripe's pages embed. A
browser sign-in started from the cockpit's Add account returns to the app
through a one-time listener on `127.0.0.1`; the app window's browser option
has you paste a code back instead. The CLI and daemon perform no update
check.

Server-side: the licensing worker sends its two transactional emails — the
pre-charge trial reminder and license recovery — through Resend. The only
personal data that reaches Resend is the receipt email address and the
message itself; never a Claude token, never usage data.

## Undocumented surfaces

The usage endpoint, the OAuth token endpoint, the Keychain service naming, and
Claude Code's config/lock layout are undocumented and reverse-engineered. They
can change without notice. llmpilot confines that knowledge to small adapters and
falls back to Claude Code's own tooling where it can, but a future Claude Code
change may break a feature until llmpilot catches up.

## Reporting a vulnerability

Please report security issues privately rather than in a public issue. Open a
[GitHub security advisory](https://github.com/alicicek/llmpilot/security/advisories/new)
on this repository, or email the address listed on the maintainer's GitHub
profile. Expect an acknowledgement within a few days.

Please do not include real tokens, credentials, or account identifiers in a
report — a redacted reproduction is enough.
