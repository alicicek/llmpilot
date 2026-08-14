#!/bin/bash
# E2E: native-board — full schedule CRUD (create, move, delete) driven
# through the NATIVE board UI (macos/Sources/Views/Cockpit/Board/) against a
# sandboxed daemon. Same sandbox machinery as scripts/e2e-native-switch.sh:
# fake $HOME + LLMPILOT_HOME, CLAUDE_CONFIG_DIR OUTSIDE the fake home,
# throwaway keychain, LLMPILOT_TEST=1, fixture usage server, two fake logins
# on the global config dir, real daemon, plus the native-app env conventions
# (LLMPILOT_DISABLE_SMAPPSERVICE, throwaway UserDefaults suite with PRE_FLAG
# restore, LLMPILOT_NO_LAUNCHD=1, LLMPILOT_NATIVE_COCKPIT=1 auto-opens the
# native window with zero navigation).
#
# ENTITLEMENT (verified, not assumed — internal/daemon/server.go:1010-1012,
# cmd/llmpilot/wave2.go:398-407, internal/pilot/pilot_pro.go:1 vs
# pilot_free.go:1): schedulingBlocked() only refuses a schedule write when
# d.EntitlementAllowed is non-nil; wave2.go wires EntitlementAllowed ONLY
# when pilot.Get().Available is true, which requires the `pro` build tag
# (linking llmpilot-pro's engine). This script — like every other sandbox
# script in this repo — does a plain `go build` with no `-tags pro`, so
# pilot_free.go's zero Provider is compiled in, EntitlementAllowed stays
# nil, and POST/PUT/DELETE /v1/schedules are unconditionally allowed. The
# launchd mirror (d.TriggerSync) is wired only when LLMPILOT_TEST=="" in
# wave2.go, so under LLMPILOT_TEST=1 it stays nil and syncTriggers()
# (server.go:385-389) no-ops — schedule writes never reach real launchd.
# No special sandbox flag is needed for scheduling beyond what every other
# e2e script already sets.
#
# FIXTURE NOTE: usage-a.json's `limits` array carries an ACTIVE kind
# "session" entry (resets_at 14:32Z) — served as-is it puts a mid-window
# floor (mid.end + 5h) under every lane, and both the clamp physics and the
# resolver then legally clamp moves to that floor. This script serves a
# DERIVED fixture with every limits[].is_active set false, so lanes are
# idle (floor 0) and the CRUD asserts are the plain trigger+15 arithmetic.

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
ROOT=$(mktemp -d /tmp/llmpilot-e2e-native-board.XXXXXX)
export TZ=UTC
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
# The global config dir lives OUTSIDE the redirected $HOME — same reasoning
# as e2e-menubar.sh/e2e-native-switch.sh: the assertSandboxDir interlock
# refuses to swap/keep-warm any dir under the process home.
export CLAUDE_CONFIG_DIR="$ROOT/claude"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"

# ---- native-app conventions (scripts/e2e-native.sh / e2e-native-switch.sh) ----
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-native-board.$$"
# The fixture daemon runs in the foreground under our control; nothing here
# should ever touch launchd.
export LLMPILOT_NO_LAUNCHD=1
# e2e seam: auto-open the native cockpit window with zero navigation.
export LLMPILOT_NATIVE_COCKPIT=1

