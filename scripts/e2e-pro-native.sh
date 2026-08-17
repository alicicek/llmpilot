#!/bin/bash
# E2E: pro-native — drives the NATIVE onboarding + paywall UI (osascript AX
# automation, System Events) against the REAL pro daemon and the REAL local
# entitlement worker in Stripe TEST mode. Proves, with ZERO accounts in the
# sandbox home:
#
#   1. the first-run mount decision (ProFlowLogic.wantFlow, mirroring
#      App.tsx:268-278) takes the ONBOARDING takeover, not the board.
#   2. the education ladder's real Continue buttons walk OnboardingModel's
#      actual phase order — wall -> accounts -> switch -> windows
#      (OnboardingModel.phases: tour ? [wall] + (identityCount >= 2 ?
#      [blind] : []) + (startedEmpty ? [accounts] : []) + tour ?
#      [switchDemo,windows]) — with the zero-detected accounts step taking
#      its skip/forward path. This sandbox starts with ZERO known
#      identities, so the blind-spot screen (②, design critique 2026-08-09:
#      it reveals the available account INVENTORY and has nothing to reveal
#      on a solo machine) is skipped entirely — it is never mounted here,
#      not shown in some reduced "solo" form.
#   3. the ask reaches receipt -> remind (answering the 8-day trial's real
#      remind-day question) -> price, quoting the worker's REAL terms.
#   4. the price screen quotes ONE price and offers no way to bargain down
#      (owner 2026-08-11: the decline ladder and its "See a lower price"
#      control are gone) — asserted below by their absence.
#
# HARD STOP: checkout-start is located but NEVER pressed.
# CheckoutSheetPolicy.decide (CheckoutSheet.swift:32-44) sends any
# off-payment-host URL to NSWorkspace.shared.open — pressing checkout would
# open the operator's REAL system browser. The daemon -> worker checkout
# mutation is already proven at the HTTP level by scripts/e2e-pro.sh.
#
# Sandboxed like every native e2e script here: fake HOME + fixed
# LLMPILOT_HOME, CLAUDE_CONFIG_DIR OUTSIDE the fake home (empty — zero
# accounts, zero detected dirs), throwaway keychain, LLMPILOT_TEST=1,
# LLMPILOT_NO_LAUNCHD=1, LLMPILOT_DISABLE_SMAPPSERVICE=1,
# LLMPILOT_NATIVE_COCKPIT=1 (the e2e seam that auto-opens the native window),
# throwaway UserDefaults suite, and the llmpilot-cockpit window-frame
# snapshot/restore (e2e-native-board.sh's cfprefsd-leak fix — same window
# autosave name, same leak).
#
# Usage: scripts/e2e-pro-native.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f go.work ] || [ ! -d ../llmpilot-pro ]; then
  echo "SKIP: needs go.work + ../llmpilot-pro for the -tags=pro daemon." >&2
  exit 2
fi
if ! command -v op >/dev/null 2>&1; then
  echo "SKIP: needs the 1Password CLI (op) to inject the worker's TEST keys." >&2
  exit 2
fi

# PREFLIGHT: exactly one llmpilot app process, or none of the AX walks below
# can be trusted. System Events resolves "first process whose unix id is N"
# into a BY-NAME process reference, so a second llmpilot (a stale run, or one
# frozen under an Xcode debug session -- STAT SX, which survives kill -9 until
# its debugserver is killed) silently captures every lookup and the walk fails
# with -1728 while "name of windows" still reports the window is open. That
# misreads as a flaky Mac; it is not. Measured 2026-08-09.
STRAY_LLMPILOT=$(pgrep -f "llmpilot\.app/Contents/MacOS/llmpilot" 2>/dev/null || true)
if [ -n "$STRAY_LLMPILOT" ]; then
  echo "E2E: FAIL -- another llmpilot app process is already running (pids: $(echo $STRAY_LLMPILOT | tr '\n' ' '))."
  echo "  Every AX lookup would be ambiguous. Quit it and re-run; if it will not"
  echo "  die, kill the Xcode debugserver holding it (ps -o ppid= -p <pid>)."
  exit 1
fi

