#!/bin/bash
# E2E: click-switch in the REAL menu bar app performs a sandboxed swap
# end-to-end. Sandboxed: fake $HOME + LLMPILOT_HOME, throwaway keychain,
# LLMPILOT_TEST interlock, local fixture usage server — the same machinery
# as scripts/e2e-cockpit.sh. The click is a human (or a driver) on the
# actual menu bar icon; this script arms the sandbox, launches the app, and
# asserts the outcome.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
go build -o "$BIN" ./cmd/llmpilot

REAL_HOME="$HOME"
ROOT=$(mktemp -d /tmp/llmpilot-e2e-menubar.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
# The global config dir lives OUTSIDE the redirected $HOME (the
# e2e-switch-hardening.sh layout): the assertSandboxDir interlock refuses to
# swap/keep-warm any dir under the process home, and a redirected HOME makes
# a home-nested fixture dir self-refusing. Both fixture
# accounts still register on this ONE global dir.
export CLAUDE_CONFIG_DIR="$ROOT/claude"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"

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
  rm -rf "$ROOT"
}
trap cleanup EXIT

# ---- two fake logged-in accounts, BOTH on the global config dir ----
# Swappable fleet accounts all live on the GLOBAL dir — the idle one's
# credential is an llmpilot backup, installed into the global slot on
# switch. A sibling ~/.claude-* fixture would register a PINNED account,
# which Swap refuses by design (clone-lineage hazard, owner 2026-07-16)
# and whose keep-warm dir the LLMPILOT_TEST interlock refuses under a
# sandboxed $HOME. So the sandbox mirrors two real logins in sequence.
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

# ---- local fixture usage endpoint (live bars in the dropdown) ----
FIXTURE_PORT=18741
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
export LLMPILOT_USAGE_URL="http://127.0.0.1:$FIXTURE_PORT"
sleep 0.3

# ---- register the fake fleet (two logins in sequence), start the daemon ----
login_global uuid-b b@example.dev b
"$BIN" init
login_global uuid-a a@example.dev a
"$BIN" init
"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
sleep 1 # first poll writes snapshots
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
BASE="http://127.0.0.1:$PORT"

show_oauth() {
  python3 -c "import json; print('  oauthAccount:', json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))['oauthAccount']['emailAddress'])"
}
active_id() {
  curl -s "$BASE/v1/state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('active_id',''))"
}

BEFORE=$(active_id)
echo "== sandbox live: daemon on $BASE · active: $BEFORE =="
show_oauth

# ---- launch the real app inside the sandbox env ----
"$APP/Contents/MacOS/llmpilot" >"$ROOT/app.log" 2>&1 &
APP_PID=$!
echo "== app launched (pid $APP_PID) — click the llmpilot menu bar icon, then Switch on the inactive account =="

TIMEOUT=${E2E_CLICK_TIMEOUT:-180}
for i in $(seq 1 "$TIMEOUT"); do
  NOW=$(active_id)
  [ -n "$NOW" ] && [ "$NOW" != "$BEFORE" ] && break
  sleep 1
done
NOW=$(active_id)
if [ "$NOW" = "$BEFORE" ]; then
  echo "E2E MENUBAR: FAIL — no switch observed within ${TIMEOUT}s"
  exit 1
fi

echo "== switch observed: $BEFORE -> $NOW =="
show_oauth
python3 -c "
import json
doc = json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))
assert doc['oauthAccount']['emailAddress'] == 'b@example.dev', doc
print('  oauthAccount splice: OK')
"
if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "  no token material in LLMPILOT_HOME: clean"
echo "E2E MENUBAR: PASS — click-switch performed a sandboxed swap end-to-end"
