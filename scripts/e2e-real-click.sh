#!/bin/bash
# E2E: real-click — REAL mouse clicks (CGEvent through the HID tap, the way a
# human's mouse arrives) on the native cockpit, asserting the actions fired.
#
# WHY THIS EXISTS (audit 2026-08-16 F18, root-caused 2026-08-17): every other
# native e2e drives the cockpit through accessibility (AXPress / named AX
# actions), which bypasses AppKit's mouse-event routing entirely. 1.3.0
# shipped a window where the FIRST board-track click threw an Objective-C
# exception out of the tick-sound path (BoardAudio: AVAudioEngine.start() on
# an empty graph, macOS 26.5) inside SwiftUI's gesture dispatch — leaving the
# window's gesture environment holding a never-reset recognizer, so every
# later SwiftUI click was dead while hover, NSMenus and window chrome kept
# working. The AX suites all passed. This gate is the one that would have
# caught it: click the track for real, then click ⚙ for real, and require
# the Settings sheet to actually open.
#
# Sandbox: identical to scripts/e2e-native.sh (demo daemon LLMPILOT_DEMO=1,
# fake $HOME + fixed LLMPILOT_HOME, LLMPILOT_TEST interlock, SMAppService
# and launchd mutation disabled, throwaway defaults suite, dead-end usage
# URL, keychain named but never created). No `-tags pro`, so schedule
# writes are unconditionally allowed (see e2e-native-board.sh's ENTITLEMENT
# note) — a real track click on an empty lane MUST land a schedule.
#
# MACHINE REQUIREMENT: this run posts real clicks, so the cockpit window
# must be on top and unobstructed at the click points; the script activates
# the app and REFUSES (fails loudly) if another app's window owns the pixel
# — never click into whatever else is on screen. Run it on an idle Mac.
#
# PERMISSION: posting to the HID event tap needs Accessibility (or Input
# Monitoring) permission for the TERMINAL you run this from — System
# Settings > Privacy & Security > Accessibility. Without it macOS drops the
# events silently and realclick still exits 0, so the assertions below fail
# as though the app were click-dead. Grant it before believing a failure.
#
# APP=/path/to/llmpilot.app skips the source build (used to prove the fail
# case against the shipped 1.3.0 bundle: it must FAIL there).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-$(pwd)/llmpilot}
go build -o "$BIN" ./cmd/llmpilot

STRAY_LLMPILOT=$(pgrep -f "llmpilot\.app/Contents/MacOS/llmpilot" 2>/dev/null || true)
if [ -n "$STRAY_LLMPILOT" ]; then
  echo "E2E REAL-CLICK: FAIL -- another llmpilot app process is already running (pids: $(echo $STRAY_LLMPILOT | tr '\n' ' ')). Quit it and re-run."
  exit 1
fi

REAL_HOME="$HOME"
ROOT=$(mktemp -d /tmp/llmpilot-e2e-real-click.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-real-click.$$"
export LLMPILOT_USAGE_URL="http://127.0.0.1:9"
export LLMPILOT_KEYCHAIN="$ROOT/absent.keychain-db"
export LLMPILOT_NO_LAUNCHD=1
export LLMPILOT_NATIVE_COCKPIT=1
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"

PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
PRE_FRAME=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || echo "ABSENT")
if [ "$PRE_FRAME" != "ABSENT" ]; then
  HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
fi

# ---- the two click tools (Swift, compiled per run — no binaries in git) ----
mkdir -p "$ROOT/tools"
HOME="$REAL_HOME" swiftc -O -o "$ROOT/tools/realclick" scripts/tools/realclick.swift 2>/dev/null
HOME="$REAL_HOME" swiftc -O -o "$ROOT/tools/topwin" scripts/tools/topwin.swift 2>/dev/null
REALCLICK="$ROOT/tools/realclick"; TOPWIN="$ROOT/tools/topwin"

APP=${APP:-}
if [ -z "$APP" ]; then
  HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
    -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
  APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
  codesign --force --deep -s - "$APP" 2>/dev/null