REAL_HOME="$HOME"
ROOT=$(mktemp -d /tmp/llmpilot-e2e-pro-native.XXXXXX)
KEYCHAIN="$ROOT/throwaway.keychain-db"
BIN="$ROOT/llmpilot-pro"
WIN_TITLE="llmpilot"

# wrangler dev spawns child processes (esbuild, workerd) that outlive a
# plain `kill` of the npm/wrangler parent (npm does not exec-replace
# itself) — kill the whole subtree so a run never leaks a worker still
# bound to :8787 for the next invocation.
kill_tree() {
  local pid="$1"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null || true
}

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${WRANGLER_PID:-}" ] && kill_tree "$WRANGLER_PID"
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -f worker/.dev.vars
  if [ -n "${LLMPILOT_DEFAULTS_SUITE:-}" ]; then
    HOME="$REAL_HOME" defaults delete "$LLMPILOT_DEFAULTS_SUITE" 2>/dev/null || true
  # `defaults delete` silently fails on an empty domain and leaves the
  # plist behind (119 piled up before this line existed) — remove it too.
  rm -f "$REAL_HOME/Library/Preferences/$LLMPILOT_DEFAULTS_SUITE.plist" 2>/dev/null || true
  fi
  if [ "${PRE_FLAG:-ABSENT}" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || true
  else
    case "$PRE_FLAG" in
      1|true|yes) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool true 2>/dev/null || true ;;
      0|false|no) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool false 2>/dev/null || true ;;
    esac
  fi
  if [ "${PRE_FRAME:-ABSENT}" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
  else
    HOME="$REAL_HOME" defaults write dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" -string "$PRE_FRAME" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

echo "== build the cockpit + the Pro daemon (-tags=pro, go.work resolves the engine) =="
(cd web && pnpm build >/dev/null)
go build -tags=pro -o "$BIN" ./cmd/llmpilot

echo "== build the native app (Release) =="
HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
  -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
# Ad-hoc builds keep Sparkle's own Team-ID signature on the embedded
# framework, which library validation rejects — re-sign consistently.
codesign --force --deep -s - "$APP" 2>/dev/null

echo "== bring up the entitlement worker (op-injected TEST keys, local D1) =="
(cd worker && op inject -f -i .dev.vars.template -o .dev.vars >/dev/null 2>&1)
(cd worker && npm run migrate:local >/dev/null 2>&1)
(cd worker && npm run dev >"$ROOT/wrangler.log" 2>&1) &
WRANGLER_PID=$!
disown # bash job-control would otherwise print a "Terminated" notice on
       # trap kill, landing after the final PASS/FAIL line (e2e-native-board.sh's fix).
for _ in $(seq 1 60); do
  curl -fsS "http://localhost:8787/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://localhost:8787/healthz" >/dev/null || { echo "worker never came up"; tail -5 "$ROOT/wrangler.log"; exit 1; }
echo "  worker healthz OK on :8787"

echo "== sandbox: fake HOME, throwaway keychain, native-cockpit env =="
export TZ=UTC
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
# OUTSIDE the fake home, same reasoning as e2e-native-board.sh/e2e-menubar.sh
# — and left EMPTY on purpose: this is the zero-accounts, zero-detected
# first-run case the whole script exists to drive.
export CLAUDE_CONFIG_DIR="$ROOT/claude"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
export LLMPILOT_ENTITLEMENT_URL="http://localhost:8787"
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-pro-native.$$"
# The fixture daemon runs in the foreground under our control; nothing here
# should ever touch launchd.
export LLMPILOT_NO_LAUNCHD=1
# e2e seam: auto-open the native cockpit window with zero navigation
# (LLMPilotApp.swift:20).
export LLMPILOT_NATIVE_COCKPIT=1
mkdir -p "$LLMPILOT_HOME" "$HOME" "$CLAUDE_CONFIG_DIR"
/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"

# cfprefsd routes UserDefaults writes to the REAL dev.llmpilot.menubar domain
# regardless of the redirected $HOME (e2e-native-board.sh's finding) —
# snapshot/restore both leaked keys so a killed sandbox run never bleeds into
# the developer's real app.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
PRE_FRAME=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || echo "ABSENT")
if [ "$PRE_FRAME" != "ABSENT" ]; then
  HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
