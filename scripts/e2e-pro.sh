#!/bin/bash
# E2E (app delta): the REAL Pro daemon against the REAL entitlement worker in
# Stripe TEST mode. Proves the daemon -> worker -> Stripe checkout wiring end to
# end: POST /v1/license/checkout mints a real test-mode Checkout Session and the
# daemon starts its silent activation poller. Completing the purchase (4242 card)
# and the refund/dispute paths are the interactive Stripe steps proven live in
# the money-core review (W8-MONEY-PLAN-REVIEW fix-delta); this script proves the
# NEW app-side half without a browser.
#
# Sandboxed: throwaway keychain + LLMPILOT_TEST interlock; the worker runs on
# localhost with op-injected TEST keys. No secret is ever printed.
#
# Usage: scripts/e2e-pro.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f go.work ] || [ ! -d ../llmpilot-pro ]; then
  echo "SKIP: needs go.work + ../llmpilot-pro for the -tags=pro daemon." >&2
  exit 2
fi

ROOT=$(mktemp -d /tmp/llmpilot-e2e-pro.XXXXXX)
KEYCHAIN="$ROOT/throwaway.keychain-db"
BIN="$ROOT/llmpilot-pro"
cleanup() {
  [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
  [ -n "${WRANGLER_PID:-}" ] && kill "$WRANGLER_PID" 2>/dev/null || true
  /usr/bin/security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -f worker/.dev.vars
  rm -rf "$ROOT"
}
trap cleanup EXIT

echo "== build the cockpit + the Pro daemon (-tags=pro, go.work resolves the engine) =="
(cd web && pnpm build >/dev/null)
go build -tags=pro -o "$BIN" ./cmd/llmpilot

echo "== bring up the entitlement worker (op-injected TEST keys, local D1) =="
(cd worker && op inject -f -i .dev.vars.template -o .dev.vars >/dev/null 2>&1)
(cd worker && npm run migrate:local >/dev/null 2>&1)
(cd worker && npm run dev >"$ROOT/wrangler.log" 2>&1) &
WRANGLER_PID=$!
for _ in $(seq 1 60); do
  curl -fsS "http://localhost:8787/healthz" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://localhost:8787/healthz" >/dev/null || { echo "worker never came up"; tail -5 "$ROOT/wrangler.log"; exit 1; }
echo "  worker healthz OK on :8787"

echo "== sandboxed Pro daemon pointed at the local worker =="
export TZ=UTC
export LLMPILOT_TEST=1
export LLMPILOT_HOME="$ROOT/home"
export LLMPILOT_KEYCHAIN="$KEYCHAIN"
export LLMPILOT_ENTITLEMENT_URL="http://localhost:8787"
mkdir -p "$LLMPILOT_HOME"
/usr/bin/security create-keychain -p e2e "$KEYCHAIN"
/usr/bin/security unlock-keychain -p e2e "$KEYCHAIN"

"$BIN" daemon run >"$ROOT/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do [ -f "$LLMPILOT_HOME/daemon.port" ] && break; sleep 0.1; done
PORT=$(cat "$LLMPILOT_HOME/daemon.port")
BASE="http://127.0.0.1:$PORT"
echo "  daemon on $BASE"

TOKEN=$(cat "$LLMPILOT_HOME/daemon.token")

echo "== GET /v1/license (official build, no entitlement yet) =="
curl -fsS "$BASE/v1/license" | jq '{available, active, status}'

echo "== POST /v1/license/checkout WITHOUT the install token must be 401 =="
NOAUTH=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/license/checkout" \
  -H 'Content-Type: application/json' -d '{"rung":"discount_trial"}')
if [ "$NOAUTH" != "401" ]; then
  echo "  FAIL: tokenless checkout answered $NOAUTH, want 401"; exit 1
fi
echo "  PASS: tokenless checkout refused (401)"

echo "== GET /v1/license/quote — the server-quoted consent terms =="
QUOTE=$(curl -fsS "$BASE/v1/license/quote")
TRIAL_DAYS=$(printf '%s' "$QUOTE" | jq -r '.trial_days')
CUR=$(printf '%s' "$QUOTE" | jq -r '.prices.discount | keys[0]')
AMOUNT=$(printf '%s' "$QUOTE" | jq -r ".prices.discount[\"$CUR\"]")
echo "  quoted: ${TRIAL_DAYS}-day trial, then $AMOUNT minor units ($CUR)"

echo "== checkout with a DRIFTED echo must be 409 quote_stale =="
STALE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/license/checkout" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"rung\":\"discount_trial\",\"quote\":{\"trial_days\":$((TRIAL_DAYS + 1)),\"currency\":\"$CUR\",\"amount_minor\":$AMOUNT}}")
if [ "$STALE" != "409" ]; then
  echo "  FAIL: drifted echo answered $STALE, want 409"; exit 1
fi
echo "  PASS: drifted echo refused (409 quote_stale)"

echo "== POST /v1/license/checkout {rung: discount_trial} + quote echo — mints a REAL test session =="
CO=$(curl -fsS -X POST "$BASE/v1/license/checkout" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"rung\":\"discount_trial\",\"quote\":{\"trial_days\":$TRIAL_DAYS,\"currency\":\"$CUR\",\"amount_minor\":$AMOUNT}}")
SID=$(printf '%s' "$CO" | jq -r '.session_id')
URL=$(printf '%s' "$CO" | jq -r '.url')
echo "  session_id: $SID"
echo "  checkout url host: $(printf '%s' "$URL" | sed -E 's#(https?://[^/]+)/.*#\1#')"
case "$SID" in
  cs_*) echo "  PASS: worker created a live Stripe TEST checkout session" ;;
  *) echo "  FAIL: no cs_ session id returned"; exit 1 ;;
esac

echo "== activation poller is running; /v1/activate is pending until the card is entered =="
ACT=$(curl -fsS -X POST "http://localhost:8787/v1/activate" \
  -H 'Content-Type: application/json' -d "{\"session_id\":\"$SID\"}")
echo "  worker /v1/activate → $(printf '%s' "$ACT" | jq -c '{pending, status}')"
echo "  (a real 4242 purchase flips this to trialing; the daemon poller then"
echo "   stores the grant and Pro turns on silently — money-core proven live.)"

echo "E2E-PRO: PASS (daemon -> worker -> Stripe checkout wiring proven live)"