fi
echo "== app under test: $APP =="

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  HOME="$REAL_HOME" defaults delete "$LLMPILOT_DEFAULTS_SUITE" 2>/dev/null || true
  rm -f "$REAL_HOME/Library/Preferences/$LLMPILOT_DEFAULTS_SUITE.plist" 2>/dev/null || true
  if [ "$PRE_FRAME" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
  else
    HOME="$REAL_HOME" defaults write dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" -string "$PRE_FRAME" 2>/dev/null || true
  fi
  if [ "$PRE_FLAG" = "ABSENT" ]; then
    HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || true
  else
    case "$PRE_FLAG" in
      1|true|yes) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool true 2>/dev/null || true ;;
      0|false|no) HOME="$REAL_HOME" defaults write dev.llmpilot.menubar firstLaunchWindowShown -bool false 2>/dev/null || true ;;
    esac
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ---- demo daemon ----
LLMPILOT_DEMO=1 "$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
disown
PORT=""
for _ in $(seq 1 20); do
  if [ -f "$LLMPILOT_HOME/daemon.port" ]; then
    PORT=$(cat "$LLMPILOT_HOME/daemon.port")
    curl -sf "http://127.0.0.1:$PORT/v1/state" >/dev/null 2>&1 && break
    PORT=""
  fi
  sleep 0.5
done
[ -n "$PORT" ] || { echo "E2E REAL-CLICK: FAIL — demo daemon never came up"; tail -20 "$ROOT/daemon.log"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "== demo daemon reachable on :$PORT =="

count_for() { # <accountID> -> number of that account's schedules
  curl -s "$BASE/v1/schedules" | python3 -c "import json,sys; print(len([s for s in json.load(sys.stdin) if s['account_id']=='$1']))"
}
# theo: no schedules, no active session bucket → floor 0 → any hour books.
TARGET=theo
[ "$(count_for $TARGET)" = "0" ] || { echo "E2E REAL-CLICK: FAIL — $TARGET already has schedules"; exit 1; }

# first-launch auto-open + guided tour suppressed (same idiom as the siblings)
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" llmpilot.tour.seen -bool true

"$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
disown # no "Terminated" job notice after the trap's kill
echo "== app launched (pid $APP_PID) — waiting for the native cockpit window =="
WINDOW=""
for _ in $(seq 1 30); do
  WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
  case "$WINDOW" in *llmpilot*) break ;; esac
  sleep 1
done
case "$WINDOW" in *llmpilot*) ;; *) echo "E2E REAL-CLICK: FAIL — no cockpit window (AX: '$WINDOW')"; tail -20 "$ROOT/app.log"; exit 1 ;; esac
# Bring it to the front and give it room: real clicks land on whatever is
# on top, and the demo fleet's four lanes must all be INSIDE the window (a
# lane below the bottom edge is not the app's pixel — it is whatever sits
# behind the window). 1180x1000 is the cockpit default width at a height
# that shows every demo lane on a 13" display.
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to tell window \"llmpilot\" to set {position, size} to {{40, 40}, {1180, 1000}}" >/dev/null 2>&1 || true
sleep 1.5
WIN_FRAME=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to tell window \"llmpilot\" to get {position, size}" 2>/dev/null | tr -d ' ')
echo "== cockpit window frame (x,y,w,h): $WIN_FRAME =="
inside_window() { # <x> <y> -> 0 if the point is inside the cockpit window
  python3 - "$WIN_FRAME" "$1" "$2" <<'PY'
import sys
x0,y0,w,h=[float(v) for v in sys.argv[1].split(",")]
x,y=float(sys.argv[2]),float(sys.argv[3])
sys.exit(0 if (x0<=x<x0+w and y0<=y<y0+h) else 1)
PY
}

# <identifier-prefix> -> "x, y, w, h" of the first element carrying it
ax_frame_by_id() {
  osascript <<OSA 2>/dev/null
with timeout of 60 seconds
tell application "System Events" to tell (first process whose unix id is $APP_PID) to tell window "llmpilot"
  set gs to (entire contents)
  repeat with g in gs
    try
      set idv to value of attribute "AXIdentifier" of g
      if idv starts with "$1" then
        set p to position of g
        set s to size of g
        return ((item 1 of p) as text) & ", " & ((item 2 of p) as text) & ", " & ((item 1 of s) as text) & ", " & ((item 2 of s) as text)
      end if
    end try
  end repeat
  return "NOTFOUND"
end tell
end timeout
OSA
}
sheets() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get count of sheets of window \"llmpilot\"" 2>/dev/null || echo "?"; }