fi
# Suppress the web cockpit's own first-launch auto-open — LLMPILOT_NATIVE_COCKPIT
# already opens the native window unconditionally; this just keeps a second,
# competing (web) window off screen for a clean AX walk.
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true

echo "== start the sandboxed Pro daemon against the local worker =="
"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
disown
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
[ -f "$LLMPILOT_HOME/daemon.port" ] || { echo "E2E PRO-NATIVE: FAIL — daemon never wrote daemon.port"; tail -20 "$ROOT/daemon.log"; exit 1; }
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
BASE="http://127.0.0.1:$PORT"
echo "  daemon on $BASE"

echo "== confirm the official-build entitlement gate: available=true active=false status=none =="
LIC=$(curl -fsS "$BASE/v1/license")
echo "  GET /v1/license -> $(printf '%s' "$LIC" | jq -c '{available, active, status}')"
AVAIL=$(printf '%s' "$LIC" | jq -r '.available')
ACTIVE=$(printf '%s' "$LIC" | jq -r '.active')
STATUS=$(printf '%s' "$LIC" | jq -r '.status')
[ "$AVAIL" = "true" ] && [ "$ACTIVE" = "false" ] && [ "$STATUS" = "none" ] || {
  echo "E2E PRO-NATIVE: FAIL — /v1/license not in the expected first-run shape"; exit 1; }

echo "== fetch the REAL quoted terms ourselves (GET /v1/license/quote) =="
QUOTE=$(curl -fsS "$BASE/v1/license/quote")
TRIAL_DAYS=$(printf '%s' "$QUOTE" | jq -r '.trial_days')
FULL_MINOR=$(printf '%s' "$QUOTE" | jq -r '.prices.full.gbp')
DISC_MINOR=$(printf '%s' "$QUOTE" | jq -r '.prices.discount.gbp')
[ "$FULL_MINOR" != "null" ] && [ "$DISC_MINOR" != "null" ] || {
  echo "E2E PRO-NATIVE: FAIL — quote carried no gbp price (full=$FULL_MINOR discount=$DISC_MINOR)"; exit 1; }
# LadderLogic.formatAmount/localAmount: this app's Locale.current.identifier
# uses macOS's underscore form (e.g. "en_GB"), which never matches
# localAmount's hyphenated "-us"/"-gb" exact-match check, so every locale on
# this Mac falls through to the "gbp" candidate pushed ahead of the sorted
# fallback. NumberFormatter(.currency, currencyCode: "GBP") renders minor
# units as "<symbol>D.DD" — grep on the bare digits only, so the assertion
# survives whatever currency glyph/locale grouping the AX tree exposes.
FULL_STR=$(awk -v m="$FULL_MINOR" 'BEGIN{printf "%.2f", m/100}')
DISC_STR=$(awk -v m="$DISC_MINOR" 'BEGIN{printf "%.2f", m/100}')
echo "  quoted: ${TRIAL_DAYS}-day trial, full=$FULL_STR gbp, discount=$DISC_STR gbp"

echo "== launch the native app (zero accounts, zero detected dirs) =="
# -SUEnableAutomaticChecks NO rides the ARGUMENT defaults domain (highest
# precedence, nothing persisted): a Release build otherwise fires a live
# Sparkle appcast check mid-walk and the update dialog sits over the
# paywall in the LOOK screenshot (caught on the first S6 run). Never write
# this key into the real dev.llmpilot.menubar domain from a harness — a
# killed run would leave the developer's real app with update checks off
# (S6 review F4).
"$APP/Contents/MacOS/llmpilot" -SUEnableAutomaticChecks NO >"$ROOT/app.log" 2>&1 &
APP_PID=$!
disown
echo "== app launched (pid $APP_PID) — waiting for the native cockpit window =="

WINDOW=""
for _ in $(seq 1 30); do
  WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
  case "$WINDOW" in "$WIN_TITLE"|"$WIN_TITLE, "*|*", $WIN_TITLE"|*", $WIN_TITLE, "*) break ;; esac
  sleep 1
done
case "$WINDOW" in
  "$WIN_TITLE"|"$WIN_TITLE, "*|*", $WIN_TITLE"|*", $WIN_TITLE, "*) echo "== native cockpit window open (AX: windows = $WINDOW) ==" ;;
  *) echo "E2E PRO-NATIVE: FAIL — no native cockpit window (AX: '$WINDOW')"; tail -20 "$ROOT/app.log"; exit 1 ;;
