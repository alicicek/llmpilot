#!/bin/bash
# E2E: native-switch — the e2e-menubar.sh sandbox + assertion set, but the
# human click on the menu bar popover is replaced by osascript AX
# automation clicking the switch button inside the NATIVE cockpit window
# (the native-cockpit preview surface, opted into via LLMPILOT_NATIVE_-
# COCKPIT=1 — macos/Sources/LLMPilotApp.swift). Sandboxed per Protocol 10:
# fake $HOME + LLMPILOT_HOME, CLAUDE_CONFIG_DIR OUTSIDE the fake home,
# throwaway keychain, LLMPILOT_TEST=1, fixture usage server, two fake
# logins on the global config dir, real daemon — identical to
# scripts/e2e-menubar.sh — plus the native-app env conventions from
# scripts/e2e-native.sh (LLMPILOT_DISABLE_SMAPPSERVICE, throwaway
# UserDefaults suite with PRE_FLAG restore, LLMPILOT_NO_LAUNCHD).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
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
ROOT=$(mktemp -d /tmp/llmpilot-e2e-native-switch.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
# The global config dir lives OUTSIDE the redirected $HOME — same reasoning
# as e2e-menubar.sh: the assertSandboxDir interlock refuses to swap/keep-warm
# any dir under the process home, and a redirected HOME makes a home-nested
# fixture dir self-refusing.
export CLAUDE_CONFIG_DIR="$ROOT/claude"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"

# ---- native-app conventions (scripts/e2e-native.sh) ----
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-native-switch.$$"
# The fixture daemon runs in the foreground under our control; nothing here
# should ever touch launchd — the same reasoning as e2e-native.sh.
export LLMPILOT_NO_LAUNCHD=1
# e2e seam: auto-open the native cockpit window with zero navigation.
export LLMPILOT_NATIVE_COCKPIT=1

# The app writes its first-launch flag via UserDefaults; if cfprefsd routes
# it to the REAL domain despite the $HOME override, restore the pre-run
# state in the trap so the real app is untouched.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
# Frame-autosave leaks through cfprefsd to the REAL domain too (see
# e2e-native-board.sh) — and the key is now the real app's cockpit frame.
PRE_FRAME=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || echo "ABSENT")
if [ "$PRE_FRAME" != "ABSENT" ]; then
  HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
fi

# Build the app unless a prebuilt one is supplied.
APP=${APP:-}
if [ -z "$APP" ]; then
  HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
    -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
  APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
fi
# Ad-hoc builds keep Sparkle's own Team-ID signature on the embedded
# framework, which library validation rejects — re-sign the bundle
# consistently for the local run (release CI signs with Developer ID).
codesign --force --deep -s - "$APP" 2>/dev/null

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${FIXTURE_PID:-}" ] && kill "$FIXTURE_PID" 2>/dev/null || true
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
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
    # only accepts true/false spellings, while `defaults read` prints 1/0,
    # so map explicitly.
    case "$PRE_FLAG" in
      1|true|yes) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool true 2>/dev/null || true ;;
      0|false|no) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool false 2>/dev/null || true ;;
    esac
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ---- two fake logged-in accounts, BOTH on the global config dir ----
mkdir -p "$CLAUDE_CONFIG_DIR" "$LLMPILOT_HOME" "$HOME"
SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"

/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"
login_global() { # <uuid> <email> <tag> — the global dir is now logged into this account
  echo "{\"oauthAccount\": {\"accountUuid\": \"$1\", \"emailAddress\": \"$2\"}}" >"$CLAUDE_CONFIG_DIR/.claude.json"
  cred="{\"claudeAiOauth\":{\"accessToken\":\"sandbox-token-$3\",\"refreshToken\":\"sandbox-refresh-$3\",\"expiresAt\":4102444800000}}"
  /usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" \
    -X "$(printf '%s' "$cred" | xxd -p | tr -d '\n')" "$KEYCHAIN"
}

