#!/bin/bash
# E2E: first-run — a fresh install onboards itself. Launching the app
# with NO daemon, NO LaunchAgent, and NO $LLMPILOT_HOME must bring the
# daemon up with zero clicks, auto-open the cockpit window exactly once
# (adopt screen visible), and a relaunch must NOT auto-open again.
# Sandboxed per Protocol 10: fake $HOME + LLMPILOT_HOME, throwaway
# keychain, LLMPILOT_TEST interlock. SMAppService is disabled by env —
# BTM rejects ad-hoc builds anyway, and a sandbox run must never enroll a
# real login item; the automated proof exercises the legacy-fallback +
# interlock paths (the SMAppService happy path needs a manual demo).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-$(pwd)/llmpilot}
go build -o "$BIN" ./cmd/llmpilot

REAL_HOME="$HOME"
UID_N=$(id -u)
ROOT=$(mktemp -d /tmp/llmpilot-e2e-firstrun.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home" # NOT created — fresh install
export HOME="$ROOT/home"
export CLAUDE_CONFIG_DIR="$ROOT/home/claude-main"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
export LLMPILOT_BIN="$BIN"
export LLMPILOT_DISABLE_SMAPPSERVICE=1
# cfprefsd keys UserDefaults by uid + bundle id and ignores $HOME — the
# first-launch flag rides a throwaway suite, deleted in the trap.
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-firstrun.$$"
# Nothing should poll in this test (no adopted accounts) — dead-end the
# usage endpoint so a regression fails fast locally instead of sending a
# sandbox token at the real API.
export LLMPILOT_USAGE_URL="http://127.0.0.1:9"

# The app writes its first-launch flag via UserDefaults; if cfprefsd routes
# it to the REAL domain despite the $HOME override, restore the pre-run
# state in the trap so your real app is untouched.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")

mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"

# Build the app unless a prebuilt one is supplied.
APP=${APP:-}
if [ -z "$APP" ]; then
  HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
    -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
  APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
fi
codesign --force --deep -s - "$APP" 2>/dev/null

SANDBOX_BOOTSTRAPPED=0
cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  # Bootout ONLY the agent this run bootstrapped: the label is shared with a
  # real install, and the precondition-refusal path must never tear down your
  # live daemon.
  if [ "$SANDBOX_BOOTSTRAPPED" = "1" ]; then
    /bin/launchctl bootout "gui/$UID_N/dev.llmpilot.daemon" 2>/dev/null || true
  fi
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  HOME="$REAL_HOME" defaults delete "$LLMPILOT_DEFAULTS_SUITE" 2>/dev/null || true
  if [ "$PRE_FLAG" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

# One fake logged-in Claude account so the adopt screen has a candidate.
SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"
echo '{"oauthAccount": {"accountUuid": "uuid-a", "emailAddress": "a@example.dev"}}' >"$CLAUDE_CONFIG_DIR/.claude.json"
CRED='{"claudeAiOauth":{"accessToken":"sandbox-token-a","refreshToken":"sandbox-refresh-a","expiresAt":4102444800000}}'
/usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" \
  -X "$(printf '%s' "$CRED" | xxd -p | tr -d '\n')" "$KEYCHAIN"

# Preconditions: nothing is running, nothing is installed.
[ -d "$LLMPILOT_HOME" ] && { echo "PRECONDITION FAIL: LLMPILOT_HOME exists"; exit 1; }
[ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ] && { echo "PRECONDITION FAIL: plist exists"; exit 1; }
/bin/launchctl print "gui/$UID_N/dev.llmpilot.daemon" >/dev/null 2>&1 && {
  echo "PRECONDITION FAIL: dev.llmpilot.daemon already loaded in gui domain"; exit 1; }
echo "== preconditions: no daemon, no LaunchAgent, no \$LLMPILOT_HOME =="

# ---- first launch: zero clicks ----
T0=$(date +%s)
"$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
echo "== app launched (pid $APP_PID) — waiting for the daemon with NO click =="

PORT=""
for _ in $(seq 1 120); do
  if [ -f "$LLMPILOT_HOME/daemon.port" ]; then
    PORT=$(cat "$LLMPILOT_HOME/daemon.port")
    curl -sf "http://127.0.0.1:$PORT/v1/state" >/dev/null 2>&1 && break
    PORT=""
  fi
  sleep 0.5
done
[ -n "$PORT" ] || { echo "E2E FIRSTRUN: FAIL — daemon never came up"; tail -20 "$ROOT/app.log"; exit 1; }
ELAPSED=$(( $(date +%s) - T0 ))
echo "== daemon reachable with no click: /v1/state ok on :$PORT after ${ELAPSED}s =="

# The app's own start path used the legacy route (SMAppService disabled).
[ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ] \
  && echo "== legacy fallback used: sandbox plist written + bootstrapped ==" \
  || { echo "E2E FIRSTRUN: FAIL — no sandbox plist"; exit 1; }
SANDBOX_BOOTSTRAPPED=1

# ---- cockpit window auto-opened (AX assert) ----
WINDOW=""
for _ in $(seq 1 30); do
  WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
  case "$WINDOW" in *llmpilot*) break ;; esac
  sleep 1
done
case "$WINDOW" in
  *llmpilot*) echo "== cockpit window auto-opened (AX: windows = $WINDOW) ==" ;;
  *) echo "E2E FIRSTRUN: FAIL — no auto-opened window (AX: '$WINDOW')"; exit 1 ;;
