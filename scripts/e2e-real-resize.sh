#!/bin/bash
# E2E: real-resize — a REAL edge drag (CGEvent press → leftMouseDragged →
# release) on the native cockpit, asserting the window refuses to go below
# its 1000×700 content minimum.
#
# WHY THIS EXISTS (audit 2026-08-17, N1): 1.3.1 shipped a cockpit whose
# stated minimum did not bite. One ordinary drag on the right edge took it
# to 876pt, then 426, then 226 wide, and the bottom edge to 231 tall; the
# content did not reflow, it CLIPPED — the whole header row disappeared and
# body text was cut mid-word at both edges. `WindowMode.cockpit.minSize` read
# 1000×700 the whole time and MainMenuTests asserted exactly that, and
# passed. Every other native e2e drives geometry through System Events'
# `set size of window`, which bypasses AppKit's live-resize path completely
# — the same class of blind spot that let F18 (click-dead window) ship past
# an all-green AX suite. This gate is the one that would have caught it:
# drag the edge for real, then read the size back.
#
# Sandbox: identical to scripts/e2e-real-click.sh (demo daemon
# LLMPILOT_DEMO=1, fake $HOME + fixed LLMPILOT_HOME, LLMPILOT_TEST
# interlock, SMAppService and launchd mutation disabled, throwaway defaults
# suite, dead-end usage URL, keychain named but never created).
#
# MACHINE REQUIREMENT: this run posts real drags, so the cockpit window must
# be on top and unobstructed at the grab points; the script activates the
# app and REFUSES (fails loudly) if another app's window owns the pixel.
# Run it on an idle Mac.
#
# PERMISSION: posting to the HID event tap needs Accessibility (or Input
# Monitoring) permission for the TERMINAL you run this from — System
# Settings > Privacy & Security > Accessibility. Without it macOS drops the
# events silently, the window never moves, and the "the drag was actually
# delivered" assertion below fails rather than passing vacuously.
#
# APP=/path/to/llmpilot.app skips the source build (used to prove the fail
# case against the shipped 1.3.1 bundle: it must FAIL there).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-$(pwd)/llmpilot}
go build -o "$BIN" ./cmd/llmpilot

STRAY_LLMPILOT=$(pgrep -f "llmpilot\.app/Contents/MacOS/llmpilot" 2>/dev/null || true)
if [ -n "$STRAY_LLMPILOT" ]; then
  echo "E2E REAL-RESIZE: FAIL -- another llmpilot app process is already running (pids: $(echo $STRAY_LLMPILOT | tr '\n' ' ')). Quit it and re-run."
  exit 1
fi

REAL_HOME="$HOME"
ROOT=$(mktemp -d /tmp/llmpilot-e2e-real-resize.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
export LLMPILOT_DISABLE_SMAPPSERVICE=1
export LLMPILOT_DEFAULTS_SUITE="dev.llmpilot.e2e-real-resize.$$"
export LLMPILOT_USAGE_URL="http://127.0.0.1:9"
export LLMPILOT_KEYCHAIN="$ROOT/absent.keychain-db"
export LLMPILOT_NO_LAUNCHD=1
export LLMPILOT_NATIVE_COCKPIT=1
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR"

# The cockpit's frame autosave writes through cfprefsd to the REAL
# dev.llmpilot.menubar domain even from a sandboxed run (WindowMode's own
# doc comment) — snapshot and restore it, exactly as e2e-real-click.sh does.
PRE_FLAG=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar firstLaunchWindowShown 2>/dev/null || echo "ABSENT")
PRE_FRAME=$(HOME="$REAL_HOME" defaults read dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || echo "ABSENT")
if [ "$PRE_FRAME" != "ABSENT" ]; then
  HOME="$REAL_HOME" defaults delete dev.llmpilot.menubar "NSWindow Frame llmpilot-cockpit" 2>/dev/null || true
fi

# Installed HERE, before the tool builds and the app build: the snapshot
# above already deleted the owner's saved frame, so from this point every
# exit path — including a missing Swift toolchain — must restore it.
cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
  # WAIT for it to actually go. A dying NSApplication flushes its own
  # autosaved window frame to cfprefsd, and the restore below writes to the
  # owner's REAL dev.llmpilot.menubar domain — kill-then-write races that
  # flush and can leave the owner's cockpit at the sandbox's size.
  if [ -n "${APP_PID:-}" ]; then
    for _ in $(seq 1 40); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
  fi
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

mkdir -p "$ROOT/tools"
HOME="$REAL_HOME" swiftc -O -o "$ROOT/tools/realdrag" scripts/tools/realdrag.swift 2>"$ROOT/swiftc.err" \
  || { echo "E2E REAL-RESIZE: FAIL — swiftc failed on scripts/tools/realdrag.swift:"; cat "$ROOT/swiftc.err"; exit 1; }
