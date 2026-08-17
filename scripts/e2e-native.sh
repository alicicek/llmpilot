#!/bin/bash
# E2E: native — the demo daemon (LLMPILOT_DEMO=1) serves the masked demo
# fleet from a sandbox-fixed $LLMPILOT_HOME, and the real menu bar app finds
# it there (macos/Sources/API/DaemonClient.swift baseURL() reads
# $LLMPILOT_HOME/daemon.port) and auto-opens the cockpit window with zero
# clicks. Simpler than e2e-firstrun.sh: no keychain FIXTURES, no fixture
# usage server, no login fixtures — the demo daemon needs none of them.
# (The launched app itself still makes one read-only trial-marker probe of
# the data-protection keychain — reportMarkerOnce — which is harmless.)
# Sandboxed per Protocol 10: fake $HOME + fixed LLMPILOT_HOME, LLMPILOT_TEST
# interlock, SMAppService disabled by env, dead-end usage URL, and a
# LLMPILOT_KEYCHAIN that is named but never created (defense — nothing here
# should ever touch a keychain).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-$(pwd)/llmpilot}
go build -o "$BIN" ./cmd/llmpilot

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
ROOT=$(mktemp -d /tmp/llmpilot-e2e-native.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-native.$$"
# Nothing should poll in this run (masked demo fleet, no real accounts) —
# dead-end the usage endpoint so a regression fails fast locally instead of
# sending a sandbox token at the real API.
export LLMPILOT_USAGE_URL="http://127.0.0.1:9"
# Named but never created — the demo daemon touches no Keychain; if
# anything on this path tries, it fails loudly instead of silently.
export LLMPILOT_KEYCHAIN="$ROOT/absent.keychain-db"
# The fixture daemon runs in the foreground — launchd has no role in this
# harness, and launchctl ignores $HOME, so ANY launchctl mutation from the
# app would hit the developer's REAL daemon (DaemonLauncher refuses under
# this flag; e2e-firstrun.sh, which legitimately bootstraps a sandbox
# agent, does NOT set it).
export LLMPILOT_NO_LAUNCHD=1

mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"

# The app writes its first-launch flag via UserDefaults; if cfprefsd routes
# it to the REAL domain despite the $HOME override, restore the pre-run
# state in the trap so your real app is untouched.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
# Same leak, different key (see e2e-native-board.sh for the full story):
# the frame-autosave key is now the REAL app's cockpit frame — a killed run
# must never leave a garbage frame for the developer's own app to inherit.
PRE_FRAME=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || echo "ABSENT")
if [ "$PRE_FRAME" != "ABSENT" ]; then
  HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
fi

# Build the app unless a prebuilt one is supplied. The E2E_XCUI=1 path
# never uses $APP — xcodebuild test builds its own Debug products — so
# skip the Release build there instead of spending minutes on nothing.
APP=${APP:-}
if [ "${E2E_XCUI:-0}" != "1" ]; then
  if [ -z "$APP" ]; then
    HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
      -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
    APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
  fi
  # Ad-hoc builds keep Sparkle's own Team-ID signature on the embedded
  # framework, which library validation rejects — re-sign the bundle
  # consistently for the local run (release CI signs with Developer ID).
  codesign --force --deep -s - "$APP" 2>/dev/null
fi

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  HOME="$REAL_HOME" defaults delete "$LLMPILOT_DEFAULTS_SUITE" 2>/dev/null || true
  # `defaults delete` silently fails on an empty domain and leaves the
  # plist behind (119 piled up before this line existed) — remove it too.
  rm -f "$REAL_HOME/Library/Preferences/$LLMPILOT_DEFAULTS_SUITE.plist" 2>/dev/null || true
  if [ "$PRE_FRAME" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
  else
    HOME="$REAL_HOME" defaults write dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" -string "$PRE_FRAME" 2>/dev/null || true
  fi
  if [ "$PRE_FLAG" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || true
  else
    # Restore means RESTORE: a pre-existing value is written back, not
    # merely left to whatever the run may have overwritten it with. -bool
    # keeps the plist type the app wrote — and only accepts true/false
    # spellings, while `defaults read` prints 1/0, so map explicitly.
    case "$PRE_FLAG" in
      1|true|yes) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool true 2>/dev/null || true ;;
      0|false|no) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool false 2>/dev/null || true ;;
    esac
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ---- start the demo daemon, sandbox-fixed $LLMPILOT_HOME ----
LLMPILOT_DEMO=1 "$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "== demo daemon launched (pid $DAEMON_PID) — waiting for \$LLMPILOT_HOME/daemon.port =="