esac

# ---- adopt screen visible (AX text inside the web view) ----
# WKWebView only builds its AX tree for assistive clients — force it with
# AXEnhancedUserInterface, then walk entire contents for static texts.
osascript -e "tell application \"System Events\" to set value of attribute \"AXEnhancedUserInterface\" of (first process whose unix id is $APP_PID) to true" 2>/dev/null || true
WEBAREA="UI element 1 of scroll area 1 of group 1 of group 1 of window 1"
ADOPT=""
for _ in $(seq 1 30); do
  for Q in \
    "get name of every UI element of $WEBAREA whose role is \"AXHeading\"" \
    "get name of (every UI element of UI element 2 of $WEBAREA whose role is \"AXHeading\")"; do
    ADOPT=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to $Q" 2>/dev/null || true)
    case "$ADOPT" in *"Adopt your accounts"*) break 2 ;; esac
  done
  sleep 1
done
case "$ADOPT" in
  *"Adopt your accounts"*) echo "== adopt screen visible in the auto-opened window ==" ;;
  *) echo "E2E FIRSTRUN: FAIL — adopt screen not visible over AX"; exit 1 ;;
esac

# ---- single instance, already-live class, real binary ----
SECOND_OUT=$("$BIN" daemon run 2>&1) && SECOND_EXIT=0 || SECOND_EXIT=$?
[ $SECOND_EXIT -eq 0 ] || { echo "E2E FIRSTRUN: FAIL — second daemon run exited $SECOND_EXIT"; exit 1; }
case "$SECOND_OUT" in
  *"already running"*) echo "== single-instance (already-live): second daemon run exited 0: '$SECOND_OUT' ==" ;;
  *) echo "E2E FIRSTRUN: FAIL — unexpected second-run output: $SECOND_OUT"; exit 1 ;;
esac
curl -sf "http://127.0.0.1:$PORT/v1/state" >/dev/null || { echo "E2E FIRSTRUN: FAIL — first daemon lost its socket"; exit 1; }
DAEMONS=$(pgrep -f "$BIN daemon run" | wc -l | tr -d ' ')
[ "$DAEMONS" = "1" ] || { echo "E2E FIRSTRUN: FAIL — $DAEMONS daemons running, want 1"; exit 1; }
echo "== exactly ONE daemon process (legacy-fallback path): $DAEMONS =="

# ---- relaunch: the window must NOT auto-open again ----
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null || true
sleep 1
"$APP/Contents/MacOS/llmpilot" >"$ROOT/app2.log" 2>&1 &
APP_PID=$!
sleep 8
WINDOWS2=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || echo "")
if [ -n "$WINDOWS2" ]; then
  echo "E2E FIRSTRUN: FAIL — relaunch auto-opened a window ($WINDOWS2)"; exit 1
fi
# …and the relaunched app sees the SAME single daemon (reachable-first path).
DAEMONS2=$(pgrep -f "$BIN daemon run" | wc -l | tr -d ' ')
[ "$DAEMONS2" = "1" ] || { echo "E2E FIRSTRUN: FAIL — $DAEMONS2 daemons after relaunch"; exit 1; }
echo "== relaunch: no auto-open (windows: none), still exactly one daemon =="

if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "== no token material in LLMPILOT_HOME: clean =="
echo "E2E FIRSTRUN: PASS — fresh install onboarded itself with zero clicks"