# The app writes its first-launch flag via UserDefaults; if cfprefsd routes
# it to the REAL domain despite the $HOME override, restore the pre-run
# state in the trap so the real app is untouched.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
# Same leak, different key: NSWindow's frame-autosave (setFrameAutosaveName
# "llmpilot-cockpit", NativeCockpitWindow.swift) also writes through
# cfprefsd to the REAL dev.llmpilot.menubar domain regardless of the
# redirected $HOME (found the hard way — a killed sandbox app leaves
# whatever garbage frame it had mid-run, e.g. a near-zero-height window,
# and the NEXT run inherits it via frame restoration, which then starves
# the board's ScrollView of visible height and drops off-screen lanes out
# of the AX tree). Snapshotted and cleared here so every run starts from
# the coded default (win.center(), 1180x760); restored in the trap so the
# real app's own remembered window position is never touched.
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
  if [ "$PRE_FRAME" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
  else
    HOME="$REAL_HOME" defaults write dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" -string "$PRE_FRAME" 2>/dev/null || true
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

# ---- local fixture usage endpoint (live bars + the mid-window floor) ----
FIXTURE_PORT=18765
# Serve a DERIVED fixture with five_hour nulled: an active mid-window puts a
# non-15-aligned floor (mid.end+5h, from the fixture's fixed 14:32Z
# resets_at) under every lane, and both the clamp physics and the resolver
# then legally teleport moves to that floor — correct product behavior, but
# the gate wants the simple idle-lane CRUD arithmetic (trigger +15).
IDLE_FIXTURE="$ROOT/usage-idle.json"
python3 - testdata/fixtures/usage-a.json "$IDLE_FIXTURE" <<'PYFIX'
import json, sys
d = json.load(open(sys.argv[1]))
# Buckets come from the `limits` array (internal/anthropic/client.go:130
# is_active) — de-activate them all so no lane has a mid-window floor.
for l in d.get("limits") or []:
    l["is_active"] = False
json.dump(d, open(sys.argv[2], "w"))
PYFIX
python3 - "$FIXTURE_PORT" "$IDLE_FIXTURE" <<'PYEOF' &
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
echo "== sandbox live: daemon on $BASE =="

schedules_for() { # <accountID> -> JSON array of that account's schedules
  curl -s "$BASE/v1/schedules" | python3 -c "
import json, sys
scheds = json.load(sys.stdin)
print(json.dumps([s for s in scheds if s['account_id'] == '$1']))
"
}
schedule_count_for() { schedules_for "$1" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"; }

# ---- resolve the target account: a@example.dev ----
TARGET_JSON=$(curl -s "$BASE/v1/state" | python3 -c "
import json, sys
doc = json.load(sys.stdin)
for acct in doc['accounts']:
    if acct['email'] == 'a@example.dev':
        print(json.dumps({'id': acct['id'], 'email': acct['email']}))
        break
")
[ -n "$TARGET_JSON" ] || { echo "E2E NATIVE-BOARD: FAIL — account a@example.dev not found in /v1/state"; exit 1; }
TARGET_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$TARGET_JSON")
echo "== target account: id=$TARGET_ID email=a@example.dev =="

[ "$(schedule_count_for "$TARGET_ID")" = "0" ] || { echo "E2E NATIVE-BOARD: FAIL — target account already has schedules before CREATE"; exit 1; }
echo "  pre-CREATE schedule count for $TARGET_ID: 0"

# ---- suppress the web cockpit auto-open: pre-set the first-launch flag in
# the throwaway suite so ONLY the native window opens. ----
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true
echo "== first-launch flag pre-set in $LLMPILOT_DEFAULTS_SUITE: first-launch auto-open suppressed =="

# ---- suppress the guided-tour auto-open: chunk 5A's NativeCockpitWindow
# opens it the FIRST time the board is visible with accounts (App.tsx:
# 296-299's native twin) — this fleet has accounts, so left alone it would
# steal the AX tree from the CRUD walk below. Pre-seed "seen" the same way
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
  *) echo "E2E NATIVE-BOARD: FAIL — no native cockpit window (AX: '$WINDOW')"; tail -20 "$ROOT/app.log"; exit 1 ;;
esac

frontmost_app() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
}
frontmost_app

# Per-element walk with try/catch — the ONLY reliable AX-identifier search
# (a `whose` clause over `entire contents` is invalid AppleScript, -1700;
# measured: a full walk of this window is ~14s, well inside the retry
# budget). Structured so osascript always EXITS 0 (result rides stdout) —
# under set -e a non-zero exit would silently kill the harness mid-retry.
osa_query() { # <identifier> <action: locate|press>
  local ident="$1" action="$2"
  osascript <<OSA 2>&1 || true
set out to "NOTFOUND"
with timeout of 60 seconds
tell application "System Events"
  set targetProc to first process whose unix id is $APP_PID
  tell targetProc
    set win to window "llmpilot"
    set elems to entire contents of win
    repeat with i from 1 to (count of elems)
      try
        set elem to item i of elems
        if (value of attribute "AXIdentifier" of elem) is "$ident" then
          if "$action" is "locate" then
            set thePos to value of attribute "AXPosition" of elem
            set theSize to value of attribute "AXSize" of elem
            set out to ((item 1 of thePos) as string) & "," & ((item 2 of thePos) as string) & "," & ((item 1 of theSize) as string) & "," & ((item 2 of theSize) as string)
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

osa_locate() { osa_query "$1" locate; }
osa_axpress_ident() { osa_query "$1" press; }

# ============================================================
# CREATE — through the Fresh-window MENU: real menu button + menu item,
# the only AX control class System Events reliably delivers to SwiftUI
# (custom accessibility-action closures are never invoked; coordinate
# clicks cannot reach a locked/backgrounded display — both measured).
# ============================================================
TARGET_LABEL=$(curl -s "$BASE/v1/state" | python3 -c "
import json,sys
for a in json.load(sys.stdin)['accounts']:
    if a['id'] == '$TARGET_ID':
        print(a['label'] or a['email']); break
")
echo "== CREATE via Fresh-window menu, item title: $TARGET_LABEL =="
CREATE_MECHANISM=""
MENU_RESULT=""
for _ in $(seq 1 12); do
MENU_RESULT=$(osascript <<OSA 2>&1 || true
set out to "NOTFOUND"
with timeout of 60 seconds
tell application "System Events"
  tell (first process whose unix id is $APP_PID)
    set win to window "llmpilot"
    set elems to entire contents of win
    repeat with i from 1 to (count of elems)
      try
        set elem to item i of elems
        if (value of attribute "AXIdentifier" of elem) is "fresh-window-menu" then
          perform action "AXPress" of elem
          delay 0.8
          click menu item "$TARGET_LABEL" of menu 1 of elem
          set out to "MENU-CLICKED"
          exit repeat
        end if
      end try
    end repeat
  end tell
end tell
end timeout
out
OSA
)
  case "$MENU_RESULT" in *MENU-CLICKED*) break ;; esac
  sleep 2
done
echo "== Fresh-window menu drive: $MENU_RESULT =="
case "$MENU_RESULT" in
  *MENU-CLICKED*)
    for _ in $(seq 1 15); do
      [ "$(schedule_count_for "$TARGET_ID")" = "1" ] && { CREATE_MECHANISM="Fresh-window menu (AXPress + menu item click)"; break; }
      sleep 1
    done
    ;;
esac
if [ -z "$CREATE_MECHANISM" ]; then
  echo "E2E NATIVE-BOARD: FAIL — Fresh-window menu create produced no schedule (result: $MENU_RESULT)"
  tail -20 "$ROOT/app.log"
  exit 1
fi
echo "== CREATE landed via: $CREATE_MECHANISM =="

SCHED_JSON=$(schedules_for "$TARGET_ID")
SCHED_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[0]['id'])" "$SCHED_JSON")
START_HOUR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[0]['hour'])" "$SCHED_JSON")
START_MIN=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])[0]['minute'])" "$SCHED_JSON")
echo "== CREATE verified: schedule id=$SCHED_ID trigger=$START_HOUR:$START_MIN for $TARGET_ID =="

