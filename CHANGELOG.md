# Changelog

All notable user-facing changes to llmpilot. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/spec/v2.0.0.html).

## [1.3.5] - 2026-08-29

One-click restore from the recovery email, on the Mac app only. No price,
trial length, offer, or account-data changes.

### Added

- **The recovery email restores Pro in one click.** The page the email
  links to now has an "Open llmpilot" button: on the Mac you're restoring,
  it hands the one-time code to the app so you don't retype it. The app
  asks you to confirm ("Restore Pro on this Mac?") before it turns Pro on —
  so a link you didn't request changes nothing if you decline. The typed
  code still works exactly as before, and remains the way to restore from
  a phone or a Mac that doesn't have llmpilot yet.

### Fixed

- **Restoring right after installing waits for the app to be ready.**
  Opening the link on a fresh Mac launches llmpilot; the restore now waits
  for it to finish starting instead of failing, and says what to do if
  something is off.

## [1.3.4] - 2026-08-28

Checkout moves to your browser. No price, trial length, or offer changes:
£9.99 / $12.99 after the 4-day free trial, and the one lower offer at
£5.99 / $7.99, are exactly what 1.3.1 through 1.3.3 sold. Nothing about
accounts, schedules, or settings data changes.

### Changed

- **The trial button opens checkout in your browser.** Pressing it now
  opens the payment page in your default browser instead of a window
  inside the app — which means Apple Pay (Safari), Google Pay (Chrome),
  your browser's saved cards, and one-click checkout appear where your
  browser supports them. The in-app window remains only as a fallback for
  the rare case the browser cannot be opened. The ✕ on the price screen
  is dimmed from the press until the browser has the page; once it does,
  the ✕ closes the screen and the purchase carries on in the browser.
- **Backing out is understood immediately.** Leaving the checkout page via
  its back arrow tells the app right away: the page you left can no
  longer charge you, and the price screen offers its one lower price
  within seconds instead of after a timeout. Closing the tab without
  backing out is answered more slowly (about ten minutes), and a payment
  made later in a still-open tab is always honored — the app keeps
  checking for it for as long as the page stays payable, so a late
  payment turns Pro on rather than disappearing.
- **One payable checkout at a time.** Starting a new checkout closes any
  earlier still-open payment page for this Mac, and a Mac whose license
  is already active is never sold a second one.

### Fixed

- **The sign-in retry says what it does.** When the sign-in server is
  rate-limited, the message now says that trying again starts a fresh
  sign-in and that the interrupted attempt's code is used and will not
  work again — instead of implying the same sign-in resumes.
- **The checkout web pages read like answers.** The page after paying
  confirms and points back to the app; the page after backing out says
  plainly that nothing was charged.

## [1.3.3] - 2026-08-19

Two fixes to the Pro price screen's lower offer, on the Mac app only. No
price, trial length, or offer changes: £9.99 / $12.99 after the 4-day
free trial, and the one lower offer at £5.99 / $7.99, are exactly what
1.3.1 and 1.3.2 sold. Nothing about accounts, schedules, or settings data
changes.

### Fixed

- **The lower offer is decided for the checkout you actually closed.**
  Backing out of a checkout without paying arms the price screen's one
  lower offer — on the screen itself if it is still open, otherwise the
  next time it opens. That decision is reached about ten seconds after
  the payment window closes, and until now it did not know which window
  it was about: back out, press the trial button again inside those
  seconds, and the lower offer armed behind the new full-price checkout —
  the screen re-drew at £5.99 with £9.99 struck through while the open
  window still charged £9.99. Every checkout press and payment window on
  the install is now a numbered event, and a closed window's verdict
  counts only while that window is still the newest; a newer press
  anywhere voids it. What you pay was always, and remains, what the
  payment window says — a closed window's verdict can no longer paint a
  stale price behind a newer one.
- **The ✕ waits for the checkout.** Pressing the trial button takes a
  moment — the app asks the payment server for a checkout — and in that
  moment the price screen's ✕ still worked: it armed the lower offer and
  re-drew the screen at £5.99, and then the full-price payment window the
  button was opening landed on top of it. The ✕ is now dimmed and does
  nothing from the press until that payment window has closed; the
  window's own Cancel is the way out. And for the ten seconds after it
  closes, while the app is still finding out whether you paid, the ✕
  closes the screen and leaves the lower offer to that answer — it is
  no longer decided ahead of it.

