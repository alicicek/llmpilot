# Security

## The short version

- llmpilot runs entirely on your Mac.
- Your Claude tokens never leave the machine. There is no telemetry.
- The only outbound traffic is to Anthropic's own endpoints (the same ones
  Claude Code uses), to a licensing worker for Pro (which never sees a Claude
  token), and one optional version check you can turn off.

## What llmpilot touches

- **The macOS Keychain** — llmpilot reads and writes the credential item Claude
  Code already stores. It does so under Claude Code's own lock files, so it
  cooperates with a running `claude` session rather than racing its token
  refresh. Credential writes are lock-first, backed up, and verified, so an
  interrupted switch cannot corrupt a login.
- **`~/.claude.json` and per-account config dirs** — read for identity, written
  only to switch the active account (atomic, tempfile + rename).
- **Local cache under `$LLMPILOT_HOME`** (default `~/.llmpilot`) — usage
  percentages, reset timestamps, and schedules. **Never tokens.**
- **A loopback socket** — every surface (menu bar, cockpit, statusline, CLI)
  reads the daemon over `127.0.0.1` / a unix socket. Routes that reveal or
  mutate a license require an install-scoped token, so another local process
  cannot read or change your entitlement.

## Network egress, in full

| To | Why | Carries a token? |
|----|-----|------------------|
| `api.anthropic.com` (usage / profile) | read your usage | your own Claude access token, over TLS |
| `platform.claude.com` (OAuth token) | keep idle logins fresh (Pro/keep-warm) | your own refresh token, over TLS |
| the licensing worker | Pro purchase and entitlement | never a Claude token |
| version check (GET only) | notify you of updates | no |

The Anthropic endpoints are the same ones Claude Code itself calls; llmpilot
sends your credential there and nowhere else. The version check is off in CI and
can be disabled with `LLMPILOT_NO_UPDATE_CHECK=1`.

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