esac

frontmost_app() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
}
frontmost_app

# Per-element walk with try/catch — the ONLY reliable AX-identifier search
# (a `whose` clause over `entire contents` is invalid AppleScript, -1700;
# measured elsewhere in this repo: a full walk of a comparable window is
# ~14s, well inside the retry budgets below). Structured so osascript always
# EXITS 0 (result rides stdout) — under set -e a non-zero exit would
# silently kill the harness mid-retry.
osa_query() { # <attr> <value> <action: locate|press>
  local attr="$1" val="$2" action="$3"
  osascript <<OSA 2>&1 || true
set out to "MISSING"
with timeout of 60 seconds
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    set win to window "$WIN_TITLE"
    set elems to entire contents of win
    repeat with i from 1 to (count of elems)
      try
        set elem to item i of elems
        if (value of attribute "$attr" of elem) is "$val" then
          if "$action" is "locate" then
            set out to "FOUND"
          else
            perform action "AXPress" of elem
            set out to "PRESSED"
          end if
          exit repeat
        end if
      end try
    end repeat
  end tell
end tell
end timeout
out
OSA
}
osa_locate_id() { osa_query "AXIdentifier" "$1" locate; }
osa_press_id() { osa_query "AXIdentifier" "$1" press; }

# Dumps every AXValue/AXTitle string in the window onto stdout, one per
# line — used only for the quoted-amount asserts, where the amount is
# composed from several concatenated SwiftUI `Text` runs and there is no
# single stable identifier to locate for the digits themselves.
osa_dump_texts() {
  osascript <<OSA 2>&1 || true
set out to ""
with timeout of 60 seconds
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set win to window "$WIN_TITLE"
    set elems to entire contents of win
    repeat with i from 1 to (count of elems)
      set elem to item i of elems
      try
        set v to value of attribute "AXValue" of elem
        set out to out & (v as string) & linefeed
      end try
      try
        set t to value of attribute "AXTitle" of elem
        set out to out & (t as string) & linefeed
      end try
    end repeat
  end tell
end tell
end timeout
out
OSA
}

wait_locate_id() { # <ident> [tries]
  local ident="$1" tries="${2:-15}" r=""
  for _ in $(seq 1 "$tries"); do
    r=$(osa_locate_id "$ident")
    case "$r" in *FOUND*) echo "$r"; return 0 ;; esac
    sleep 1
  done
  echo "$r"; return 1
}
wait_press_id() { # <ident> [tries]
  local ident="$1" tries="${2:-15}" r=""
  for _ in $(seq 1 "$tries"); do
    r=$(osa_press_id "$ident")
    case "$r" in *PRESSED*) echo "$r"; return 0 ;; esac
    sleep 1
  done
  echo "$r"; return 1
}
wait_texts_contain() { # <needle> [tries]
  local needle="$1" tries="${2:-10}" r=""
  for _ in $(seq 1 "$tries"); do
    r=$(osa_dump_texts)
    case "$r" in *"$needle"*) return 0 ;; esac
    sleep 1
  done
  return 1
}

# ============================================================
# [1] zero-account first run must present the ONBOARDING takeover.
# ============================================================
echo "== [1] zero-account first run: onboarding takeover, not the board =="
wait_locate_id "edu-wall-lanes" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — wall screen (edu-wall-lanes) not found; onboarding did not take over"; tail -20 "$ROOT/app.log"; exit 1; }
echo "  wall screen showing (edu-wall-lanes located)"
BOARD=$(osa_locate_id "fresh-window-menu")
case "$BOARD" in
  *FOUND*) echo "E2E PRO-NATIVE: FAIL — the board's fresh-window-menu is mounted; onboarding should own the whole window"; exit 1 ;;
  *) echo "  board not mounted (fresh-window-menu absent) — confirms the onboarding takeover" ;;
esac