## [1.3.2] - 2026-08-19

A fresh-install audit of 1.3.1 found eight defects across first run, the
Pro screens, and Settings. All of them are fixed here, along with what
fixing them turned up, and the first-run window was reshaped to fit its
content. Nothing about accounts, schedules, or settings data changes.

### Changed

- **The first-run window fits its content.** The tour and price screens
  floated a narrow column in an 860×560 canvas — the progress dots sat
  against the window edges while the content sat far inside them. The
  window is now 616×540 and the dots, headline, card, and footer share
  one centred 560pt column, so the margins are equal on both sides and
  the top, like a mobile onboarding card.
- **The schedule demo's hour axis is decided by geometry.** Labels sit
  every two hours, and one that would collide with the "now" pill or the
  corner caption drops out instead of overprinting it — at this window
  width the axis reads 00 02 04 06 08 · 10:20 · 14 16 18.
- **The switch demo says how long the rested account rests.** Its
  caption names the wait beside the reset clock (e.g. "Resets at 17:19 ·
  ~3h") instead of leaving the subtraction to you.
- **Settings' license actions are real buttons.** Turn on the autopilot,
  Restore by email, and Restore with code were bare grey text beside real
  buttons in the same sheet; they are now plain macOS buttons, and the
  two Restore buttons stay dimmed until their field has something in it.

### Fixed

- **The window's minimum size is enforced.** A real edge drag could take
  the cockpit down to under a quarter of its 1000×700 minimum, clipping
  every panel mid-word. It now stops at the floor, and a new end-to-end
  gate drags the window edge with real mouse events to prove it.
- **The reopened Pro screen is opaque.** Opening Pro again from the board
  drew the Free/Pro comparison over a translucent backdrop with the
  cockpit reading through it.
- **Two rows, one address — both name their folder.** When the same email
  is signed in from one folder and signed out in another, first run's
  account inventory showed both rows with no folder on either, and the
  screen read as contradicting itself.
- **The schedule demo's status swaps cleanly.** "Booked — opens 07:00"
  and "In use — resets 12:00" were crossfaded on top of each other for a
  beat at each change; the swap is now instant.
- **The progress dots count the screens you actually walk.** The strip
  no longer counts a screen that only a buyer ever sees, so it stops
  promising a step the flow cannot give you; the confirmation screen
  keeps its layout instead of jumping when the strip goes.
- **The trial's article can no longer go wrong.** The trial length comes
  from the payment server while the words around it hardcoded "a" —
  right for the 4-day trial on sale, wrong for any length that takes
  "an". The article now follows the number's sound. The lower offer's
  line also gained its full stop: "Same trial, lower price."
- **The payment server's fallback trial is the trial on sale.** If the
  configured trial length ever went missing, the server fell back to 8
  days — quoting it in the paywall's consent copy, sending it to Stripe
  as the charge date, and, at that length, switching off the emails that
  warn people before they are charged. The fallback is now 4, pinned
  equal to the deployed value by a test, and the release script refuses
  to ship while the live server disagrees with the tree.

## [1.3.1] - 2026-08-17

The build the launch posts point at: a fresh-user walk of 1.3.0 on a
reset Mac (real download, real Gatekeeper) found one dead end and a dozen
first-ten-minutes defects. All of them are fixed here; nothing about
accounts, schedules, or settings changes.

### Added

- **The price screen makes one lower offer before it closes.** Press ✕ and
  the first time it re-draws with the lower price instead of closing —
  £5.99 / $7.99, the same free trial, quoted live from the payment server,
  the previous price struck through, no deadline attached. Press ✕ again
  and it closes. Backing out of checkout without paying arms the same
  single offer for the next time the screen opens. It happens once per
  install, and buying at any price — or restoring a purchase — ends it
  permanently.

### Fixed

- **The cockpit no longer goes click-dead after the first board tap.** On
  macOS 26.5 the first tick sound of a session could throw inside the
  click that played it, after which every button in the window ignored
  the mouse while hover, menus and the window frame still worked — it read
  as frozen and a relaunch did not clear it. The sound engine is now built
  before it starts and never runs inside a click; a new end-to-end gate
  posts real mouse clicks (not accessibility presses) to prove the window
  stays alive.
- **A rate-limited sign-in reads as one.** A first sign-in that met a 429
  used to pause every account's token refresh for 24 hours and the doctor
  called it "a token refresh". A sign-in 429 now pauses refreshes for one
  hour, the doctor says a sign-in was rate-limited and that signing in
  still works, and the browser tab says "you can close this tab" once
  instead of "try again" twice.
- **No "unregistered" nudge on first launch.** The daemon posted an event
  and a notification naming the very account first run was about to add.
  The nudge now waits until a fleet exists — it is for a new sign-in
  appearing later.
- **The cockpit comes to the front when it should.** Opening the sign-in
  window from the menu bar and closing it could leave the cockpit opening
  behind the previous app with that app's menu bar.
- **First run's account inventory shows what you own.** Each detected
  account now carries the same live lane the menu bar shows (5-hour,
  weekly, and per-model bars with percent and reset time), a folder whose
  sign-in is gone is listed as signed out with a Sign in again button
  instead of vanishing, Add account is a real button, and the copy agrees
  in number with the count.
- **The switch demo tells its whole story.** The first account's percent
  is visible as it climbs and reads 97 at the switch; the second account
  starts moving after the handoff so you can see work continue. Demo
  identities read as real addresses.
- **The price screen breathes.** More room in the price card, and its
  footer holds Restore a purchase only — the reminder day is chosen on its
  own screen.
- **The board fits the window — any window.** The 24-hour axis derives
  from the live width instead of a fixed 1400pt row inside a hidden
  scroller (the day used to clip at about 18:00 at the size the window
  opens with), and the lane column shows Fable, not F, with the full reset
  time.
- **A calmer cockpit header.** The permanently green Daemon active pill is
  gone (the slot shows only Connecting or Not running), the ? and settings
  controls sit left of Add account and Fresh window, and the guided tour
  has three steps. The first-run window is fixed at its designed size; the
  cockpit stays resizable.
- **A rate-limited sign-in offers an explicit retry.** The sheet says to
  wait a minute and its primary action reads Try again.

## [1.3.0] - 2026-08-14

### Added

- **The autopilot now rides each account to its own edge.** Instead of
  switching at a fixed 90%, it watches how fast each account is actually
  burning and switches when the wall is about 8 minutes away — up to 97%
  on a Max 20× plan when the pace says that's safe, and earlier when a
  hot session genuinely needs it. With no burn data yet (right after a
  restart, or an account that just went quiet) it falls back to the old
  90% rule rather than guess. Setting `threshold_percent` in config.json
  still pins the old fixed behaviour exactly.
- **Watch-only accounts tell you when they could help.** If the autopilot
  wants to switch and the only headroom left sits on an account you added
  as watch-only, you get one notification naming it — moving it into the
  fleet stays a two-click choice that is always yours.
- **Account rows show the plan.** Detected sign-ins carry their
  subscription tier (Pro, Max 5×, Max 20×) in the first-run inventory.
- **Turning Pro on lists your watch-only accounts** with a Make
  switchable button right on the confirmation screen, so paying never
  leaves the autopilot with nothing it is allowed to switch to.

### Changed

- **The cockpit is fully native now.** The window looks the same but is
  built from real macOS controls instead of an embedded web page — faster
  to open, resizable, and readable with VoiceOver. Real macOS notification
  banners replace the old script-based ones, and a guided tour introduces
  the board the first time you open it. Nothing about your accounts,
  schedules, or settings changes or needs migrating.
- The browser cockpit (`llmpilot open`) is still there for a CLI-only
  install with no app.
- **First run answers the questions it used to skip.** The add-account
  screen explains what pressing the button does, shows an example of an
  added account, and states where your sign-in lives: in your Mac's
  Keychain, only ever seen by Anthropic, with no telemetry. The switch
  demo now climbs to 97% and switches one tick under the wall — the same
  behaviour the autopilot ships with.
- Every cockpit sheet uses one even margin all the way around, with the
  close button where macOS dialogs put it.

### Fixed

- **Only usable sign-ins are listed and added on first run.** A folder
  whose sign-in has lapsed is no longer counted, listed, or auto-added
  into a failure it cannot survive; it gets a sign-in-again button
  instead, and an add that fails says so on the screen that promised it.
- The multi-account inventory screen now actually appears for fresh
  multi-account Macs instead of being skipped by a race with detection.
- The scheduler's axis no longer overlaps its own caption, and the demo
  screens disclose their example numbers everywhere real accounts appear.

## [1.2.7] - 2026-08-06

### Changed

- **First run explains the problem before it asks you for anything.** It opens
  on the moment you already know — a session limit filling up and stopping you
  mid-thought — then shows the accounts already signed in on this Mac and the
  headroom you could not see, and only then asks to add them. The autopilot
  switching and the scheduled window each get a screen of their own, shown on
  your own accounts once they are added.
- **The price comes last, on the screen that takes the payment.** Everything
  you are agreeing to — the trial length, the exact amount, the date you are
  charged, the day we email you, and how it appears on your statement — now
  sits together on the one screen with the payment button, instead of being
  split across two.
- **You choose when to be reminded before you see a price.** The reminder
  screen states no amount; it names the day your free days end and asks which
  day the email should land. Your choice carries through to the payment
  screen, and it stays changeable from there.
- **A short comparison of free and Pro** appears before the ask, with the free
  column showing what it honestly is: watching every limit, switching by hand,
  the statusline and analytics all stay free.

### Fixed

- **Add account no longer tells you to sign in to an account you are already
  using.** A second folder holding an account llmpilot already watches is now
  named as exactly that — one account means one limit, so the extra folder
  adds no headroom — instead of reading as a signed-out account needing a
  fresh login.
- **The paused screen can be closed.** When a trial had ended, that screen
  offered no way out except reloading the window.

## [1.2.6] - 2026-08-04

### Added

- **First run now walks you through it, one screen at a time.** Your accounts,
  then the autopilot shown switching away from a wall before you hit it, then
  the offer, then when you want to be reminded, then what is on. The switch
  demonstration runs on your own accounts once there are two of them, and says
  so plainly when it is running on a sample instead.
- **A short guide points at your own cockpit.** It spotlights your live usage,
  the control that moves you to an account with room, booking a window ahead
  of time, and where llmpilot keeps running once the window is closed. It
  appears once and stays available from the toolbar afterwards.

### Changed

- **Accounts are grouped by who they are, not by folder.** Two folders holding
  the same account collapse into a single row that says so — watching both
  adds no headroom, because they share one limit. A genuinely separate account
  is named as what it is: the one the autopilot switches to.
- **Switching to another account is a control on that account's own row**,
  beside its name, rather than a small link below its usage bars.
- **llmpilot starts with your Mac by default.** The daemon always did; the menu
  bar icon did not, so after a restart it was simply gone. The switch stays in
  the gear menu, and first run now says where the icon lives and that a menu
  bar manager such as Ice or Bartender can hide it.

### Fixed

- **Folders whose sign-in is gone are no longer offered as accounts.** A Claude
  folder remembers which account it belonged to even after the sign-in itself
  is gone, so llmpilot listed it as available and then refused to add it. It
  now tells you the folder is signed out and what to do about it.
- **You can paste into the in-app sign-in window.** The code field could not
  take ⌘V — which was the one thing that window was for. Pasting also works
  with Caps Lock on, and in the cockpit and checkout windows.
- **Booking a fresh window without the autopilot answers with the offer, not
  an error.** It used to fail with the daemon's own internal wording and point
  at recovering a licence you never had. Lanes also stop inviting a click they
  cannot honour.
- **The marker at the end of a usage bar only appears where it means
  something.** On a fresh or idle account it sat alone with nothing to
  reference; it now shows from the warning threshold up, where a rounded fill
  end starts passing for a full bar.

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

[1.3.3]: https://github.com/alicicek/llmpilot/compare/v1.3.2...v1.3.3
[1.3.2]: https://github.com/alicicek/llmpilot/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/alicicek/llmpilot/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/alicicek/llmpilot/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/alicicek/llmpilot/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/alicicek/llmpilot/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/alicicek/llmpilot/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/alicicek/llmpilot/compare/v1.0.1...v1.2.0
[1.0.1]: https://github.com/alicicek/llmpilot/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/alicicek/llmpilot/releases/tag/v1.0.0