# Only click when llmpilot owns the pixel — anything else is a covered
# window, which is a property of the desktop, not of the app.
click_checked() { # <x> <y> <what>
  inside_window "$1" "$2" || { echo "E2E REAL-CLICK: FAIL — $3 at $1,$2 lies outside the cockpit window ($WIN_FRAME); the target is not visible"; exit 1; }
  local owner; owner=$("$TOPWIN" "$1" "$2")
  case "$owner" in
    "llmpilot pid=$APP_PID "*) ;;
    *) echo "E2E REAL-CLICK: FAIL — cannot click $3 at $1,$2: pixel owned by '$owner' (cockpit covered or off-screen). Run on an idle Mac with the cockpit unobstructed."; exit 1 ;;
  esac
  "$REALCLICK" "$1" "$2" --move >/dev/null; sleep 0.4
  "$REALCLICK" "$1" "$2" >/dev/null
}

TRACK=$(ax_frame_by_id "track-$TARGET")
[ "$TRACK" != "NOTFOUND" ] && [ -n "$TRACK" ] || { echo "E2E REAL-CLICK: FAIL — track-$TARGET not in the AX tree"; exit 1; }
TX=$(echo "$TRACK" | cut -d, -f1 | tr -d ' '); TY=$(echo "$TRACK" | cut -d, -f2 | tr -d ' ')
TW=$(echo "$TRACK" | cut -d, -f3 | tr -d ' '); TH=$(echo "$TRACK" | cut -d, -f4 | tr -d ' ')
# 3/4 along the day (~18:00) and mid-height: legal on an idle lane.
CX=$(python3 -c "print(int($TX + $TW*0.75))"); CY=$(python3 -c "print(int($TY + $TH/2))")
GEAR=$(ax_frame_by_id "cockpit-settings")
[ "$GEAR" != "NOTFOUND" ] && [ -n "$GEAR" ] || { echo "E2E REAL-CLICK: FAIL — Settings gear not in the AX tree"; exit 1; }
GX=$(python3 -c "f='$GEAR'.split(','); print(int(float(f[0])+float(f[2])/2))"); GY=$(python3 -c "f='$GEAR'.split(','); print(int(float(f[1])+float(f[3])/2))")
echo "== targets: track-$TARGET click at $CX,$CY · Settings gear at $GX,$GY =="

# ---- 1. REAL click on the board track: the create must land ----
click_checked "$CX" "$CY" "the board track"
LANDED=0
for _ in $(seq 1 20); do
  [ "$(count_for $TARGET)" = "1" ] && { LANDED=1; break; }
  sleep 0.5
done
[ "$LANDED" = "1" ] || { echo "E2E REAL-CLICK: FAIL — a real click on track-$TARGET did not book a schedule (count $(count_for $TARGET)) — the tap never completed (F18: an exception on the first tick aborts createAt before onCreate); raw: $(curl -s "$BASE/v1/schedules")"; exit 1; }
echo "== real click on the track booked a schedule for $TARGET (count 1) =="

# ---- 2. REAL click on ⚙ AFTER the track click: the sheet must open ----
# This is the F18 assertion: after the first board tick, a SwiftUI Button
# in the same window must still receive real mouse-downs.
sleep 0.5
click_checked "$GX" "$GY" "the Settings gear"
OPENED=0
for _ in $(seq 1 20); do
  [ "$(sheets)" = "1" ] && { OPENED=1; break; }
  sleep 0.5
done
[ "$OPENED" = "1" ] || { echo "E2E REAL-CLICK: FAIL — a real click on ⚙ after the track click opened no Settings sheet (sheets=$(sheets)) — the window is click-dead (F18)"; exit 1; }
echo "== real click on ⚙ opened the Settings sheet (sheets=1) =="

# ---- 3. dismiss + a second real click on the track: still alive ----
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
sleep 0.8
[ "$(sheets)" = "0" ] || { echo "E2E REAL-CLICK: FAIL — Escape did not close the Settings sheet (sheets=$(sheets))"; exit 1; }
CX2=$(python3 -c "print(int($TX + $TW*0.4))")
click_checked "$CX2" "$CY" "the board track (2nd)"
LANDED2=0
for _ in $(seq 1 20); do
  [ "$(count_for $TARGET)" = "2" ] && { LANDED2=1; break; }
  sleep 0.5
done
[ "$LANDED2" = "1" ] || { echo "E2E REAL-CLICK: FAIL — the second real track click did not book (count $(count_for $TARGET))"; exit 1; }
echo "== second real click on the track booked again (count 2) =="

echo "E2E REAL-CLICK: PASS — real mouse clicks book on the board and open Settings; the window stays click-alive after the first tick"
