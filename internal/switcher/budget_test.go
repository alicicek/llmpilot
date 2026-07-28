package switcher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// nearExpiryCred returns a credential expiring 5 minutes after base — inside
// the 10-minute switch lead, so a freshen actually attempts a POST.
func nearExpiryCred(tok string, base time.Time) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(
		`{"claudeAiOauth":{"accessToken":%q,"refreshToken":"r-%s","expiresAt":%d}}`,
		tok, tok, base.Add(5*time.Minute).UnixMilli()))
}

// countingRefresher counts POSTs and returns rotating results (or a fixed
// error). Injected as the engine's TokenRefresher — no network ever.
type countingRefresher struct {
	mu    sync.Mutex
	posts int
	fail  error
	base  time.Time
}

func (c *countingRefresher) refresh(_ context.Context, refreshToken string) (anthropic.RefreshResult, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.posts++
	if c.fail != nil {
		return anthropic.RefreshResult{}, c.fail
	}
	return anthropic.RefreshResult{
		AccessToken:  fmt.Sprintf("token-rotated-%d", c.posts),
		RefreshToken: fmt.Sprintf("r-token-rotated-%d", c.posts),
		ExpiresAt:    c.base.Add(12 * time.Hour),
	}, nil
}

// budgetSandbox seeds acct-b's backup near expiry and returns keep-warm opts
// wired to the counting refresher at a pinned clock.
func budgetSandbox(t *testing.T) (*Switcher, *fakeKeychain, *countingRefresher, KeepWarmOpts, store.Account) {
	t.Helper()
	sw, fk, _, _ := sandbox(t)
	base := time.Date(2026, 7, 25, 12, 0, 0, 0, time.UTC)
	b := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}
	if err := sw.SaveBackup(context.Background(), b.ID, nearExpiryCred("token-b-STORED", base), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	cr := &countingRefresher{base: base}
	opts := KeepWarmOpts{
		Refresh:     cr.refresh,
		RefreshLead: 10 * time.Minute,
		Now:         func() time.Time { return base },
	}
	return sw, fk, cr, opts, b
}