# ============================================================
# [2] education ladder — OnboardingModel.phases' real order on a ZERO-
# identity sandbox: wall -> accounts (skip, zero detected) -> switch ->
# windows. The blind-spot screen (②) is absent from `phases` entirely on
# fewer than two known identities (design critique 2026-08-09) — this
# sandbox starts with zero, so it must never be located here.
# ============================================================
echo "== [2] education ladder: wall -> accounts(skip) -> switch -> windows (blind-spot skipped: <2 identities) =="
wait_press_id "edu-continue" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — wall screen's Continue not pressed"; exit 1; }
echo "  wall: Continue pressed"

wait_locate_id "onboarding-accounts-screen" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — accounts screen not found after wall Continue (blind-spot correctly skipped on <2 identities)"; exit 1; }
echo "  accounts screen showing (blind-spot correctly skipped — this sandbox has zero known identities)"
BLIND=$(osa_locate_id "edu-blind-pair")
case "$BLIND" in
  *FOUND*) echo "E2E PRO-NATIVE: FAIL — edu-blind-pair is mounted; the blind-spot screen must be skipped, not shown, on <2 identities"; exit 1 ;;
  *) echo "  blind-spot screen confirmed absent (edu-blind-pair not found)" ;;
esac
wait_locate_id "onboarding-skip" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — onboarding-skip (\"I'll do this later\") not found — zero detected accounts should show the skip path"; exit 1; }
CONT=$(osa_locate_id "onboarding-continue")
case "$CONT" in
  *FOUND*) echo "E2E PRO-NATIVE: FAIL — onboarding-continue is present with zero detected groups (should not render per OnboardingAccountsStepView)"; exit 1 ;;
  *) echo "  zero-detected path confirmed: onboarding-skip present, onboarding-continue absent" ;;
esac
wait_press_id "onboarding-skip" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — onboarding-skip not pressed"; exit 1; }
echo "  accounts: skip path pressed (accountsForward == .advance since tour == true)"

wait_locate_id "onboarding-switch-step" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — switch-demo screen not found after accounts skip"; exit 1; }
echo "  switch-demo screen showing"
wait_press_id "edu-continue" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — switch-demo screen's Continue not pressed"; exit 1; }
echo "  switch-demo: Continue pressed"

wait_locate_id "edu-windows-board" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — windows screen (edu-windows-board) not found after switch-demo Continue"; exit 1; }
echo "  windows screen showing"
wait_press_id "edu-continue" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — windows screen's Continue not pressed"; exit 1; }
echo "  windows: Continue pressed"

# ============================================================
# [3/4] the ask — receipt -> remind (answer the real remind-day question)
# -> price, quoting the REAL worker terms.
# ============================================================
echo "== [3/4] the ask: receipt -> remind -> price =="
# The old quote-race (resolveGuidedAsk snapshotting quoteModel.quote with
# no later push) was FIXED in review 2026-08-08 P0-1: the composition root
# now wires `.onChange(of: quoteModel.quote) → setQuote` on both asks
# (NativeCockpitWindow.swift). Landing on noterms-screen here therefore
# means the QUOTE FETCH ITSELF failed or never resolved (worker down, bad
# terms) — diagnose the worker, not the view wiring.
if ! wait_locate_id "receipt-screen" 20 >/dev/null; then
  NOTERMS=$(osa_locate_id "noterms-screen")
  case "$NOTERMS" in
    *FOUND*)
      echo "E2E PRO-NATIVE: FAIL — stuck on noterms-screen (\"Loading the price…\"/Reload price) after windows Continue."
      echo "  The setQuote race was fixed 2026-08-08 (onChange wiring in NativeCockpitWindow.swift),"
      echo "  so this means the quote fetch itself failed: check the worker on :8787 and daemon.log."
      exit 1
      ;;
    *)
      echo "E2E PRO-NATIVE: FAIL — receipt screen not found after windows Continue, and noterms-screen is not showing either"
      tail -20 "$ROOT/app.log"
      exit 1
      ;;
  esac
fi
echo "  receipt screen showing"
wait_press_id "receipt-continue" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — receipt-continue not pressed"; exit 1; }
echo "  receipt: Continue pressed"

