#!/bin/bash
# LIVE keep-warm proof — OWNER-RUN, requires sign-off. Rotates a REAL
# throwaway account's OAuth refresh token against the REAL token endpoint,
# then proves the two claims that only a live run can:
#
#   1. NO 5-HOUR WINDOW ADVANCE — the account's five_hour bucket (percent and
#      resets_at) does not move ACROSS a refresh. A refresh is an auth call,
#      not a model call, so it must never start or advance a window.
#   2. CHAIN SURVIVES — two refreshes in a row both succeed, proving the first
#      rotation's new refresh token was stored correctly (and re-verifying the
#      endpoint + client_id are still live, per §Protocol 2b).
#
# Ordering matters: a keep-warm TARGET normally has an EXPIRED access token
# (that is the whole point), so its usage cannot be read until AFTER a refresh
# mints a fresh one. We therefore refresh FIRST, read the window, refresh
# AGAIN, read again, and assert the window did not move across that second
# refresh.
#
# The mechanical "contacts only token+usage, never an inference path" proof is
# the Go test TestKeepWarmE2ENoModelEgress (runs in CI, no real account). This
# script is the live complement and is NOT part of CI.
#
# Usage:
#   LLMPILOT_KEEPWARM_ACCOUNT=<label|id|email> scripts/e2e-keepwarm-live.sh
#
# The named account MUST be a THROWAWAY you can afford to re-login, MUST be
# registered (`llmpilot account add`), and MUST be idle (not the active
# account — keep-warm never touches the active one). Its refresh token must
# still be alive; a fully logged-out account is reported and skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCT="${LLMPILOT_KEEPWARM_ACCOUNT:-}"
if [ -z "$ACCT" ]; then
  echo "SKIP: set LLMPILOT_KEEPWARM_ACCOUNT=<label|id|email> to a THROWAWAY account to run the live proof."
  echo "      (This rotates a real refresh token; never point it at an account you rely on.)"
  exit 0
fi

BIN="${BIN:-./llmpilot}"
go build -o "$BIN" ./cmd/llmpilot

# five_hour_bucket prints "<percent> <resets_at>" for the account, or exits
# non-zero when usage can't be read (expired/logged-out).
five_hour_bucket() {
  local json
  json="$("$BIN" debug fetch --account "$ACCT" --json 2>&1)" || { echo "$json"; return 1; }
  python3 - "$json" <<'PY'
import json, sys
buckets = json.loads(sys.argv[1])
fh = next((b for b in buckets if b.get("kind") == "five_hour"), None)
print("NONE NONE" if fh is None else f"{fh.get('percent','NONE')} {fh.get('resets_at','NONE')}")
PY
}

echo "== live keep-warm proof for account: $ACCT =="
echo "   (rotates a real refresh token; Ctrl-C now if this is not a throwaway)"
sleep 2

# --- 1. Refresh (rotation #1) — mints a fresh access token to read with ----
out1="$("$BIN" account refresh "$ACCT" 2>&1 || true)"
echo "refresh #1: $out1"
if echo "$out1" | grep -q "backup is the live credential\|live in the global slot"; then
  echo "SKIP: $ACCT is the ACTIVE account — keep-warm never refreshes it (Claude Code owns it)."
  echo "      Switch to another account first:  $BIN switch <other>"
  exit 0
fi
if echo "$out1" | grep -qi "429\|rate-limiting"; then
  echo "SKIP: the token endpoint is rate-limiting refreshes right now (HTTP 429). This is TRANSIENT,"
  echo "      not a dead account — the daemon handles it by backing off. Wait a few minutes and re-run."
  exit 0
fi
if ! echo "$out1" | grep -q "^refreshed "; then
  echo "SKIP: could not refresh $ACCT — its refresh token is dead or it is logged out."
  echo "      Log in again (run a claude session in its dir), then re-add:  $BIN account add"
  exit 0
fi

# --- 2. Read the five_hour window (token is fresh now) --------------------
read -r before_pct before_reset < <(five_hour_bucket) || { echo "FAIL: usage unreadable right after a successful refresh"; exit 1; }
echo "before: five_hour percent=$before_pct resets_at=$before_reset"

# --- 3. Refresh (rotation #2) — must use the rotated token (chain) ---------
out2="$("$BIN" account refresh "$ACCT" 2>&1 || true)"
echo "refresh #2: $out2"
echo "$out2" | grep -q "^refreshed " || { echo "FAIL: second refresh did not rotate — chain broken (endpoint/client_id changed?): $out2"; exit 1; }
echo "PASS: chain survived — the second refresh used the rotated token (endpoint + client_id live)."

# --- 4. Read again and assert NO window advance across the refresh --------
read -r after_pct after_reset < <(five_hour_bucket) || { echo "FAIL: usage unreadable after the second refresh"; exit 1; }
echo "after:  five_hour percent=$after_pct resets_at=$after_reset"

# resets_at is the hard signal: a model call would create a window (None ->
# set) or leave an existing boundary fixed while percent climbs. An auth-only
# refresh moves neither.
if [ "$before_reset" != "$after_reset" ]; then
  echo "FAIL: five_hour resets_at changed ($before_reset -> $after_reset) — the refresh advanced a window!"
  exit 1
fi
if [ "$before_pct" != "$after_pct" ]; then
  echo "WARN: five_hour percent changed ($before_pct -> $after_pct). Expected only if you used this"
  echo "      account elsewhere during the run; otherwise investigate — a refresh must not burn budget."
fi
echo "PASS: no 5-hour window advance (resets_at unchanged across a refresh)."

echo "== live keep-warm proof PASSED =="