HOME="$REAL_HOME" swiftc -O -o "$ROOT/tools/topwin" scripts/tools/topwin.swift 2>"$ROOT/swiftc.err" \
  || { echo "E2E REAL-RESIZE: FAIL — swiftc failed on scripts/tools/topwin.swift:"; cat "$ROOT/swiftc.err"; exit 1; }
REALDRAG="$ROOT/tools/realdrag"; TOPWIN="$ROOT/tools/topwin"

APP=${APP:-}
if [ -z "$APP" ]; then
  HOME="$REAL_HOME" xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
    -configuration Release -derivedDataPath "$ROOT/dd" build >/dev/null
  APP="$ROOT/dd/Build/Products/Release/llmpilot.app"
  codesign --force --deep -s - "$APP" 2>/dev/null
fi
echo "== app under test: $APP =="


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
[ -n "$PORT" ] || { echo "E2E REAL-RESIZE: FAIL — demo daemon never came up"; tail -20 "$ROOT/daemon.log"; exit 1; }
echo "== demo daemon reachable on :$PORT =="

HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" firstLaunchWindowShown -bool true
HOME="$REAL_HOME" defaults write "$LLMPILOT_DEFAULTS_SUITE" llmpilot.tour.seen -bool true

"$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
disown
echo "== app launched (pid $APP_PID) — waiting for the native cockpit window =="
WINDOW=""
for _ in $(seq 1 30); do
  WINDOW=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to get name of windows" 2>/dev/null || true)
  case "$WINDOW" in *llmpilot*) break ;; esac
  sleep 1
done
case "$WINDOW" in *llmpilot*) ;; *) echo "E2E REAL-RESIZE: FAIL — no cockpit window (AX: '$WINDOW')"; tail -20 "$ROOT/app.log"; exit 1 ;; esac

frame() { # -> "x,y,w,h" of the cockpit window (AX: whole window, title bar included)
  # `|| true` inside the group, not after the pipeline: `set -o pipefail` is
  # on, so a transient osascript failure would otherwise abort the whole run
  # from inside a `$(frame)` assignment with no diagnosis. An empty answer
  # falls through to the callers' own explicit checks, which say what went
  # wrong.
  { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to tell window \"llmpilot\" to get {position, size}" 2>/dev/null || true; } | tr -d ' '
}
f_x() { echo "$1" | cut -d, -f1; }
f_y() { echo "$1" | cut -d, -f2; }
f_w() { echo "$1" | cut -d, -f3; }
f_h() { echo "$1" | cut -d, -f4; }

osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
# Start well ABOVE the floor in both axes, so a drag that stops at the floor
# is visibly a shrink and not the size it already had.
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $APP_PID) to tell window \"llmpilot\" to set {position, size} to {{60, 60}, {1400, 1000}}" >/dev/null 2>&1 || true
sleep 1.5
START=$(frame)
echo "== cockpit start frame (x,y,w,h): $START =="
[ -n "$START" ] || { echo "E2E REAL-RESIZE: FAIL — System Events returned no frame for the cockpit window; the AX tree is unreadable (is the app still up?)"; tail -20 "$ROOT/app.log"; exit 1; }
SW=$(f_w "$START"); SH=$(f_h "$START")
# AppKit clamps the staged size to the display, so the headroom this gate
# gets is a property of the MACHINE, not of the request. Decide per axis
# rather than demanding one flat size: a 1280x800 or 1440x900 display, or a
# 13" Air with the Dock showing, cannot give 900pt of height, and aborting
# there would mean the gate silently never runs on half the supported
# hardware.
[ "$SW" -ge 1100 ] || {
  echo "E2E REAL-RESIZE: FAIL — this display staged only ${SW}pt of width; under 1100 there is no headroom above the 1000pt floor to drag through, so the gate cannot run here. Use a wider display."; exit 1; }
RUN_HEIGHT=1
if [ "$SH" -lt 800 ]; then
  RUN_HEIGHT=0
  echo "== SKIPPED: the height half. This display staged only ${SH}pt (needs 800+ to leave room above the 732pt frame floor). The WIDTH floor is still asserted below; the height floor is NOT covered by this run. =="
fi

owns_pixel() { # <x> <y> <what>
  # Re-assert frontmost immediately before the check, not once at staging:
  # anything the operator touches in between (a terminal, a note window)
  # takes the pixel back, and the gate then refuses a drag it could have
  # made. Measured on this Mac — Raycast Notes and the invoking terminal
  # both stole the right edge between staging and the grab.
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
  sleep 0.6
  local owner; owner=$("$TOPWIN" "$1" "$2")
  case "$owner" in
    "llmpilot pid=$APP_PID "*) ;;
    *) echo "E2E REAL-RESIZE: FAIL — cannot grab $3 at $1,$2: pixel owned by '$owner' (cockpit covered or off-screen). Run on an idle Mac with the cockpit unobstructed."; exit 1 ;;
  esac
}

