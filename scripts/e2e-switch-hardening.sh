#!/bin/bash
# E2E proof: the foreign-credential stash, end to end, with the
# REAL llmpilot binary and the REAL /usr/bin/security — against a THROWAWAY
# keychain and a fake config dir (Protocol 10: LLMPILOT_TEST interlock +
# filesystem env redirection + per-run throwaway keychain).
#
#   legacy unmatched-* item  --daemon start sweep-->  stash (REAL
#     `security dump-keychain` enumeration, not the unit-test fake)
#   switch away from a FOREIGN login --> stash entry + events.jsonl
#     kind=stash + SSE state push
#   /v1/state serves the stash --> adopt registers the account
#     global-swappable (fleet row appears) --> discard removes entry+payload
#   unauthenticated adopt/discard --> REFUSED (requireAuth fail case)
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$(mktemp -d /tmp/llmpilot-e2e-stash.XXXXXX)
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/llmpilot-home"
export CLAUDE_CONFIG_DIR="$ROOT/claude"
KEYCHAIN="$ROOT/throwaway.keychain-db"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
BIN=${BIN:-"$ROOT/llmpilot"}

cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

echo "== sandbox =="
echo "root:      $ROOT"
echo "keychain:  $KEYCHAIN (throwaway, deleted on exit)"

go build -o "$BIN" ./cmd/llmpilot
/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"
mkdir -p "$CLAUDE_CONFIG_DIR" "$LLMPILOT_HOME"

SERVICE="Claude Code-credentials-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"

# The global dir is logged into a FOREIGN account (signed in outside
# llmpilot, never registered) — the switch must preserve it, not guess.
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'EOF'
{
  "oauthAccount": {"accountUuid": "uuid-f", "emailAddress": "stranger@example.dev"},
  "userSettings": {"theme": "dark"}
}
EOF
CRED_F='{"claudeAiOauth":{"accessToken":"sandbox-token-f","refreshToken":"sandbox-refresh-f","expiresAt":4102444800000}}'
/usr/bin/security add-generic-password -U -a "$USER" -s "$SERVICE" \
  -X "$(printf '%s' "$CRED_F" | xxd -p | tr -d '\n')" "$KEYCHAIN"

# Registered fleet: acct-b with a stored backup (as `account add` leaves it).
cat > "$LLMPILOT_HOME/accounts.json" <<EOF
[
  {"id": "acct-b", "label": "b", "email": "b@example.dev", "config_dir": "$CLAUDE_CONFIG_DIR", "keychain_service": "$SERVICE"}
]
EOF
BACKUP_B='{"credential":{"claudeAiOauth":{"accessToken":"sandbox-token-b","refreshToken":"sandbox-refresh-b","expiresAt":4102444800000}},"oauthAccount":{"accountUuid":"uuid-b","emailAddress":"b@example.dev"},"saved_at":"2026-07-25T00:00:00Z"}'
/usr/bin/security add-generic-password -U -a acct-b -s llmpilot-backups \
  -X "$(printf '%s' "$BACKUP_B" | xxd -p | tr -d '\n')" "$KEYCHAIN"

# A PRE-P2 legacy unmatched-* item: the daemon-start sweep must migrate it
# into the stash via the REAL attribute-only `security dump-keychain` path.
LEGACY='{"credential":{"claudeAiOauth":{"accessToken":"sandbox-token-legacy","refreshToken":"sandbox-refresh-legacy","expiresAt":4102444800000}},"oauthAccount":{"emailAddress":"old.stranger@example.dev"},"saved_at":"2026-07-01T00:00:00Z"}'
/usr/bin/security add-generic-password -U -a "unmatched-old.stranger_example.dev" -s llmpilot-backups \
  -X "$(printf '%s' "$LEGACY" | xxd -p | tr -d '\n')" "$KEYCHAIN"

echo
echo "== daemon up =="
"$BIN" daemon run &
DAEMON_PID=$!
for i in $(seq 1 50); do
  [ -f "$LLMPILOT_HOME/daemon.port" ] && break
  sleep 0.1
done
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
TOKEN=$(cat "$LLMPILOT_HOME/daemon.token")
API="http://127.0.0.1:$PORT"
echo "port: $PORT"

echo
echo "== 1. startup sweep migrates the legacy unmatched-* item (real dump-keychain List) =="
for i in $(seq 1 50); do
  N=$(curl -s "$API/v1/state" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('stash') or []))")
  [ "$N" = "1" ] && break
  sleep 0.2
done
[ "$N" = "1" ] || { echo "sweep did not surface the legacy item (stash=$N)"; exit 1; }
curl -s "$API/v1/state" | python3 -c "
import json,sys
s = json.load(sys.stdin)['stash']
assert s[0]['label'] == 'old.stranger@example.dev', s
print('  migrated:', s[0]['label'], '(fingerprint', s[0]['fingerprint'][:16] + '…)')"
/usr/bin/security find-generic-password -s llmpilot-backups -a "unmatched-old.stranger_example.dev" "$KEYCHAIN" >/dev/null 2>&1 \
  && { echo "legacy item still present after migration"; exit 1; }
