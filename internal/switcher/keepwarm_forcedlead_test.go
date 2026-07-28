package switcher

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestKeepWarmForcedLeadStillBudgetGated is the P3 revive composition proof,
// end to end through the REAL rotate() chain: the forced lead (1000h) makes
// a FUTURE-expiry credential due — the 401-class stale account whose stored
// expiry still looks valid gets proven live or dead instead of installed on
// looks — while the budget gate sitting BELOW the lead check still binds:
// once the 2/24h slots are spent, the forced attempt is SKIPPED with no
// POST. The lead override widens WHEN a refresh is due, never WHETHER it
// may run.
func TestKeepWarmForcedLeadStillBudgetGated(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	// A fresh-looking credential: expires 8h out, far beyond the normal lead.
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(8*time.Hour)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}

	// Normal lead: 8h-out expiry is not due — the trap the forced lead
	// exists for (a 401-marked stale account with a valid-looking expiry).
	var calls []string
	res, err := sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil || res.Skipped != "not near expiry" || len(calls) != 0 {
		t.Fatalf("want not-near-expiry skip, got %+v err=%v calls=%v", res, err, calls)
	}

	forced := func() KeepWarmOpts {
		o := nearExpiryOpts(now, &calls)
		o.RefreshLead = 1000 * time.Hour
		return o
	}
	for attempt := 1; attempt <= 2; attempt++ {
		calls = nil
		res, err = sw.KeepWarm(ctx, acctB, forced())
		if err != nil || !res.Rotated || len(calls) != 1 {
			t.Fatalf("forced attempt %d did not POST: %+v err=%v calls=%v", attempt, res, err, calls)
		}
	}
	// Slot 3: budget spent — the forced lead must NOT bypass the gate.
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, forced())
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, "budget exhausted") || len(calls) != 0 {
		t.Fatalf("forced lead bypassed the budget gate: %+v calls=%v", res, calls)
	}
}
