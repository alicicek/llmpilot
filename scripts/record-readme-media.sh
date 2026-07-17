#!/bin/bash
# Produce the README media (docs/media/cockpit.png + docs/media/scheduler.gif)
# from the masked demo fixtures (?fixtures=1) — the same designed states the
# onboarding demo uses. Real binary serving the embedded cockpit; no accounts,
# no keychain, nothing personal on screen.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
(cd web && pnpm build)
go build -o "$BIN" ./cmd/llmpilot

ROOT=$(mktemp -d /tmp/llmpilot-media.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/home"
mkdir -p "$LLMPILOT_HOME"
cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
PORT=$(cat "$LLMPILOT_HOME/daemon.port")

export MEDIA_BASE_URL="http://127.0.0.1:$PORT"
export MEDIA_OUT_DIR="$PWD/docs/media"
mkdir -p docs/media

(cd web && node scripts/readme-media.mjs)

# webm -> gif, two-pass palette for quality at README-friendly weight
ffmpeg -y -i docs/media/scheduler.webm \
  -vf "fps=15,scale=960:-1:flags=lanczos,palettegen" "$ROOT/palette.png" >/dev/null 2>&1
ffmpeg -y -i docs/media/scheduler.webm -i "$ROOT/palette.png" \
  -filter_complex "fps=15,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse" \
  docs/media/scheduler.gif >/dev/null 2>&1
rm -f docs/media/scheduler.webm

ls -lh docs/media/
