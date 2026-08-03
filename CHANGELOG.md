# Changelog

All notable user-facing changes to llmpilot. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/spec/v2.0.0.html).

## [1.2.5] - 2026-08-03

### Changed

- **The ask is one clear offer: try free for 4 days, then £9.99 once, yours
  for life.** The trial is the purchase — card up front, a single charge at
  trial end, renewal cancelled automatically. The old full-price-first
  ladder (discount step, no-card step, "keep using the free tools" link) is
  gone; closing the paywall instead surfaces the standing lower price once,
  struck honestly against the regular one.
- **You pick when the trial reminder email lands.** Two days or one day
  before the charge, chosen beside a timeline of the real dates — and the
  choice drives the actual email, not just the copy on screen.
- **Trial-reminder and license-recovery emails now arrive reliably.** They
  are delivered through a dedicated provider with per-message delivery
  logs; previously a recovery email could fail without leaving a trace.

### Fixed

- **A nearly-full usage bar no longer reads as completely full.** Every
  usage track now ends in a visible tick, and the menu bar's account rows
  gained a small ring beside the percentage — at 90% the ring shows an
  unmistakable 36° gap where a thin bar sliver did not.
- **The checkout page names the real price and charge date when nothing is
  due today.** A trial checkout used to headline £0.00 and never say what
  would be charged, or when.
- **The first-run screen always keeps a way forward.** The sign-in-later
  link now appears when no accounts were found or an adopt attempt failed —
  a denied Keychain prompt no longer strands the screen.
- **Buying from an outdated app asks for an update instead of failing
  quietly.** An older app can show terms the server no longer sells; the
  refusal now says what happened and what to do.

## [1.2.4] - 2026-07-30

### Fixed

- **Buy buttons no longer die after the first click.** Opening the checkout
  window once locked the paywall's double-click protection permanently, so
  closing checkout and clicking any purchase button again did nothing until
  the app restarted. The protection now releases a moment after the checkout
  window opens; a genuine double-click still cannot start two checkouts.
- **A checkout that cannot start now says so, next to the button.** In
  particular, a cockpit window left open across an app update loses its
  session token; every purchase click was refused invisibly. The refusal now
  appears where you clicked, with what to do about it.
- **The first-run window no longer counts as shown when nobody saw it.** With
  a fullscreen app in front, macOS can open the cockpit's one-time welcome
  behind everything; it then never appeared again. It now only counts as
  shown once it is actually visible, and otherwise tries again next launch.
- **The menu bar's adopt list tells identical sign-ins apart.** The same
  account signed in from two folders showed as two indistinguishable rows;
  each row now carries its folder, like the cockpit already did.
- **The checkout page looks like part of the product.** The wrapper around
  the payment form previously rendered unstyled.

## [1.2.3] - 2026-07-29

### Fixed

- **Updating restarts the daemon — this time for real.** 1.2.2 spotted a
  left-behind daemon by reading which executable it was running, but the
  updater deletes the copy it moved aside, so by the time the new app looked
  there was no path to read and the check quietly did nothing. A daemon whose
  executable has vanished is now treated as left behind, which is precisely
  what an in-place update leaves. A daemon installed from Homebrew or built
  from source is still never restarted.

## [1.2.2] - 2026-07-28

### Fixed

- **Updating really does restart the daemon now.** 1.2.1 tried to spot a
  left-behind daemon by comparing the version it reports — but a daemon old
  enough to be stale is old enough to predate that field, so the check could
  never fire on the very update that needed it. It now looks at which
  executable the daemon is actually running. A daemon started from Homebrew
  or from source is left alone.

## [1.2.1] - 2026-07-28

### Fixed

- **The doctor no longer claims llmpilot will not start at login.** It looked
  for a launch agent *file*, but the app registers the daemon through macOS's
  own login-item service, which writes no such file — so a correctly installed
  Mac was told it was broken, and the suggested fix could not clear it. The
  check now asks launchd directly, and says "not checked" when it cannot get a
  straight answer instead of guessing.
- **Updating no longer leaves the old daemon running.** The updater replaces
  the app but not the background daemon, which is a separate service, so after
  an update the new app talked to the previous version's daemon until the next
  logout. The app now notices the mismatch and restarts it once.

### Added

- The daemon reports its own version, so anything talking to it can tell which
  build is actually answering.

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

[1.2.3]: https://github.com/alicicek/llmpilot/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/alicicek/llmpilot/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/alicicek/llmpilot/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/alicicek/llmpilot/compare/v1.0.1...v1.2.0
[1.0.1]: https://github.com/alicicek/llmpilot/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/alicicek/llmpilot/releases/tag/v1.0.0
