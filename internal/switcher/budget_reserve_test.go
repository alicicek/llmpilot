package switcher

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestKeepWarmBudgetReserve: an unattended caller with BudgetReserve=1 can
// spend at most one of the account's 2/24h refresh slots — the user's own
// switch-time freshen (reserve 0) still finds its slot afterwards. This is
// the P3 re-review NEW-1 guarantee: unattended revives can never lock the
// user out of their last refresh.
func TestKeepWarmBudgetReserve(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(8*time.Hour)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}

	var calls []string
	opts := func(reserve int) KeepWarmOpts {
		o := nearExpiryOpts(now, &calls)
		o.RefreshLead = 1000 * time.Hour
		o.BudgetReserve = reserve
		return o
	}

	// Reserved attempt 1: allowed (0 spent < 1 usable).
	calls = nil
	res, err := sw.KeepWarm(ctx, acctB, opts(1))
	if err != nil || !res.Rotated || len(calls) != 1 {
		t.Fatalf("first reserved attempt: %+v err=%v calls=%v", res, err, calls)
	}
	// Reserved attempt 2: the reserved slot is untouchable — skip, no POST.
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, opts(1))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, ReasonBudgetExhausted) || len(calls) != 0 {
		t.Fatalf("reserve did not bind: %+v calls=%v", res, calls)
	}
	// The USER's slot survived: an unreserved caller still refreshes.
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, opts(0))
	if err != nil || !res.Rotated || len(calls) != 1 {
		t.Fatalf("user slot was drained: %+v err=%v calls=%v", res, err, calls)
	}
	// Now the account cap is truly spent for everyone.
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, opts(0))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, ReasonBudgetExhausted) || len(calls) != 0 {
		t.Fatalf("account cap did not bind: %+v calls=%v", res, calls)
	}
}