PORT=""
for _ in $(seq 1 20); do
  if [ -f "$LLMPILOT_HOME/daemon.port" ]; then
    PORT=$(cat "$LLMPILOT_HOME/daemon.port")
    curl -sf "http://127.0.0.1:$PORT/v1/state" >/dev/null 2>&1 && break
    PORT=""
  fi
  sleep 0.5
done
[ -n "$PORT" ] || { echo "E2E NATIVE: FAIL — demo daemon never came up"; tail -20 "$ROOT/daemon.log"; exit 1; }
echo "== demo daemon reachable: /v1/state ok on :$PORT =="

# internal/daemon/demo.go DemoFleet: "returns four fictional accounts".
WANT_ACCOUNTS=4
GOT_ACCOUNTS=$(curl -sf "http://127.0.0.1:$PORT/v1/state" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['accounts']))")
[ "$GOT_ACCOUNTS" = "$WANT_ACCOUNTS" ] || {
  echo "E2E NATIVE: FAIL — /v1/state has $GOT_ACCOUNTS accounts, want the demo fleet's $WANT_ACCOUNTS"; exit 1; }
echo "== demo fleet served: $GOT_ACCOUNTS accounts =="

if [ "${E2E_XCUI:-0}" = "1" ]; then
  # ---- XCUITest smoke: the runner launches the app itself ----
  # The UI-test runner is a separate app spawned by testmanagerd — it
  # inherits NOTHING from this shell; xcodebuild forwards TEST_RUNNER_-
  # prefixed vars to it, and SmokeUITests forwards them on to the app under
  # test (and XCTSkips without them, so it can never touch the real env).
  SANDBOX_HOME="$HOME"
  echo "== XCUITest smoke: launching the app via the llmpilotUITests scheme =="
  HOME="$REAL_HOME" \
    TEST_RUNNER_LLMPILOT_TEST=1 \
    TEST_RUNNER_LLMPILOT_HOME="$LLMPILOT_HOME" \
    TEST_RUNNER_HOME="$SANDBOX_HOME" \
    TEST_RUNNER_CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
    TEST_RUNNER_LLMPILOT_DISABLE_SMAPPSERVICE=1 \
    TEST_RUNNER_LLMPILOT_DEFAULTS_SUITE="$LLMPILOT_DEFAULTS_SUITE" \
    TEST_RUNNER_LLMPILOT_USAGE_URL="$LLMPILOT_USAGE_URL" \
    TEST_RUNNER_LLMPILOT_KEYCHAIN="$LLMPILOT_KEYCHAIN" \
    TEST_RUNNER_LLMPILOT_NO_LAUNCHD=1 \
    xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilotUITests \
    -derivedDataPath "${XCUI_DD:-/tmp/llmpilot-xcui-dd}" test 2>&1 | tail -6 || XCUI_FAIL=1
  # The verdict is deferred until AFTER the negative asserts below: a failed
  # run is exactly when the app may have taken a path those asserts catch,
  # and an early exit would skip them and let cleanup delete the evidence.
  [ "${XCUI_FAIL:-0}" = "0" ] \
    && echo "== XCUITest smoke passed (cockpit window asserted by SmokeUITests) ==" \
    || echo "== XCUITest smoke FAILED — negative asserts still run, verdict at the end =="
else
  # ---- launch the real app inside the sandbox env ----
  "$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
  APP_PID=$!
  echo "== app launched (pid $APP_PID) — waiting for the cockpit window to auto-open =="

  # ---- cockpit window auto-opened (AX assert) ----
  WINDOW=""
  for _ in $(seq 1 30); do
    WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
    case "$WINDOW" in *llmpilot*) break ;; esac
    sleep 1
  done
  case "$WINDOW" in
    *llmpilot*) echo "== cockpit window auto-opened (AX: windows = $WINDOW) ==" ;;
    *) echo "E2E NATIVE: FAIL — no auto-opened window (AX: '$WINDOW')"; exit 1 ;;
  esac
fi

# ---- negative: the app must not have enrolled a login item ----
if [ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ]; then
  echo "E2E NATIVE: FAIL — app wrote a LaunchAgent plist though the daemon was already reachable"
  exit 1
fi
echo "== no LaunchAgent plist written (daemon was reachable-first) =="

# ---- negative: the demo store carries no credential-shaped material ----
# Unlike the sibling scripts this run plants NO credential fixture, so the
# sandbox-token pattern can't fire; the refreshToken pattern is the real
# guard — the daemon writing token material into its store would be a
# regression of the cache-holds-percentages-only rule.
if grep -r "sandbox-token\|refreshToken" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "E2E NATIVE: FAIL — credential material found in LLMPILOT_HOME"; exit 1
fi
echo "== no credential material in LLMPILOT_HOME: clean =="

