#!/bin/bash
# E2E: the Playwright happy path against a REAL sandboxed daemon serving the
# embedded cockpit — open → board renders → book → persisted →
# keyboard-move → switch account from the UI → SSE live. Sandboxed (fake
# $HOME, throwaway keychain, LLMPILOT_TEST interlock, local fixture usage
# server) — same machinery as scripts/record-golden.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
(cd web && pnpm build)
go build -o "$BIN" ./cmd/llmpilot

REAL_HOME="$HOME" # playwright/pnpm run under the real home; only the daemon gets the fake one
ROOT=$(mktemp -d /tmp/llmpilot-e2e-web.XXXXXX)
export TZ=UTC
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
export CLAUDE_CONFIG_DIR="$ROOT/home/claude-main"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"

cleanup() {
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
mkdir -p "$CLAUDE_CONFIG_DIR" "$LLMPILOT_HOME"
SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"

/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"
login_global() { # <uuid> <email> <tag> — the global dir is now logged into this account
  echo "{\"oauthAccount\": {\"accountUuid\": \"$1\", \"emailAddress\": \"$2\"}}" >"$CLAUDE_CONFIG_DIR/.claude.json"
  cred="{\"claudeAiOauth\":{\"accessToken\":\"sandbox-token-$3\",\"refreshToken\":\"sandbox-refresh-$3\",\"expiresAt\":4102444800000}}"
  /usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" \
    -X "$(printf '%s' "$cred" | xxd -p | tr -d '\n')" "$KEYCHAIN"
}

# ---- local fixture usage endpoint ----
FIXTURE_PORT=18733
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
export E2E_BASE_URL="http://127.0.0.1:$PORT"
echo "daemon on $E2E_BASE_URL"

# ---- the happy path ----
(cd web && HOME="$REAL_HOME" pnpm exec playwright test "$@")
echo "E2E COCKPIT: PASS"

# ---- statusline: apply → the BINARY's output changes ----
# The Playwright run applied a config with the model segment; the binary must
# render it from the same statusline.json (sample stdin carries the model).
SAMPLE_STDIN='{"model":{"id":"claude-fable-5","display_name":"Fable"},"workspace":{"current_dir":"/Users/you/dev/llmpilot"},"cwd":"/Users/you/dev/llmpilot","cost":{"total_cost_usd":3.42},"context_window":{"used_percentage":34,"context_window_size":200000}}'
BIN_LINE=$(printf '%s' "$SAMPLE_STDIN" | NO_COLOR=1 COLUMNS=120 "$BIN" statusline)
echo "binary statusline after apply: $BIN_LINE"
case "$BIN_LINE" in
  *Fable*) echo "E2E STATUSLINE APPLY→BINARY: PASS" ;;
  *) echo "E2E STATUSLINE APPLY→BINARY: FAIL (model segment missing)"; exit 1 ;;
esac

# ---- preview-parity: daemon preview byte-equals the real binary ----
# Same config (the saved one), same stdin fixture (statusline.SamplePayload's
# exact fields above), plain tier both sides.
PREVIEW_PLAIN=$(curl -sf "$E2E_BASE_URL/v1/statusline/preview?width=120&tier=plain" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plain"])')
if [ "$PREVIEW_PLAIN" = "$BIN_LINE" ]; then
  echo "E2E PREVIEW-PARITY: PASS (\"$PREVIEW_PLAIN\" == binary stdout)"
else
  echo "E2E PREVIEW-PARITY: FAIL"
  echo "  preview: $PREVIEW_PLAIN"
  echo "  binary : $BIN_LINE"
  exit 1
fi

# ---- budget: <50ms including process start (wall clock, 10 runs) ----
python3 - "$BIN" <<PYEOF
import subprocess, sys, time
stdin = '$SAMPLE_STDIN'.encode()
times = []
env = {"PATH": "/usr/bin:/bin", "NO_COLOR": "1", "COLUMNS": "120",
       "LLMPILOT_HOME": "$LLMPILOT_HOME", "HOME": "$HOME",
       "CLAUDE_CONFIG_DIR": "$CLAUDE_CONFIG_DIR", "LLMPILOT_TEST": "1"}
for _ in range(10):
    t0 = time.monotonic()
    subprocess.run([sys.argv[1], "statusline"], input=stdin, capture_output=True, env=env, check=True)
    times.append((time.monotonic() - t0) * 1000)
times.sort()
print(f"statusline wall clock incl. process start: min {times[0]:.1f}ms · median {times[5]:.1f}ms · max {times[-1]:.1f}ms (budget 50ms)")
if times[5] > 50:
    print("E2E STATUSLINE BUDGET: FAIL")
    sys.exit(1)
print("E2E STATUSLINE BUDGET: PASS")
PYEOF