# ============================================================
# MOVE — the chip is a real Button (select opens the Inspector), then the
# Inspector's "+15" nudge button (also real) moves the schedule.
# ============================================================
CHIP_GEOM=""
for i in $(seq 1 15); do
  CHIP_GEOM=$(osa_locate "chip-$SCHED_ID")
  case "$CHIP_GEOM" in *,*,*,*) break ;; esac
  sleep 1
done
case "$CHIP_GEOM" in
  *,*,*,*) echo "== chip-$SCHED_ID located: $CHIP_GEOM ==" ;;
  *) echo "E2E NATIVE-BOARD: FAIL — chip-$SCHED_ID not found in AX tree"; tail -20 "$ROOT/app.log"; exit 1 ;;
esac
IFS=',' read -r CHX CHY CHW CHH <<<"$CHIP_GEOM"

# MOVE: the chip is a REAL Button now — AXPress selects it (Inspector
# slides in), then the Inspector's "+15" nudge button (also real) moves it.
RESULT=$(osa_axpress_ident "chip-$SCHED_ID")
echo "== chip AXPress (select → Inspector): $RESULT =="
case "$RESULT" in *PRESSED*) : ;; *)
  echo "E2E NATIVE-BOARD: FAIL — chip AXPress failed (result: $RESULT)"; exit 1 ;;