# ============================================================
# TOUR — chunk 5A's native guided-tour overlay (TourOverlayView.swift). The
# assertions above drove the FIRST-LAUNCH auto-open (which, post-cutover,
# opens this same native window); this section relaunches with a fresh
# tour-unseen suite — same seam/suppression idiom as
# scripts/e2e-native-board.sh — and walks the tour AX-first.
# Skipped under E2E_XCUI: neither sibling native script drives that path
# either, and this section owns its own app process under $APP_PID's
# replacement below rather than the XCUITest runner's.
# ============================================================
if [ "${E2E_XCUI:-0}" != "1" ]; then
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true

  # Suppress the web cockpit's own auto-open (same idiom as e2e-native-
  # board.sh/e2e-native-switch.sh) and switch to the native e2e seam.
  # Deliberately do NOT pre-seed llmpilot.tour.seen — a fresh suite means an
  # unseen tour, and the auto-open under test IS that fresh state.
  HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true
  export LLMPILOT_NATIVE_COCKPIT=1

  "$APP/Contents/MacOS/llmpilot" >"$ROOT/tour-app.log" 2>&1 &
  APP_PID=$!
  echo "== tour: relaunched (pid $APP_PID) for the native window =="

  TOUR_WINDOW=""
  for _ in $(seq 1 30); do
    TOUR_WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
    case "$TOUR_WINDOW" in "llmpilot"|"llmpilot, "*|*", llmpilot"|*", llmpilot, "*) break ;; esac
    sleep 1
  done
  case "$TOUR_WINDOW" in
    "llmpilot"|"llmpilot, "*|*", llmpilot"|*", llmpilot, "*) echo "== tour: native cockpit window open (AX: windows = $TOUR_WINDOW) ==" ;;
    *) echo "E2E NATIVE: FAIL — no native cockpit window for the tour walk (AX: '$TOUR_WINDOW')"; tail -20 "$ROOT/tour-app.log"; exit 1 ;;
  esac

  # <identifier> <action: locate|press|value> — same per-element try/catch
  # walk as e2e-native-board.sh's osa_query (a `whose` clause over `entire
  # contents` is invalid AppleScript, -1700).
  tour_osa() {
    local ident="$1" action="$2"
    osascript <<OSA 2>&1 || true
set out to "NOTFOUND"
with timeout of 60 seconds
try
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    -- NOTE: no backticks anywhere in this heredoc (see the value branch
    -- below) — it is UNQUOTED so bash runs backticks as commands.
    --
    -- Address the window by NAME, same as e2e-native-board.sh's osa_query.
    --
    -- This walk needs the window VISIBLE and not hidden/minimised: a hidden
    -- window still shows up in "name of windows" but is not addressable, so
    -- every lookup here raises -1728 while the outer readiness check above
    -- happily reports the window is open (measured 2026-08-09). That is a
    -- property of the machine the run is on, not of the app -- run these
    -- scripts on an idle Mac and do not hide the window mid-run.
    --
    -- Do NOT "fix" that by swapping in a "whose" filter over windows: a
    -- previous attempt at "item 1 of (every window whose subrole is
    -- AXStandardWindow)" raised -1719, and the blanket try that came with
    -- it turned every fault into a silent NOTFOUND, which is what made the
    -- real cause invisible. The error handler below reports instead.
    set win to window "llmpilot"
    set elems to entire contents of win
    repeat with i from 1 to (count of elems)
      try
        set elem to item i of elems
        if (value of attribute "AXIdentifier" of elem) is "$ident" then
          if "$action" is "locate" then
            set out to "FOUND"
          else if "$action" is "press" then
            perform action "AXPress" of elem
            set out to "PRESSED"
          else if "$action" is "value" then
            -- NOTE: no backticks in this comment block on purpose — this
            -- heredoc is UNQUOTED (needed for ident/action interpolation
            -- above), so bash treats backticks as command substitution.
            -- A plain SwiftUI Text reports its own string through this
            -- generic value property; a custom accessibilityValue set on an
            -- accessibilityElement(children: .contain) GROUP measured
            -- ungettable through System Events despite SwiftUI setting it,
            -- so this reads the identified tour-step Text node instead.
            set out to (value of elem) as string
          end if
          exit repeat
        end if
      end try
    end repeat
  end tell
