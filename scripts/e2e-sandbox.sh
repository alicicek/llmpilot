#!/bin/bash
# E2E proof: full sandboxed swap + daemon, end to end, with the REAL
# llmpilot binary and the REAL /usr/bin/security — against a THROWAWAY
# keychain and a fake config dir. Two independent sandbox layers:
# filesystem via env redirection, Keychain via a per-run throwaway keychain
# file. LLMPILOT_TEST arms the code interlock.
set -euo pipefail

ROOT=$(mktemp -d /tmp/llmpilot-e2e.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
BIN=${BIN:-./llmpilot}

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

echo "== sandbox =="
echo "root:      $ROOT"
echo "keychain:  $KEYCHAIN (throwaway, deleted on exit)"

/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"

mkdir -p "$CLAUDE_CONFIG_DIR" "$LLMPILOT_HOME"

# --- fake logged-in account a ---
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'EOF'
{
  "oauthAccount": {"accountUuid": "uuid-a", "emailAddress": "a@example.dev"},
  "userSettings": {"theme": "dark"},
  "projects": {"/tmp/x": {"exampleFlag": true}}
}
EOF

SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
CRED_A='{"claudeAiOauth":{"accessToken":"sandbox-token-a","refreshToken":"sandbox-refresh-a","expiresAt":4102444800000}}'
/usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" \
  -X "$(printf '%s' "$CRED_A" | xxd -p | tr -d '\n')" "$KEYCHAIN"

# --- register both accounts; seed b's backup the way `account add` does ---
cat > "$LLMPILOT_HOME/accounts.json" <<EOF
[
  {"id": "acct-a", "label": "a", "email": "a@example.dev", "config_dir": "$CLAUDE_CONFIG_DIR", "keychain_service": "$SERVICE"},
  {"id": "acct-b", "label": "b", "email": "b@example.dev", "config_dir": "$CLAUDE_CONFIG_DIR", "keychain_service": "$SERVICE"}
]
EOF
BACKUP_B='{"credential":{"claudeAiOauth":{"accessToken":"sandbox-token-b","refreshToken":"sandbox-refresh-b","expiresAt":4102444800000}},"oauthAccount":{"accountUuid":"uuid-b","emailAddress":"b@example.dev"},"saved_at":"2026-07-09T00:00:00Z"}'
/usr/bin/security add-generic-password -U -a acct-b -s llmpilot-backups \
  -X "$(printf '%s' "$BACKUP_B" | xxd -p | tr -d '\n')" "$KEYCHAIN"

show_oauth() {
  python3 -c "import json,sys; print('  oauthAccount:', json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))['oauthAccount']['emailAddress'])"
}

echo
echo "== swap a -> b =="
echo "before:"; show_oauth
"$BIN" switch b
echo "after:"; show_oauth

echo
echo "== swap back b -> a (restore from backup) =="
"$BIN" switch a
echo "after:"; show_oauth

echo
echo "== untouched config keys survived both splices =="
python3 -c "
import json
doc = json.load(open('$CLAUDE_CONFIG_DIR/.claude.json'))
assert doc['userSettings'] == {'theme': 'dark'}, doc
assert doc['projects'] == {'/tmp/x': {'exampleFlag': True}}, doc
print('  userSettings + projects intact')
"

echo
echo "== no secrets in llmpilot home (cache discipline) =="
if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "  grep for token material in $LLMPILOT_HOME: clean"

echo
echo "== daemon: state + SSE =="
"$BIN" daemon run &
DAEMON_PID=$!
for i in $(seq 1 50); do
  [ -f "$LLMPILOT_HOME/daemon.port" ] && break
  sleep 0.1
done
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
echo "-- GET /v1/state (127.0.0.1:$PORT) --"
curl -s "http://127.0.0.1:$PORT/v1/state" | python3 -m json.tool | head -30
echo "-- GET /v1/state (unix socket) --"
curl -s --unix-socket "$LLMPILOT_HOME/daemon.sock" http://localhost/v1/state \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('  accounts:', [a['label'] for a in d['accounts']], 'active:', d.get('active_id'))"

echo "-- SSE: event on cache change --"
curl -s -N --max-time 5 "http://127.0.0.1:$PORT/v1/events" > "$ROOT/sse.log" &
SSE_PID=$!
sleep 0.5
# poke the cache the way a poll would: write a snapshot and switch via API
# wrong content type must be refused (CSRF hardening) …
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{"account_id":"acct-b"}' "http://127.0.0.1:$PORT/v1/switch")
echo "  POST without application/json: HTTP $CODE (expect 415)"
[ "$CODE" = "415" ] || { echo "content-type guard missing"; exit 1; }
# … and the real call goes through
curl -s -X POST -H 'Content-Type: application/json' -d '{"account_id":"acct-b"}' "http://127.0.0.1:$PORT/v1/switch" \
  | python3 -c "import json,sys; print('  POST /v1/switch:', json.load(sys.stdin))"
wait $SSE_PID 2>/dev/null || true
EVENTS=$(grep -c '^event: state' "$ROOT/sse.log" || true)
echo "  SSE state events received: $EVENTS"
[ "$EVENTS" -ge 2 ] || { echo "expected >=2 SSE events (connect + switch)"; exit 1; }
show_oauth

echo
echo "== E2E SANDBOX PROOF: ALL STEPS PASSED =="