# ---- local fixture usage endpoint (live bars in the native window) ----
FIXTURE_PORT=18742
python3 - "$FIXTURE_PORT" testdata/fixtures/usage-a.json <<'PYEOF' &
import http.server, json, sys
port, path = int(sys.argv[1]), sys.argv[2]
body = open(path, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PYEOF
FIXTURE_PID=$!
disown # bash job-control would otherwise print a "Terminated" notice on
       # trap kill, landing after the final PASS/FAIL line
export LLMPILOT_USAGE_URL="http://127.0.0.1:$FIXTURE_PORT"
sleep 0.3

# ---- register the fake fleet (two logins in sequence), start the daemon ----
login_global uuid-b b@example.dev b
"$BIN" init
login_global uuid-a a@example.dev a
"$BIN" init
"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
disown
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
sleep 1 # first poll writes snapshots
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
BASE="http://127.0.0.1:$PORT"

active_id() {
  curl -s "$BASE/v1/state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active_id',''))"
}
show_oauth() {
  python3 -c "import json; print('  oauthAccount:', json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))['oauthAccount']['emailAddress'])"
}

BEFORE=$(active_id)
echo "== sandbox live: daemon on $BASE · active: $BEFORE =="
show_oauth

# ---- determine the switch target: the OTHER account in /v1/state ----
TARGET_JSON=$(curl -s "$BASE/v1/state" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
before = doc.get('active_id', '')
for acct in doc['accounts']:
    if acct['id'] != before:
        print(json.dumps({'id': acct['id'], 'email': acct['email']}))
        break
")
[ -n "$TARGET_JSON" ] || { echo "E2E NATIVE-SWITCH: FAIL — no non-active account found in /v1/state"; exit 1; }
TARGET_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$TARGET_JSON")
TARGET_EMAIL=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['email'])" "$TARGET_JSON")
echo "== switch target: id=$TARGET_ID email=$TARGET_EMAIL =="

# ---- suppress the web cockpit auto-open: pre-set the first-launch flag in
# the throwaway suite so ONLY the native window opens (FleetViewModel.-
# firstLaunchKey; cfprefsd keys UserDefaults by uid + bundle id and ignores
# a sandboxed $HOME, so this must use the REAL home like the trap does). ----
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true
echo "== first-launch flag pre-set in $LLMPILOT_DEFAULTS_SUITE: first-launch auto-open suppressed =="

# ---- suppress the guided-tour auto-open: chunk 5A's NativeCockpitWindow
# opens it the FIRST time the board is visible with accounts (App.tsx:
# 296-299's native twin) — this fleet has accounts, so left alone it would
# steal the AX tree from the switch walk below. Pre-seed "seen" the same way
# firstLaunchWindowShown is suppressed above. ----
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" llmpilot.tour.seen -bool true
echo "== tour-seen flag pre-set in $LLMPILOT_DEFAULTS_SUITE: guided tour suppressed =="

# ---- launch the real app inside the sandbox env ----
"$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
disown
echo "== app launched (pid $APP_PID) — waiting for the native cockpit window =="

# ---- native cockpit window opened (AX assert) ----
WINDOW=""
for _ in $(seq 1 30); do
  WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
  case "$WINDOW" in "llmpilot"|"llmpilot, "*|*", llmpilot"|*", llmpilot, "*) break ;; esac
  sleep 1
done
case "$WINDOW" in
  "llmpilot"|"llmpilot, "*|*", llmpilot"|*", llmpilot, "*) echo "== native cockpit window open (AX: windows = $WINDOW) ==" ;;
  *) echo "E2E NATIVE-SWITCH: FAIL — no native cockpit window (AX: '$WINDOW')"; tail -20 "$ROOT/app.log"; exit 1 ;;
esac

# ---- click the switch button via AX automation ----
# SwiftUI builds its AX tree lazily — retry the locate+press. AXPress does
# not require on-screen visibility, so no scrolling is attempted first.
osa_axpress() {
  osascript <<OSA 2>&1
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    set win to window "llmpilot"
    set theElems to entire contents of win
    repeat with elem in theElems
      try
        if (value of attribute "AXIdentifier" of elem) is "switch-$TARGET_ID" then
          perform action "AXPress" of elem
          return "PRESSED"
        end if
      end try
    end repeat
  end tell
end tell
return "NOTFOUND"
OSA
}

osa_click() {
  osascript <<OSA 2>&1
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    set win to window "llmpilot"
    set theElems to entire contents of win
    repeat with elem in theElems
      try
        if (value of attribute "AXIdentifier" of elem) is "switch-$TARGET_ID" then
          click elem
          return "CLICKED"
        end if
      end try
    end repeat
  end tell
end tell
return "NOTFOUND"
OSA
}