end tell
on error errMsg number errNum
  -- Report the failure instead of silently reading as NOTFOUND: callers
  -- match on FOUND/PRESSED, so this still behaves as "not found" for
  -- control flow, but a genuine AppleScript fault is visible in the log
  -- rather than indistinguishable from an absent element.
  set out to "OSAERROR " & errNum & " " & errMsg
end try
end timeout
out
OSA
  }
  tour_counter() { tour_osa "tour-step" value; }

  # ---- assert: tour-card auto-opens over the board, zero clicks ----
  COUNTER=""
  for _ in $(seq 1 20); do
    COUNTER=$(tour_counter)
    case "$COUNTER" in "STEP 1 OF"*) break ;; esac
    sleep 1
  done
  case "$COUNTER" in
    "STEP 1 OF"*) echo "== tour: auto-opened, $COUNTER ==" ;;
    *) echo "E2E NATIVE: FAIL — tour-card never auto-opened over the board (last read: '$COUNTER')"; exit 1 ;;
  esac
  # This demo fleet has 4 accounts (asserted above) with one active, so every
  # step's target is on screen — no renumbering, want the full 3 (the tour
  # lost its daemon-pill step with the pill itself; audit F15).
  case "$COUNTER" in "STEP 1 OF 3") : ;; *)
    echo "E2E NATIVE: FAIL — want 'STEP 1 OF 3' on the demo fleet, got '$COUNTER'"; exit 1 ;;
  esac

  # ---- press tour-next through every step, asserting the counter changes ----
  for WANT in "STEP 2 OF 3" "STEP 3 OF 3"; do
    RESULT=$(tour_osa "tour-next" press)
    case "$RESULT" in *PRESSED*) : ;; *)
      echo "E2E NATIVE: FAIL — tour-next AXPress failed (result: $RESULT)"; exit 1 ;;
    esac
    COUNTER=""
    for _ in $(seq 1 10); do
      COUNTER=$(tour_counter)
      [ "$COUNTER" = "$WANT" ] && break
      sleep 1
    done
    [ "$COUNTER" = "$WANT" ] || {
      echo "E2E NATIVE: FAIL — want '$WANT' after Next, got '$COUNTER'"; exit 1; }
    echo "== tour: counter advanced to $COUNTER =="
  done

  # ---- last step: Skip is hidden, the button reads Got it (tour-next is
  # the SAME AXIdentifier for Next/Got it — Tour.tsx has one button, not two)
  RESULT=$(tour_osa "tour-skip" locate)
  case "$RESULT" in
    "FOUND") echo "E2E NATIVE: FAIL — 'Skip the guide' still present on the last step"; exit 1 ;;
    *) echo "== tour: Skip the guide correctly hidden on the last step ==" ;;
  esac

  # ---- press Got it: the overlay must go away ----
  RESULT=$(tour_osa "tour-next" press)
  case "$RESULT" in *PRESSED*) : ;; *)
    echo "E2E NATIVE: FAIL — 'Got it' AXPress failed (result: $RESULT)"; exit 1 ;;
  esac
  GONE=0
  for _ in $(seq 1 10); do
    [ "$(tour_osa "tour-card" locate)" = "NOTFOUND" ] && { GONE=1; break; }
    sleep 1
  done
  [ "$GONE" = "1" ] || { echo "E2E NATIVE: FAIL — tour-card still present after Got it"; exit 1; }
  echo "== tour: overlay gone after Got it =="

  # ---- relaunch-free: tourSeen persisted, so a later launch would not
  # reopen it — read the SAME suite the app just wrote through, rather than
  # spending a third app boot to prove it. UserDefaults -> cfprefsd
  # propagation is asynchronous, so poll like every other assert here.
  SEEN="ABSENT"
  for _ in $(seq 1 10); do
    SEEN=$(HOME="$REAL_HOME" defaults read "$LLMPILOT_DEFAULTS_SUITE" llmpilot.tour.seen 2>/dev/null || echo "ABSENT")
    case "$SEEN" in 1|true|yes) break ;; esac
    sleep 1
  done
  case "$SEEN" in
    1|true|yes) echo "== tour: llmpilot.tour.seen persisted ($SEEN) — will not reopen ==" ;;
    *) echo "E2E NATIVE: FAIL — llmpilot.tour.seen not persisted after dismissal (read: '$SEEN')"; exit 1 ;;
  esac

  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  unset APP_PID
fi

if [ "${XCUI_FAIL:-0}" != "0" ]; then
  echo "E2E NATIVE: FAIL — XCUITest smoke failed (negative asserts above still held)"
  exit 1
fi
echo "E2E NATIVE: PASS — demo daemon + native app, cockpit window auto-opened with zero clicks"
