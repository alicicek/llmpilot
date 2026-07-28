# Changelog

All notable user-facing changes to llmpilot. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-07-27

### Added

- **`llmpilot doctor`** — checks the fleet, the sign-ins on this Mac, the
  refresh budget, the daemon and the install, and reports what is wrong, what
  it could not check, and the one thing that fixes each finding. Read-only by
  proof, not promise: a full sweep writes nothing, takes no lock and spends no
  budget. Also a panel in the cockpit, served by the same engine.
- **Sign in from the app** — "Sign in with Claude" in the cockpit and the menu
  bar opens Anthropic's own hosted sign-in page in a native window. The code
  exchange happens on your Mac; llmpilot never sees your password.
- **Adopt and move** — sign-ins detected outside the fleet can be adopted as
  watched accounts or moved into the fleet: backed up first, then made
  switchable, with every partial state named. Adoption resolves accounts by
  identity, not by folder path.
- **Foreign sign-ins are kept, never lost** — switching away from an account
  llmpilot does not manage preserves that credential in a stash; adopt or
  discard it later from the cockpit or menu bar.
- **`llmpilot token add / list / copy / remove`** — long-lived headless tokens
  (the `claude setup-token` kind, for CI and headless machines) stored in your
  Keychain. Only label and dates ever touch disk; the one way a token leaves
  the Keychain is an explicit `token copy` to the clipboard, and the output
  says so.
- **First run** — the app starts the daemon on first launch with zero clicks,
  opens the cockpit, and offers the Claude sign-ins already on the Mac.

### Changed

- **No background token-refresh loop, ever.** An earlier build refreshed idle
  logins on a timer; that is gone. llmpilot refreshes a login only when
  something needs it — about 10 minutes before a planned switch, when the
  autopilot revives a stale account, or when you sign in from the app — capped
  at 2 attempts per account per rolling 24 hours, with a global 24-hour pause
  after any rate-limit answer from the token endpoint.
- **Stale reads stale.** A login llmpilot cannot currently read is frozen at
  its last-known numbers and marked, on every surface, until a switch, a
  revive or a re-login proves it live again.
- **The autopilot revives honestly.** A stale account is only offered as a
  switch target after a refresh proves it live, and unattended refreshes
  always leave one budget slot for your own switch.
- **Usage polling is budgeted** — a steady 3-minute cadence with a hard cap of
  28 requests per account per rolling hour, backing off on rate limits.
- **Switching is hardened end-to-end** — the outgoing credential is classified
  by identity under the lock, config writes are compare-and-swap, every step
  can roll back, and an interrupted switch is recoverable from its journal.

### Fixed

- The statusline no longer shows the previous account's limits after a switch
  — its floor is bound to the session identity.
- The menu bar and cockpit decode every daemon state, including the empty
  fresh-install state.

### Security

- The docs now match shipped behavior: SECURITY.md lists every request
  llmpilot itself makes — including the embedded sign-in and checkout pages —
  and the real refresh triggers. The CLI and daemon perform no update check;
  updates are Sparkle in the menu bar app only, against GitHub.

## [1.0.1] - 2026-07-22

### Added

- The brand mark, everywhere: app icon, menu bar, cockpit, site.
- A styled DMG as the website download.

### Fixed

- The bundled daemon reports the release version.

## [1.0.0] - 2026-07-18

Initial public release: live usage for every account, lock-first switching,
window scheduling, the cockpit, the menu bar app, the statusline, and the
one-time Pro autopilot.

[1.2.0]: https://github.com/alicicek/llmpilot/compare/v1.0.1...v1.2.0
[1.0.1]: https://github.com/alicicek/llmpilot/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/alicicek/llmpilot/releases/tag/v1.0.0