wait_locate_id "remind-screen" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — remind screen not found after receipt Continue (an $TRIAL_DAYS-day trial should offer remind days)"; exit 1; }
echo "  remind screen showing (${TRIAL_DAYS}-day trial)"
wait_locate_id "remind-offset-1" 5 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — remind-offset-1 not found (an $TRIAL_DAYS-day trial should offer offsets {1,2})"; exit 1; }
wait_press_id "remind-offset-1" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — remind-offset-1 not pressed"; exit 1; }
echo "  remind: 1-day-before offset selected"
wait_press_id "remind-continue" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — remind-continue not pressed"; exit 1; }
echo "  remind: Continue pressed"

wait_locate_id "price-screen" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — price screen not found after remind Continue"; exit 1; }
echo "  price screen showing"
wait_texts_contain "$FULL_STR" 10 \
  || { echo "E2E PRO-NATIVE: FAIL — quoted full amount $FULL_STR not found on the price screen"; exit 1; }
echo "  price screen quotes the real worker terms: $FULL_STR found"

# ============================================================
# [5] the win-back rung (audit F13): BEFORE any trigger the price
# screen quotes full only; the FIRST ✕ arms the once-per-install rung and
# the price screen re-renders the REAL discount_trial terms from the live
# quote — it does not close.
# ============================================================
echo "== [5] the win-back rung: full first, then the first ✕ swaps in the real discounted terms =="
# The walk below IS the wave's proof — terms that cannot distinguish the
# rungs (launch window: discount == full) cannot exercise it, so that is a
# harness-terms failure, not a skip.
[ "$DISC_MINOR" != "$FULL_MINOR" ] || {
  echo "E2E PRO-NATIVE: FAIL — the local catalog quotes discount == full ($FULL_STR); the win-back walk needs distinguishable rungs"; exit 1; }
if wait_texts_contain "$DISC_STR" 3 2>/dev/null; then
  echo "E2E PRO-NATIVE: FAIL — the discounted amount $DISC_STR is on screen BEFORE any decline trigger"; exit 1
fi
echo "  no discount before any trigger: $DISC_STR absent, full $FULL_STR quoted"

wait_press_id "paywall-close" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — paywall-close (the ✕) not pressed on the price screen"; exit 1; }
echo "  first ✕ pressed"
wait_locate_id "price-screen" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — the price screen closed on the FIRST ✕; it must re-render the discounted terms instead"; exit 1; }
wait_texts_contain "$DISC_STR" 10 \
  || { echo "E2E PRO-NATIVE: FAIL — discounted amount $DISC_STR not on the price screen after the first ✕"; exit 1; }
wait_texts_contain "Same trial, lower price" 5 \
  || { echo "E2E PRO-NATIVE: FAIL — the win-back headline is missing from the discounted render"; exit 1; }
wait_texts_contain "$FULL_STR" 5 \
  || { echo "E2E PRO-NATIVE: FAIL — the struck full price $FULL_STR is missing beside the discounted amount"; exit 1; }
echo "  discounted render confirmed: $DISC_STR quoted, full $FULL_STR struck through, win-back headline present"

WINBACK_STATE=$(HOME="$REAL_HOME" defaults read "$LLMPILOT_DEFAULTS_SUITE" proWinback 2>/dev/null || echo "ABSENT")
[ "$WINBACK_STATE" = "armed" ] \
  || { echo "E2E PRO-NATIVE: FAIL — proWinback should persist as 'armed' after the first ✕ (got: $WINBACK_STATE)"; exit 1; }
echo "  proWinback persisted as armed (once per install — a relaunch neither re-arms nor forgets it)"

# The wave's LOOK artifact: the discounted paywall, captured from the
# sandbox window. Region capture off the window's AX frame; requires the
# invoking terminal's Screen Recording permission — a wallpaper-only image
# fails the human LOOK, not this script.
SHOT="$ROOT/discounted-paywall.png"
WIN_FRAME=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get {position, size} of window \"$WIN_TITLE\"" 2>/dev/null || true)
if [ -n "$WIN_FRAME" ]; then
  R=$(echo "$WIN_FRAME" | awk -F', ' '{printf "%s,%s,%s,%s", $1, $2, $3, $4}')
  screencapture -x -R "$R" "$SHOT" 2>/dev/null || true
fi
if [ -s "$SHOT" ]; then
  if [ -n "${E2E_PRO_SHOT_OUT:-}" ]; then
    cp "$SHOT" "$E2E_PRO_SHOT_OUT" && echo "  discounted-paywall screenshot -> $E2E_PRO_SHOT_OUT"
  else
    echo "  discounted-paywall screenshot captured (set E2E_PRO_SHOT_OUT to keep it)"
  fi