// TestRefreshBudgetThirdAttemptSkipped: attempts 1 and 2 POST; attempt 3
// inside the rolling 24h window is SKIPPED with an honest note — and the
// skip never blocks the caller (it returns a result, not an error).
func TestRefreshBudgetThirdAttemptSkipped(t *testing.T) {
	sw, _, cr, opts, b := budgetSandbox(t)
	ctx := context.Background()
	for i := 1; i <= 2; i++ {
		res, err := sw.KeepWarm(ctx, b, opts)
		if err != nil || !res.Rotated {
			t.Fatalf("attempt %d: rotated=%v err=%v (skip=%q)", i, res.Rotated, err, res.Skipped)
		}
		// Keep the backup near expiry so the next attempt reaches the gate.
		if err := sw.SaveBackup(ctx, b.ID, nearExpiryCred(fmt.Sprintf("token-b-%d", i), opts.now()), oauthJSON("b@example.dev")); err != nil {
			t.Fatal(err)
		}
	}
	res, err := sw.KeepWarm(ctx, b, opts)
	if err != nil {
		t.Fatalf("attempt 3 must skip, not error: %v", err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, "budget exhausted") {
		t.Fatalf("attempt 3: rotated=%v skip=%q", res.Rotated, res.Skipped)
	}
	if cr.posts != 2 {
		t.Fatalf("POSTs issued = %d, want exactly 2", cr.posts)
	}
	t.Logf("attempt 3 skipped: %q (2 POSTs issued)", res.Skipped)
}

// TestRefreshBudgetSurvivesRestart: the attempt counter AND a tripped
// breaker persist in $LLMPILOT_HOME — a fresh Switcher (a daemon restart)
// sees both.
func TestRefreshBudgetSurvivesRestart(t *testing.T) {
	sw, fk, _, opts, b := budgetSandbox(t)
	ctx := context.Background()
	for i := 1; i <= 2; i++ {
		if res, err := sw.KeepWarm(ctx, b, opts); err != nil || !res.Rotated {
			t.Fatalf("attempt %d: %v %v", i, res, err)
		}
		if err := sw.SaveBackup(ctx, b.ID, nearExpiryCred(fmt.Sprintf("token-b-%d", i), opts.now()), oauthJSON("b@example.dev")); err != nil {
			t.Fatal(err)
		}
	}
	// "Restart": a brand-new Switcher over the same home + keychain.
	sw2 := &Switcher{Dir: sw.Dir, Keychain: fk.keychain(), Registry: sw.Registry, KeychainAccount: "tester"}
	res, err := sw2.KeepWarm(ctx, b, opts)
	if err != nil || res.Rotated || !strings.Contains(res.Skipped, "budget exhausted") {
		t.Fatalf("restart forgot the counter: rotated=%v skip=%q err=%v", res.Rotated, res.Skipped, err)
	}
	t.Logf("counter survived restart: %q", res.Skipped)

	// Trip the breaker on the fresh instance, then "restart" again — the
	// trip must persist too (atlas near-burn: a launchd bounce must not
	// re-enable probing).
	sw2.NoteTokenEndpoint429(ctx)
	sw3 := &Switcher{Dir: sw.Dir, Keychain: fk.keychain(), Registry: sw.Registry, KeychainAccount: "tester"}
	// A DIFFERENT account with budget headroom still skips: breaker is global.
	if err := sw3.SaveBackup(ctx, "acct-c", nearExpiryCred("token-c", opts.now()), oauthJSON("c@example.dev")); err != nil {
		t.Fatal(err)
	}
	c := store.Account{ID: "acct-c", Label: "c", Email: "c@example.dev"}
	res, err = sw3.KeepWarm(ctx, c, opts)
	if err != nil || res.Rotated || !strings.Contains(res.Skipped, "refresh paused") {
		t.Fatalf("restart forgot the breaker: rotated=%v skip=%q err=%v", res.Rotated, res.Skipped, err)
	}
	t.Logf("breaker survived restart and applies globally: %q", res.Skipped)
}

// TestRefreshBudgetBreakerTripsGlobally: a token-endpoint 429 on ONE
// account's refresh pauses EVERY account's freshen — throttle scope is
// unverified and the cost asymmetry decides.
func TestRefreshBudgetBreakerTripsGlobally(t *testing.T) {
	sw, _, cr, opts, b := budgetSandbox(t)
	ctx := context.Background()
	cr.fail = &anthropic.RefreshError{StatusCode: 429}
	res, err := sw.KeepWarm(ctx, b, opts)
	if err == nil || errors.Is(err, ErrLineageDead) || errors.Is(err, ErrRotationNotPersisted) {
		t.Fatalf("429 must surface as a transient error: %v (res %+v)", err, res)
	}
	// Another account, fresh budget: must be paused by the GLOBAL breaker.
	if err := sw.SaveBackup(ctx, "acct-c", nearExpiryCred("token-c", opts.now()), oauthJSON("c@example.dev")); err != nil {
		t.Fatal(err)
	}
	c := store.Account{ID: "acct-c", Label: "c", Email: "c@example.dev"}
	res, err = sw.KeepWarm(ctx, c, opts)
	if err != nil || res.Rotated || !strings.Contains(res.Skipped, "refresh paused") {
		t.Fatalf("breaker did not trip globally: rotated=%v skip=%q err=%v", res.Rotated, res.Skipped, err)
	}
	if cr.posts != 1 {
		t.Fatalf("POSTs after trip = %d, want 1 (no probing while open)", cr.posts)
	}
	t.Logf("global breaker: 429 on acct-b paused acct-c's freshen (%q)", res.Skipped)
}

// TestRefreshBudgetEarlyReturnsDoNotCharge: not-near-expiry / no-refresh-
// token / no-stored-expiry return early WITHOUT a POST and WITHOUT charging.
func TestRefreshBudgetEarlyReturnsDoNotCharge(t *testing.T) {
	sw, _, cr, opts, b := budgetSandbox(t)
	ctx := context.Background()
	cases := []struct {
		name string
		cred json.RawMessage
	}{
		{"not near expiry", credJSON("token-b-STORED")}, // expires 2100
		{"no refresh token", json.RawMessage(fmt.Sprintf(`{"claudeAiOauth":{"accessToken":"t","expiresAt":%d}}`, opts.now().Add(5*time.Minute).UnixMilli()))},
		{"no stored expiry", json.RawMessage(`{"claudeAiOauth":{"accessToken":"t","refreshToken":"r-x"}}`)},
	}
	for _, c := range cases {
		if err := sw.SaveBackup(ctx, b.ID, c.cred, oauthJSON("b@example.dev")); err != nil {
			t.Fatal(err)
		}
		res, err := sw.KeepWarm(ctx, b, opts)
		if err != nil || res.Rotated {
			t.Fatalf("%s: rotated=%v err=%v", c.name, res.Rotated, err)
		}
	}
	if cr.posts != 0 {
		t.Fatalf("early returns issued %d POSTs", cr.posts)
	}
	doc, err := sw.loadBudget()
	if err != nil {
		t.Fatal(err)
	}
	if len(doc.Attempts[b.ID]) != 0 {
		t.Fatalf("early returns charged the budget: %v", doc.Attempts)
	}
	t.Logf("early returns: 0 POSTs, 0 budget charges")
}

// TestRefreshBudgetConcurrentProcessesLoseNothing: two Switcher instances
// (the daemon and a CLI on one home) charging concurrently under the
// .budget.lock lose no increment — unserialized read-modify-write would
// silently double the cap.
func TestRefreshBudgetConcurrentProcessesLoseNothing(t *testing.T) {
	sw, fk, _, opts, _ := budgetSandbox(t)
	sw2 := &Switcher{Dir: sw.Dir, Keychain: fk.keychain(), Registry: sw.Registry, KeychainAccount: "tester"}
	ctx := context.Background()
	var wg sync.WaitGroup
	for i, s := range []*Switcher{sw, sw2} {
		wg.Add(1)
		go func(i int, s *Switcher) {
			defer wg.Done()
			if _, ok, err := s.chargeRefreshAttempt(ctx, fmt.Sprintf("acct-conc-%d", i), opts.now(), 0); !ok || err != nil {
				t.Errorf("charge %d: ok=%v err=%v", i, ok, err)
			}
		}(i, s)
	}
	wg.Wait()
	doc, err := sw.loadBudget()
	if err != nil {
		t.Fatal(err)
	}
	total := len(doc.Attempts["acct-conc-0"]) + len(doc.Attempts["acct-conc-1"])
	if total != 2 {
		t.Fatalf("concurrent charges recorded = %d, want 2 (an increment was lost)", total)
	}
	t.Logf("concurrent charges from two instances: both recorded")
}

// TestRefreshBudgetFileHoldsNoTokenMaterial: the budget file is timestamps
// and breaker state ONLY (the cache rule).
func TestRefreshBudgetFileHoldsNoTokenMaterial(t *testing.T) {
	sw, _, _, opts, b := budgetSandbox(t)
	ctx := context.Background()
	if res, err := sw.KeepWarm(ctx, b, opts); err != nil || !res.Rotated {
		t.Fatalf("%v %v", res, err)
	}
	sw.NoteTokenEndpoint429(ctx)
	path, _ := sw.budgetPath()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"token-", "r-token", "accessToken", "refreshToken", "Bearer"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("budget file leaks %q:\n%s", secret, data)
		}
	}
	t.Logf("budget file: attempts + breaker state only, no token material")
}

