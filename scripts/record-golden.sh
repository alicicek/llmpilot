#!/bin/bash
# Golden: record the whole terminal surface — every command's happy path
# and one failure path — on fixtures, into docs/goldens/core.md.
# Sandboxed: filesystem via a fake $HOME + LLMPILOT_HOME, Keychain via a
# per-run throwaway keychain, LLMPILOT_TEST arming the code interlock. The
# daemon polls a LOCAL fixture server (LLMPILOT_USAGE_URL, honored only
# under LLMPILOT_TEST) — no real network, no real accounts, no real
# keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
OUT=${OUT:-docs/goldens/core.md}
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/llmpilot

ROOT=$(mktemp -d /tmp/llmpilot-golden.XXXXXX)
export TZ=UTC
export NO_COLOR=1 # keep ANSI out of the markdown; color is unit-tested
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export HOME="$ROOT/home"
# The interlock refuses ANY home-default .claude layout under LLMPILOT_TEST
# (that layout is exactly what a buggy sandbox could clobber for real), so
# the sandbox's "main" account lives in a custom config dir, like
# scripts/e2e-sandbox.sh.
export CLAUDE_CONFIG_DIR="$ROOT/home/claude-main"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
T="$ROOT/transcript.md"

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${FIXTURE_PID:-}" ] && kill "$FIXTURE_PID" 2>/dev/null || true
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

# rec <shown-command> <actual command...>: append one fenced run to the
# transcript; non-zero exits are recorded, never fatal (failure paths are the
# point).
rec() {
  local title=$1; shift
  {
    echo '```console'
    echo "\$ $title"
  } >>"$T"
  set +e
  "$@" >>"$T" 2>&1
  local rc=$?
  set -e
  {
    [ $rc -ne 0 ] && echo "(exit $rc)"
    echo '```'
    echo
  } >>"$T"
}

section() { printf '## %s\n\n' "$1" >>"$T"; }

# ---- sandbox: two fake logged-in accounts -----------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME/.claude-alt" "$LLMPILOT_HOME" "$ROOT/empty-home"
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'EOF'
{"oauthAccount": {"accountUuid": "uuid-a", "emailAddress": "a@example.dev"}}
EOF
cat > "$HOME/.claude-alt/.claude.json" <<'EOF'
{"oauthAccount": {"accountUuid": "uuid-b", "emailAddress": "b@example.dev"}}
EOF

/usr/bin/security create-keychain -p golden "$KEYCHAIN"
/usr/bin/security unlock-keychain -p golden "$KEYCHAIN"
SERVICE_A="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
SERVICE_B="Claude Code-credentials-$(printf '%s' "$HOME/.claude-alt" | shasum -a 256 | cut -c1-8)"
CRED_A='{"claudeAiOauth":{"accessToken":"sandbox-token-a","refreshToken":"sandbox-refresh-a","expiresAt":4102444800000}}'
CRED_B='{"claudeAiOauth":{"accessToken":"sandbox-token-b","refreshToken":"sandbox-refresh-b","expiresAt":4102444800000}}'
/usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE_A" \
  -X "$(printf '%s' "$CRED_A" | xxd -p | tr -d '\n')" "$KEYCHAIN"
/usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE_B" \
  -X "$(printf '%s' "$CRED_B" | xxd -p | tr -d '\n')" "$KEYCHAIN"

# ---- local fixture usage endpoint -------------------------------------------
FIXTURE_PORT=18732
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

# ---- transcript --------------------------------------------------------------
cat > "$T" <<EOF
# golden transcript — the core on fixtures

Recorded by \`scripts/record-golden.sh\` on $(date -u +%Y-%m-%d) (TZ=UTC).
Sandboxed end to end: fake \$HOME with two logged-in fake accounts, throwaway
keychain, LLMPILOT_TEST interlock armed, daemon polling a local fixture
server. Every command shows its happy path and one failure path — degraded
states are designed output, never stack traces.

EOF

section "llmpilot init — detect + register existing logins"
rec "llmpilot init" "$BIN" init
rec "llmpilot init   # nothing to find" env -u CLAUDE_CONFIG_DIR HOME="$ROOT/empty-home" "$BIN" init

section "llmpilot accounts"
rec "llmpilot accounts" "$BIN" accounts
rec "llmpilot accounts   # empty registry" env LLMPILOT_HOME="$ROOT/empty-home" "$BIN" accounts

section "llmpilot status — before any daemon has ever polled"
rec "llmpilot status" "$BIN" status

section "daemon up: poll fixtures, serve state"
"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
sleep 1  # first poll pass writes the caches
rec "llmpilot daemon status" "$BIN" daemon status
rec "llmpilot status" "$BIN" status
rec "llmpilot status --json" "$BIN" status --json

section "llmpilot switch"
rec "llmpilot switch alt" "$BIN" switch alt
rec "llmpilot switch a   # and back" "$BIN" switch a
rec "llmpilot switch nosuch   # unknown label" "$BIN" switch nosuch

section "llmpilot statusline — cache fresh (piped from Claude Code)"
STDIN_JSON='{"rate_limits":{"five_hour":{"used_percentage":24.5,"resets_at":1783522800},"seven_day":{"used_percentage":42,"resets_at":1783857600}}}'
rec "echo <claude-stdin-json> | llmpilot statusline" \
  bash -c "echo '$STDIN_JSON' | \"$BIN\" statusline"
rec "echo <claude-stdin-json> | llmpilot statusline --privacy" \
  bash -c "echo '$STDIN_JSON' | \"$BIN\" statusline --privacy"

section "llmpilot statusline — stale cache falls back to the live floor"
# age the cache 48 minutes: the 5h/wk windows switch to Claude Code's own
# rate_limits floor; cache-only buckets stay, honestly aged.
python3 - "$LLMPILOT_HOME" <<'PYEOF'
import json, sys, glob, datetime
for p in glob.glob(sys.argv[1] + "/cache/usage-*.json"):
    doc = json.load(open(p))
    asof = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=48)
    doc["as_of"] = asof.isoformat().replace("+00:00", "Z")
    json.dump(doc, open(p, "w"))
PYEOF
rec "echo <claude-stdin-json> | llmpilot statusline" \
  bash -c "echo '$STDIN_JSON' | \"$BIN\" statusline"

section "llmpilot statusline — nothing at all (fresh install, no daemon)"
rec "llmpilot statusline </dev/null" \
  env LLMPILOT_HOME="$ROOT/empty-home" "$BIN" statusline < /dev/null

section "statusline latency (budget: 50ms per render, process start included)"
{
  echo '```console'
  echo "\$ 20 timed runs of: llmpilot statusline"
  python3 - "$BIN" <<'PYEOF'
import subprocess, sys, time
times = []
for _ in range(20):
    t0 = time.perf_counter()
    subprocess.run([sys.argv[1], "statusline"], input=b"{}",
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    times.append((time.perf_counter() - t0) * 1000)
print(f"avg {sum(times)/len(times):.1f}ms  max {max(times):.1f}ms  min {min(times):.1f}ms")
PYEOF
  echo '```'
  echo
} >>"$T"

section "daemon down: same commands degrade honestly"
kill "$DAEMON_PID"; wait "$DAEMON_PID" 2>/dev/null || true; DAEMON_PID=""
rec "llmpilot daemon status" "$BIN" daemon status
rec "llmpilot status" "$BIN" status

mkdir -p "$(dirname "$OUT")"
cp "$T" "$OUT"
echo "golden recorded → $OUT"