# ---- 1. REAL drag on the RIGHT edge, far past the floor ----
X=$(f_x "$START"); Y=$(f_y "$START"); W=$(f_w "$START"); H=$(f_h "$START")
EDGE_X=$((X + W - 2)); MID_Y=$((Y + H / 2))
owns_pixel "$EDGE_X" "$MID_Y" "the right edge"
# 226pt wide is exactly where the shipped 1.3.1 window ended up.
"$REALDRAG" "$EDGE_X" "$MID_Y" "$((X + 226))" "$MID_Y" >/dev/null
sleep 0.8
AFTER_W_FRAME=$(frame); AW=$(f_w "$AFTER_W_FRAME"); AH=$(f_h "$AFTER_W_FRAME")
echo "== after the right-edge drag (target 226 wide): $AFTER_W_FRAME =="
# Distinguish "the AX read failed" from "the drag was dropped" — they need
# opposite remedies, and an empty string fed to `-lt` would blame the
# permission that is already granted.
[ -n "$AW" ] || { echo "E2E REAL-RESIZE: FAIL — could not read the window frame after the drag (System Events timed out). This is an AX read failure, NOT a verdict on the minimum; re-run."; exit 1; }
[ "$AW" -lt "$W" ] || { echo "E2E REAL-RESIZE: FAIL — the right-edge drag never reached the window (width still $AW). Grant Accessibility to this terminal and re-run; a dropped drag must not read as a pass."; exit 1; }
[ "$AW" -ge 1000 ] || { echo "E2E REAL-RESIZE: FAIL — the cockpit went to ${AW}pt wide; the 1000pt minimum is not enforced (N1). At this width the header row disappears and body text clips mid-word."; exit 1; }
echo "== width stopped at ${AW}pt — the 1000pt floor held =="

# ---- 2. REAL drag on the BOTTOM edge, far past the floor ----
END=$AFTER_W_FRAME; EW=$AW; EH=$AH
if [ "$RUN_HEIGHT" = "1" ]; then
  X=$(f_x "$AFTER_W_FRAME"); Y=$(f_y "$AFTER_W_FRAME"); W=$AW; H=$AH
  EDGE_Y=$((Y + H - 2)); MID_X=$((X + W / 2))
  owns_pixel "$MID_X" "$EDGE_Y" "the bottom edge"
  "$REALDRAG" "$MID_X" "$EDGE_Y" "$MID_X" "$((Y + 231))" >/dev/null
  sleep 0.8
  END=$(frame); EW=$(f_w "$END"); EH=$(f_h "$END")
  echo "== after the bottom-edge drag (target 231 tall): $END =="
  [ -n "$EH" ] || { echo "E2E REAL-RESIZE: FAIL — could not read the window frame after the vertical drag (System Events timed out); re-run."; exit 1; }
  [ "$EH" -lt "$H" ] || { echo "E2E REAL-RESIZE: FAIL — the bottom-edge drag never reached the window (height still $EH). Grant Accessibility to this terminal and re-run."; exit 1; }
  [ "$EH" -ge 700 ] || { echo "E2E REAL-RESIZE: FAIL — the cockpit went to ${EH}pt tall; the 700pt minimum is not enforced (N1)."; exit 1; }
  [ "$EW" -ge 1000 ] || { echo "E2E REAL-RESIZE: FAIL — the vertical drag also collapsed the width to ${EW}pt"; exit 1; }
  echo "== height stopped at ${EH}pt — the 700pt floor held =="
fi

# ---- 3. it stopped AT the floor, not merely somewhere above it ----
# A window that ignored the drag entirely would also satisfy the two floors
# above. The floor is a CONTENT size, so the frame lands at 1000 wide and
# 700 + this window's own title bar tall — under 60pt of chrome on every
# macOS this ships to.
[ "$EW" -le 1002 ] || { echo "E2E REAL-RESIZE: FAIL — width settled at ${EW}pt, not at the 1000pt floor; the drag was clamped by something other than the minimum"; exit 1; }
if [ "$RUN_HEIGHT" = "1" ]; then
  [ "$EH" -le 760 ] || { echo "E2E REAL-RESIZE: FAIL — height settled at ${EH}pt, well above the 700pt floor; the drag did not actually reach the minimum"; exit 1; }
  echo "E2E REAL-RESIZE: PASS — a real edge drag shrinks the cockpit and stops dead at 1000x700 (${EW}x${EH} frame)"
else
  echo "E2E REAL-RESIZE: PASS (WIDTH ONLY) — a real edge drag stops dead at the 1000pt width floor (${EW}pt). The height floor was NOT exercised: this display is too short to stage the headroom. Re-run on a taller display before trusting the height half."
fi