esac
# The Inspector slides in over 0.2s and SwiftUI re-renders — transient
# window-lookup errors (-1728) happen mid-transition, so retry.
RESULT=""
for _ in $(seq 1 10); do
  sleep 1
  RESULT=$(osa_axpress_ident "nudge-plus")
  case "$RESULT" in *PRESSED*) break ;; esac
done
echo "== Inspector +15 nudge AXPress: $RESULT =="
case "$RESULT" in *PRESSED*) : ;; *)
  echo "E2E NATIVE-BOARD: FAIL — nudge-plus not pressed (result: $RESULT — Inspector may not have opened)"; exit 1 ;;
esac

EXPECT_TOTAL=$(( (START_HOUR * 60 + START_MIN + 15) % 1440 ))
MOVED=0
CUR=-1
for _ in $(seq 1 30); do
  CUR=$(schedules_for "$TARGET_ID" | python3 -c "
import json, sys
scheds = json.load(sys.stdin)
m = next((s for s in scheds if s['id'] == '$SCHED_ID'), None)
print(m['hour'] * 60 + m['minute'] if m else -1)
")
  [ "$CUR" = "$EXPECT_TOTAL" ] && { MOVED=1; break; }
  sleep 1
done
[ "$MOVED" = "1" ] || {
  echo "E2E NATIVE-BOARD: FAIL — schedule did not advance by 15min within 30s (want total-minutes=$EXPECT_TOTAL, last seen=$CUR)"
  echo "  raw schedules: $(curl -s "$BASE/v1/schedules")"
  exit 1
}
echo "== MOVE observed: $START_HOUR:$START_MIN -> total-minutes=$EXPECT_TOTAL (via Inspector +15 nudge) =="

# ============================================================
# DELETE: the Inspector is still open on this schedule — its "Remove
# reset" is a real Button.
RESULT=""
for _ in $(seq 1 10); do
  RESULT=$(osa_axpress_ident "inspector-remove")
  case "$RESULT" in *PRESSED*) break ;; esac
  sleep 1
done
echo "== Inspector Remove-reset AXPress: $RESULT =="
case "$RESULT" in *PRESSED*) : ;; *)
  echo "E2E NATIVE-BOARD: FAIL — inspector-remove not pressed (result: $RESULT)"; exit 1 ;;
esac

DELETED=0
for _ in $(seq 1 30); do
  [ "$(schedule_count_for "$TARGET_ID")" = "0" ] && { DELETED=1; break; }
  sleep 1
done
[ "$DELETED" = "1" ] || { echo "E2E NATIVE-BOARD: FAIL — schedule not deleted within 30s"; exit 1; }
echo "== DELETE observed: $TARGET_ID has 0 schedules =="

# ---- assert: no token material leaked into LLMPILOT_HOME ----
if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "  no token material in LLMPILOT_HOME: clean"

# ---- assert: exactly one daemon process ----
# Exact argv[0] match via awk: a regex $BIN would dot-match the developer's
# real /Applications daemon, and a grep in the pipeline matches ITSELF —
# awk's $2 == bin sidesteps both.
MATCHES=$(pgrep -fl "daemon run" | awk -v bin="$BIN" '$2 == bin' || true)
DAEMONS=$(printf '%s' "$MATCHES" | grep -c . || true)
[ "$DAEMONS" = "1" ] || {
  echo "E2E NATIVE-BOARD: FAIL — $DAEMONS daemons running, want 1"
  echo "$MATCHES"
  exit 1
}
echo "  exactly one daemon process: $DAEMONS"

# ---- assert: the app must not have enrolled a LaunchAgent ----
if [ -f "$HOME/Library/LaunchAgents/dev.llmpilot.daemon.plist" ]; then
  echo "E2E NATIVE-BOARD: FAIL — app wrote a LaunchAgent plist"
  exit 1
fi
echo "  no LaunchAgent plist written: clean"

echo "E2E NATIVE-BOARD: PASS — AX-driven create/move/delete through the native board (menu create, chip-button select, Inspector nudge/remove)"