// TestRefreshBudgetHonestRefusalWhileOpen mirrors `account refresh` against
// an open breaker: the engine returns the honest refusal reason the CLI
// prints verbatim ("no refresh for X: <reason>").
func TestRefreshBudgetHonestRefusalWhileOpen(t *testing.T) {
	sw, _, _, opts, b := budgetSandbox(t)
	ctx := context.Background()
	sw.NoteTokenEndpoint429(ctx)
	opts.RefreshLead = 1000 * time.Hour // the CLI's forced lead
	res, err := sw.KeepWarm(ctx, b, opts)
	if err != nil || res.Rotated {
		t.Fatalf("open breaker must refuse, not error/rotate: %v %v", res, err)
	}
	if !strings.Contains(res.Skipped, "refresh paused") || !strings.Contains(res.Skipped, "cooldown") {
		t.Fatalf("refusal not honest enough: %q", res.Skipped)
	}
	t.Logf("`account refresh` while open → honest refusal: %q", res.Skipped)
}

// TestRefreshBudgetRotationNotPersistedAborts is the finding-#8 split,
// proven not just decided: a store failure AFTER the server rotated surfaces
// ErrRotationNotPersisted (the switch path ABORTS on it), while a transient
// 429/network failure is a plain error the switch proceeds past.
func TestRefreshBudgetRotationNotPersistedAborts(t *testing.T) {
	sw, fk, _, opts, b := budgetSandbox(t)
	ctx := context.Background()
	// Fail the backup write that follows a successful POST: the write is a
	// keychain Set — fail every Set after the rotation POST by swapping in a
	// failing keychain mid-flight is racy; instead fail on the call index.
	// Call order inside keepWarmBackup: 1 readJournal, 2 LoadBackup,
	// 3 globalLiveCred Get, 4 SaveBackup(rotated) ← fail here.
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{4: true}}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}
	_, err := sw.KeepWarm(ctx, b, opts)
	if !errors.Is(err, ErrRotationNotPersisted) {
		t.Fatalf("store-failure class = %v, want ErrRotationNotPersisted", err)
	}
	t.Logf("rotation-persisted-but-store-failed → ErrRotationNotPersisted (switch aborts): %v", err)

	// Transient class: a network error before rotation → plain error, the
	// stored credential untouched, NOT the abort sentinel.
	sw.Keychain = fk.keychain()
	if err := sw.SaveBackup(ctx, b.ID, nearExpiryCred("token-b-KEEP", opts.now()), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	cr2 := &countingRefresher{fail: fmt.Errorf("dial tcp: network unreachable")}
	opts.Refresh = cr2.refresh
	_, err = sw.KeepWarm(ctx, b, opts)
	if err == nil || errors.Is(err, ErrRotationNotPersisted) || errors.Is(err, ErrLineageDead) {
		t.Fatalf("transient class = %v, want a plain error", err)
	}
	stored, _, lerr := sw.LoadBackup(ctx, b.ID)
	if lerr != nil || !strings.Contains(string(stored), "token-b-KEEP") {
		t.Fatalf("transient failure mutated the stored credential: %s %v", stored, lerr)
	}
	t.Logf("transient failure → plain error, stored credential untouched (switch proceeds un-freshened)")
}