osa_coord_click() {
  osascript <<OSA 2>&1
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    set win to window "llmpilot"
    set theElems to entire contents of win
    repeat with elem in theElems
      try
        if (value of attribute "AXIdentifier" of elem) is "switch-$TARGET_ID" then
          set thePos to value of attribute "AXPosition" of elem
          set theSize to value of attribute "AXSize" of elem
          set cx to (item 1 of thePos) + ((item 1 of theSize) / 2)
          set cy to (item 2 of thePos) + ((item 2 of theSize) / 2)
          click at {cx, cy}
          return "COORD-CLICKED"
        end if
      end try
    end repeat
  end tell
end tell
return "NOTFOUND"
OSA
}

MECHANISM=""
RESULT=""
for i in $(seq 1 10); do
  RESULT=$(osa_axpress)
  echo "== AXPress attempt $i: $RESULT =="
  case "$RESULT" in *PRESSED*) MECHANISM="AXPress"; break ;; esac
  sleep 1
done

if [ "$MECHANISM" != "AXPress" ]; then
  echo "== AXPress never landed — falling back to click() ==" >&2
  for i in $(seq 1 3); do
    RESULT=$(osa_click)
    echo "== click() attempt $i: $RESULT =="
    case "$RESULT" in *CLICKED*) MECHANISM="click"; break ;; esac
    sleep 1
  done
fi

if [ "$MECHANISM" != "AXPress" ] && [ "$MECHANISM" != "click" ]; then
  echo "== click() never landed — falling back to coordinate click via AXPosition/AXSize ==" >&2
  for i in $(seq 1 3); do
    RESULT=$(osa_coord_click)
    echo "== coord-click attempt $i: $RESULT =="
    case "$RESULT" in *COORD-CLICKED*) MECHANISM="coordinate"; break ;; esac
    sleep 1
  done
fi

if [ -z "$MECHANISM" ]; then
  echo "E2E NATIVE-SWITCH: FAIL — no click mechanism landed on switch-$TARGET_ID (last result: $RESULT)"
  exit 1
fi
echo "== switch button pressed via: $MECHANISM =="

# ---- assert: active_id flips to TARGET_ID within 60s ----
NOW="$BEFORE"
for _ in $(seq 1 60); do
  NOW=$(active_id)
  [ "$NOW" = "$TARGET_ID" ] && break
  sleep 1
done
if [ "$NOW" != "$TARGET_ID" ]; then
  echo "E2E NATIVE-SWITCH: FAIL — active_id did not flip to $TARGET_ID within 60s (last seen: $NOW)"
  exit 1
fi
echo "== switch observed: $BEFORE -> $NOW =="

# ---- assert: oauthAccount spliced to the target's email ----
show_oauth
python3 -c "
import json
doc = json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))
assert doc['oauthAccount']['emailAddress'] == '$TARGET_EMAIL', doc
print('  oauthAccount splice: OK')
"

# ---- assert: no token material leaked into LLMPILOT_HOME ----
if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "  no token material in LLMPILOT_HOME: clean"

# ---- assert: exactly one daemon process ----
# Exact argv[0] match via awk: a regex $BIN would dot-match the developer's
# real /Applications daemon, and a grep in the pipeline matches ITSELF
# (its own args contain "daemon run") — awk's $2 == bin sidesteps both.
MATCHES=$(pgrep -fl "daemon run" | awk -v bin="$BIN" '$2 == bin' || true)
DAEMONS=$(printf '%s' "$MATCHES" | grep -c . || true)
[ "$DAEMONS" = "1" ] || {
  echo "E2E NATIVE-SWITCH: FAIL — $DAEMONS daemons running, want 1"
  echo "$MATCHES"
  exit 1
}
echo "  exactly one daemon process: $DAEMONS"

# ---- assert: the app must not have enrolled a LaunchAgent ----
if [ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ]; then
  echo "E2E NATIVE-SWITCH: FAIL — app wrote a LaunchAgent plist"
  exit 1
fi
echo "  no LaunchAgent plist written: clean"

echo "E2E NATIVE-SWITCH: PASS — AX-driven click-switch in the native cockpit performed a sandboxed swap end-to-end ($MECHANISM)"