echo "  legacy keychain item removed after migration"

echo
echo "== 2. switch away from the foreign login → stash + event + SSE =="
curl -s -N --max-time 4 "$API/v1/events" > "$ROOT/sse.log" &
SSE_PID=$!
sleep 0.5
curl -s -X POST -H 'Content-Type: application/json' -d '{"account_id":"acct-b"}' "$API/v1/switch" \
  | python3 -c "import json,sys; print('  switch:', json.load(sys.stdin))"
wait $SSE_PID 2>/dev/null || true
STASH_JSON=$(curl -s "$API/v1/state")
FP_F=$(printf '%s' "$STASH_JSON" | python3 -c "
import json,sys
s = json.load(sys.stdin)['stash']
assert len(s) == 2, s
byl = {e.get('label',''): e for e in s}
assert 'stranger@example.dev' in byl, s
print(byl['stranger@example.dev']['fingerprint'])")
FP_L=$(printf '%s' "$STASH_JSON" | python3 -c "
import json,sys
s = json.load(sys.stdin)['stash']
print([e for e in s if e.get('label')=='old.stranger@example.dev'][0]['fingerprint'])")
echo "  stash now holds 2 entries (foreign login preserved)"
grep -q '"kind":"stash"' "$LLMPILOT_HOME/events.jsonl" || { echo "no kind=stash event in events.jsonl"; exit 1; }
echo "  events.jsonl carries kind=stash"
SSE_EVENTS=$(grep -c '^event: state' "$ROOT/sse.log" || true)
grep -q '"stash":\[{' "$ROOT/sse.log" || { echo "SSE state push does not carry the stash"; exit 1; }
echo "  SSE state pushes received: $SSE_EVENTS (stash entries on the wire)"

echo
echo "== 3. unauthenticated adopt/discard REFUSED (requireAuth fail case) =="
for EP in adopt discard; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d "{\"fingerprint\":\"$FP_F\"}" "$API/v1/stash/$EP")
  echo "  POST /v1/stash/$EP without token: HTTP $CODE (expect 401)"
  [ "$CODE" = "401" ] || { echo "unauthenticated $EP accepted"; exit 1; }
done

echo
echo "== 4. adopt the foreign entry → fleet row appears =="
curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "{\"fingerprint\":\"$FP_F\"}" "$API/v1/stash/adopt" \
  | python3 -c "import json,sys; a=json.load(sys.stdin); print('  adopted:', a['id'], a['email'])"
curl -s "$API/v1/state" | python3 -c "
import json,sys
st = json.load(sys.stdin)
emails = [a['email'] for a in st['accounts']]
assert 'stranger@example.dev' in emails, emails
assert len(st['stash']) == 1, st['stash']
print('  fleet rows:', emails)"
grep -q '"kind":"stash_adopt"' "$LLMPILOT_HOME/events.jsonl" || { echo "no stash_adopt event"; exit 1; }
echo "  events.jsonl carries kind=stash_adopt"

echo
echo "== 5. discard the legacy entry → payload deleted =="
curl -s -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "{\"fingerprint\":\"$FP_L\"}" "$API/v1/stash/discard" \
  | python3 -c "import json,sys; print('  discard:', json.load(sys.stdin))"
FINAL=$(curl -s "$API/v1/state")
printf '%s' "$FINAL" | python3 -c "
import json,sys
st = json.load(sys.stdin)
assert st['stash'] == [], st['stash']
print('  stash: [] (empty case serializes as an array, never null)')"
printf '%s' "$FINAL" | grep -q '"stash":\[\]' || { echo "empty stash not serialized as []"; exit 1; }
STASH_KEYS=$(/usr/bin/security dump-keychain "$KEYCHAIN" | grep -c 'stash-' || true)
[ "$STASH_KEYS" = "0" ] || { echo "discarded stash payload still in the keychain"; exit 1; }
echo "  keychain holds no stash-* items after discard"
grep -q '"kind":"stash_discard"' "$LLMPILOT_HOME/events.jsonl" || { echo "no stash_discard event"; exit 1; }
echo "  events.jsonl carries kind=stash_discard"

echo
echo "== 6. no token material in \$LLMPILOT_HOME (cache rule) =="
if grep -r "sandbox-token\|sandbox-refresh" "$LLMPILOT_HOME" 2>/dev/null; then
  echo "TOKEN LEAKED INTO LLMPILOT_HOME"; exit 1
fi
echo "  grep for token material: clean"

echo
echo "== E2E SWITCH-HARDENING PROOF: ALL STEPS PASSED =="
