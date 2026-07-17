#!/bin/bash
# Golden: the autopilot scenario — schedule set via CLI → launchd job
# exists → trigger dry-run fires under the right CLAUDE_CONFIG_DIR →
# simulated 95% utilization rotates the active account → events in
# `llmpilot log` + SSE. Recorded into docs/goldens/autopilot.md.
# Sandboxed: fake $HOME + LLMPILOT_HOME, throwaway keychain, LLMPILOT_TEST
# interlock, fixture usage server, sandboxed LaunchAgents dir (launchctl
# echoed, never executed), stub `claude`.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=${BIN:-./llmpilot}
OUT=${OUT:-docs/goldens/autopilot.md}
[ -x "$BIN" ] || go build -o "$BIN" ./cmd/llmpilot
BIN=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")

ROOT=$(mktemp -d /tmp/llmpilot-ap.XXXXXX)
export TZ=UTC
export NO_COLOR=1
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export LLMPILOT_AGENTS_DIR="$ROOT/launch-agents"
export HOME="$ROOT/home"
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

# ---- sandbox: two fake logged-in accounts (a = active, alt) -----------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$HOME/.claude-alt" "$LLMPILOT_HOME" "$LLMPILOT_AGENTS_DIR"
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

# ---- stub `claude`: records its CLAUDE_CONFIG_DIR, answers the trigger ------
STUB_DIR="$ROOT/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<EOF
#!/bin/sh
echo "CLAUDE_CONFIG_DIR=\$CLAUDE_CONFIG_DIR  argv: claude \$*" >> "$ROOT/stub-claude-config-dirs"
echo "hi from stub claude (\$*)"
EOF
chmod +x "$STUB_DIR/claude"
export PATH="$STUB_DIR:$PATH"

# ---- fixture usage server: account a runs HOT, alt runs cool ----------------
FIXTURE_PORT=18733
python3 - "$FIXTURE_PORT" <<'PYEOF' &
import http.server, sys
port = int(sys.argv[1])
hot = open("testdata/fixtures/usage-hot.json", "rb").read()
cool = open("testdata/fixtures/usage-cool.json", "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = hot if "sandbox-token-a" in self.headers.get("Authorization", "") else cool
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

NOW_HHMM=$(date +%H:%M)

cat > "$T" <<EOF
# golden transcript — the autopilot scenario on fixtures

Recorded by \`scripts/record-autopilot-golden.sh\` on $(date -u +%Y-%m-%d) (TZ=UTC).
Sandboxed end to end: fake \$HOME with two logged-in fake accounts, throwaway
keychain, LLMPILOT_TEST interlock armed, sandboxed LaunchAgents dir
(launchctl echoed, never executed), stub \`claude\` on PATH, fixture usage
server where account \`a\` runs HOT (session 95%, window active) and \`alt\`
runs cool (12%). The scenario: schedules land as launchd jobs → the daemon
sees 95% and rotates a→alt → a dry-run trigger fires under the target's own
CLAUDE_CONFIG_DIR → a trigger against the hot account is refused (an open
window cannot shift) → everything lands in \`llmpilot log\` and SSE.

EOF

section "register the sandbox fleet"
rec "llmpilot init" "$BIN" init

section "schedule set via CLI → launchd jobs exist (idempotent sync)"
rec "llmpilot schedule add alt $NOW_HHMM" "$BIN" schedule add alt "$NOW_HHMM"
rec "llmpilot schedule add a $NOW_HHMM" "$BIN" schedule add a "$NOW_HHMM"
rec "llmpilot schedule add alt $NOW_HHMM   # same again: no-op" "$BIN" schedule add alt "$NOW_HHMM"
rec "llmpilot schedule list" "$BIN" schedule list
rec "ls launch-agents/" ls "$LLMPILOT_AGENTS_DIR"
for p in "$LLMPILOT_AGENTS_DIR"/*.plist; do
  rec "plutil -lint ${p##*/}" plutil -lint "$p"
done

section "daemon up: polls fixtures, sees a at 95%, rotates to alt"
"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 100); do
  grep -q autoswitch "$LLMPILOT_HOME/events.jsonl" 2>/dev/null && break
  sleep 0.2
done
rec "llmpilot log" "$BIN" log
rec "cat ~/.claude/.claude.json   # oauthAccount after rotation" cat "$CLAUDE_CONFIG_DIR/.claude.json"

section "same events over SSE (GET /v1/events)"
{
  echo '```console'
  echo "\$ curl --unix-socket \$LLMPILOT_HOME/daemon.sock http://llmpilot/v1/events  # first SSE frame"
  # SSE streams forever: --max-time ends curl non-zero by design.
  (curl -s --max-time 3 --unix-socket "$LLMPILOT_HOME/daemon.sock" http://llmpilot/v1/events || true) \
    | head -2 | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
print(lines[0])
doc = json.loads(lines[1].removeprefix("data: "))
evs = [{k: e[k] for k in ("kind", "account_id", "message") if k in e} for e in doc.get("events", [])]
print("data: … \"events\":", json.dumps(evs, indent=2))
'
  echo '```'
  echo
} >>"$T"

section "dry-run trigger: fires under the TARGET's own CLAUDE_CONFIG_DIR"
rec "llmpilot schedule fire alt-${NOW_HHMM/:/}" "$BIN" schedule fire "alt-${NOW_HHMM/:/}"
rec "cat stub-claude-config-dirs   # every invocation the stub claude saw" cat "$ROOT/stub-claude-config-dirs"

section "trigger against the hot account: refused (an open window cannot shift)"
rec "llmpilot schedule fire a-${NOW_HHMM/:/}" "$BIN" schedule fire "a-${NOW_HHMM/:/}"

section "degraded wake mode: honest status, and a missed fire lands LATE"
rec "llmpilot wake status" "$BIN" wake status
rec "llmpilot wake uninstall   # nothing to remove" "$BIN" wake uninstall
LATE_HHMM=$(date -v-6H +%H:%M)
rec "llmpilot schedule add alt $LATE_HHMM   # slot was ~6h ago" "$BIN" schedule add alt "$LATE_HHMM"
rec "llmpilot schedule fire alt-${LATE_HHMM/:/}   # as launchd would on wake" "$BIN" schedule fire "alt-${LATE_HHMM/:/}"

section "the whole story in llmpilot log"
rec "llmpilot log" "$BIN" log

section "remove: schedule + launchd job go together"
rec "llmpilot schedule remove alt-${NOW_HHMM/:/}" "$BIN" schedule remove "alt-${NOW_HHMM/:/}"
rec "ls launch-agents/" ls "$LLMPILOT_AGENTS_DIR"
rec "llmpilot schedule remove alt-${NOW_HHMM/:/}   # already gone" "$BIN" schedule remove "alt-${NOW_HHMM/:/}"

mkdir -p "$(dirname "$OUT")"
# tmpdir paths churn per run; pin them so the golden diffs clean.
sed -e "s|$ROOT|/tmp/llmpilot-ap.XXXXXX|g" "$T" > "$OUT"
echo "golden recorded → $OUT"