else
  echo "  NOTE: screenshot not captured (no Screen Recording permission?) — the LOOK needs another capture"
fi

# ============================================================
# [6] STOP. checkout-start is located but never pressed. Final safety
# asserts, same shape as scripts/e2e-native-board.sh.
# ============================================================

echo "== [6] STOP — checkout-start located, never pressed =="
CHK=$(osa_locate_id "checkout-start")
case "$CHK" in
  *FOUND*) echo "  checkout-start button located — NOT pressed" ;;
  *) echo "E2E PRO-NATIVE: FAIL — checkout-start not found (cannot confirm the corridor reached the final gate)"; exit 1 ;;
esac

CHECKOUT_WIN=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
case "$CHECKOUT_WIN" in
  *Checkout*) echo "E2E PRO-NATIVE: FAIL — a Checkout sheet window is open though checkout-start was never pressed"; exit 1 ;;
  *) echo "  no Checkout sheet window open — CheckoutSheet.present was never invoked, the system browser was never opened" ;;
esac

# ============================================================
# [7] the second ✕ closes for real — the corridor ends, the board mounts,
# and the persisted rung stays armed (the standing lower price is not
# burned by leaving).
# ============================================================
echo "== [7] second ✕ closes for real =="
wait_press_id "paywall-close" 15 >/dev/null \
  || { echo "E2E PRO-NATIVE: FAIL — paywall-close (the second ✕) not pressed"; exit 1; }
BOARD_UP=""
for _ in $(seq 1 15); do
  case "$(osa_locate_id "fresh-window-menu")" in *FOUND*) BOARD_UP=1; break ;; esac
  sleep 1
done
[ -n "$BOARD_UP" ] || { echo "E2E PRO-NATIVE: FAIL — the board did not mount after the second ✕"; exit 1; }
case "$(osa_locate_id "price-screen")" in
  *FOUND*) echo "E2E PRO-NATIVE: FAIL — price-screen still mounted after the second ✕"; exit 1 ;;
  *) echo "  second ✕ closed the paywall for real — board mounted, price screen gone" ;;
esac
WINBACK_STATE=$(HOME="$REAL_HOME" defaults read "$LLMPILOT_DEFAULTS_SUITE" proWinback 2>/dev/null || echo "ABSENT")
[ "$WINBACK_STATE" = "armed" ] \
  || { echo "E2E PRO-NATIVE: FAIL — proWinback should still read 'armed' after the second ✕ (got: $WINBACK_STATE)"; exit 1; }
echo "  proWinback still armed — the standing lower offer survives the close"

if grep -r "sandbox-token\|refreshToken" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "E2E PRO-NATIVE: FAIL — token material found in LLMPILOT_HOME"; exit 1
fi
echo "  no token material in LLMPILOT_HOME: clean"

# Exact argv[0] match via awk: a regex $BIN would dot-match the developer's
# real /Applications daemon, and a grep in the pipeline matches ITSELF —
# awk's $2 == bin sidesteps both.
MATCHES=$(pgrep -fl "daemon run" | awk -v bin="$BIN" '$2 == bin' || true)
DAEMONS=$(printf '%s' "$MATCHES" | grep -c . || true)
[ "$DAEMONS" = "1" ] || {
  echo "E2E PRO-NATIVE: FAIL — $DAEMONS daemons running, want 1"
  echo "$MATCHES"
  exit 1
}
echo "  exactly one daemon process: $DAEMONS"

if [ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ]; then
  echo "E2E PRO-NATIVE: FAIL — app wrote a LaunchAgent plist"
  exit 1
fi
echo "  no LaunchAgent plist written: clean"

echo "E2E PRO-NATIVE: PASS — zero-account onboarding takeover, education ladder (wall/accounts-skip/switch/windows, blind-spot correctly skipped on <2 identities), the ask (receipt/remind/price quoting \$$FULL_STR), the win-back rung (first ✕ -> real $DISC_STR discount_trial terms, armed persisted, second ✕ closed for real) — checkout never pressed, system browser never opened"
