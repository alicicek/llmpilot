package daemon

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// fixedNow pins the daemon clock so token expiry math is deterministic.
func fixedNow() time.Time { return time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC) }

func TestKeepWarmRotatesClearsNote(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	var warmed []string
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return now.Add(20 * time.Minute), nil // near expiry
			}
			return now.Add(48 * time.Hour), nil
		},
		KeepWarm: func(_ context.Context, a store.Account) (KeepWarmStatus, error) {
			warmed = append(warmed, a.ID)
			return KeepWarmStatus{Rotated: true, Expiry: now.Add(8 * time.Hour)}, nil
		},
	}
	d.init()
	d.refreshIdle(context.Background())
	if len(warmed) != 1 || warmed[0] != "a" {
		t.Fatalf("warmed = %v, want [a]", warmed)
	}
	stt, _ := d.State(context.Background())
	for _, a := range stt.Accounts {
		if a.TokenNote != "" {
			t.Fatalf("account %s has note %q after a successful rotation", a.ID, a.TokenNote)
		}
	}
}

func TestKeepWarmSkipsActiveAccount(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	var warmed []string
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Active:      func(context.Context) string { return "a" },
		Expiry: func(context.Context, store.Account) (time.Time, error) {
			return now.Add(20 * time.Minute), nil // both near expiry
		},
		KeepWarm: func(_ context.Context, a store.Account) (KeepWarmStatus, error) {
			warmed = append(warmed, a.ID)
			return KeepWarmStatus{Rotated: true, Expiry: now.Add(8 * time.Hour)}, nil
		},
	}
	d.init()
	d.refreshIdle(context.Background())
	for _, id := range warmed {
		if id == "a" {
			t.Fatalf("keep-warm touched the ACTIVE account: %v", warmed)
		}
	}
	if len(warmed) != 1 || warmed[0] != "b" {
		t.Fatalf("warmed = %v, want only [b]", warmed)
	}
}

func TestKeepWarmDeadQuarantinesAndSelfHeals(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	fp := "sha256:deadlineage"
	warmCalls := 0
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return now.Add(10 * time.Minute), nil
			}
			return now.Add(48 * time.Hour), nil
		},
		Fingerprint: func(_ context.Context, a store.Account) (string, error) {
			return fp, nil
		},
		KeepWarm: func(_ context.Context, a store.Account) (KeepWarmStatus, error) {
			warmCalls++
			return KeepWarmStatus{Dead: true, Fingerprint: fp}, nil
		},
	}
	d.init()

	// First pass: quarantine + honest note.
	d.refreshIdle(context.Background())
	stt, _ := d.State(context.Background())
	if !strings.Contains(stt.Accounts[0].TokenNote, "sign-in expired") {
		t.Fatalf("note = %q, want the quarantine copy", stt.Accounts[0].TokenNote)
	}
	if warmCalls != 1 {
		t.Fatalf("warmCalls = %d after first pass", warmCalls)
	}

	// Second pass: still the same dead lineage → NO further POST (fingerprint
	// unchanged), note stays.
	d.refreshIdle(context.Background())
	if warmCalls != 1 {
		t.Fatalf("warmCalls = %d — quarantined account re-POSTed", warmCalls)
	}

	// A quarantined account is skipped by the poll loop.
	d.mu.Lock()
	_, quar := d.quarantine["a"]
	d.mu.Unlock()
	if !quar {
		t.Fatal("account a should be quarantined")
	}

	// Re-login: the lineage fingerprint changes → quarantine lifts and the
	// next pass refreshes successfully.
	fp = "sha256:freshlineage"
	d.KeepWarm = func(_ context.Context, a store.Account) (KeepWarmStatus, error) {
		warmCalls++
		return KeepWarmStatus{Rotated: true, Expiry: now.Add(8 * time.Hour)}, nil
	}
	d.refreshIdle(context.Background())
	if warmCalls != 2 {
		t.Fatalf("warmCalls = %d — re-login did not trigger a retry", warmCalls)
	}
	stt, _ = d.State(context.Background())
	if stt.Accounts[0].TokenNote != "" {
		t.Fatalf("note = %q, want cleared after re-login refresh", stt.Accounts[0].TokenNote)
	}
	d.mu.Lock()
	_, stillQuar := d.quarantine["a"]
	d.mu.Unlock()
	if stillQuar {
		t.Fatal("quarantine should be lifted after a successful refresh")
	}
}

// TestKeepWarmTransientFallsBackToDelegation: a transient direct-refresh error
// falls through to the `claude auth status` delegation + honest-note verify.
// TestQuarantineClearsWhenAccountBecomesActive pins the P1 fix: a quarantined
// account the user recovers by re-logging-in becomes the ACTIVE account, and
// that is the only place the quarantine can be lifted (poll skips it, the idle
// branches never run for the active account). Without the clear it is a
// permanent "sign-in expired" black hole on the user's working account.
func TestQuarantineClearsWhenAccountBecomesActive(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	active := ""
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Active:      func(context.Context) string { return active },
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			return now.Add(10 * time.Minute), nil
		},
		Fingerprint: func(context.Context, store.Account) (string, error) { return "sha256:dead", nil },
		KeepWarm: func(context.Context, store.Account) (KeepWarmStatus, error) {
			return KeepWarmStatus{Dead: true, Fingerprint: "sha256:dead"}, nil
		},
	}
	d.init()
	d.refreshIdle(context.Background()) // quarantines a (idle, dead)
	d.mu.Lock()
	_, quar := d.quarantine["a"]
	d.mu.Unlock()
	if !quar {
		t.Fatal("account a should be quarantined after a dead refresh")
	}

	// User re-logs-in to recover: a becomes the active account.
	active = "a"
	d.refreshIdle(context.Background())
	d.mu.Lock()
	_, stillQuar := d.quarantine["a"]
	d.mu.Unlock()
	if stillQuar {
		t.Fatal("quarantine must clear once the account is observed active (CC owns it)")
	}
	stt, _ := d.State(context.Background())
	for _, acc := range stt.Accounts {
		if acc.ID == "a" && acc.TokenNote != "" {
			t.Fatalf("active account still shows note %q — permanent black hole", acc.TokenNote)
		}
	}
}

func TestKeepWarmTransientFallsBackToDelegation(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	delegated := 0
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return now.Add(10 * time.Minute), nil // never moves — delegation is a no-op
			}
			return now.Add(48 * time.Hour), nil
		},
		KeepWarm: func(context.Context, store.Account) (KeepWarmStatus, error) {
			return KeepWarmStatus{}, errors.New("network down")
		},
		Refresh: func(_ context.Context, a store.Account) error {
			delegated++
			return nil
		},
	}
	d.init()
	d.refreshIdle(context.Background())
	if delegated != 1 {
		t.Fatalf("delegation called %d times, want 1 (transient fallback)", delegated)
	}
	stt, _ := d.State(context.Background())
	if !strings.Contains(stt.Accounts[0].TokenNote, "token expiring") {
		t.Fatalf("note = %q, want honest expiring warning after no-op delegation", stt.Accounts[0].TokenNote)
	}
}

func TestKeepWarm429SetsSharedRefreshPause(t *testing.T) {
	st := testStore(t)
	now := fixedNow()
	d := &Daemon{
		Store:       st,
		RefreshLead: time.Hour,
		NowFn:       fixedNow,
		Expiry: func(context.Context, store.Account) (time.Time, error) {
			return now.Add(10 * time.Minute), nil
		},
		KeepWarm: func(context.Context, store.Account) (KeepWarmStatus, error) {
			return KeepWarmStatus{}, &anthropic.RefreshError{StatusCode: 429}
		},
	}
	d.init()
	d.refreshIdle(context.Background())
	d.mu.Lock()
	paused := d.refreshPausedUntil
	d.mu.Unlock()
	if !paused.After(now) {
		t.Fatalf("refreshPausedUntil = %v, want after now on a 429", paused)
	}
}

func TestQuarantinedAccountSkippedByPoll(t *testing.T) {
	st := testStore(t)
	polled := map[string]int{}
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled[a.ID]++
			return nil, nil
		},
	}
	d.init()
	d.mu.Lock()
	d.quarantine["a"] = "sha256:dead"
	d.mu.Unlock()
	d.pollDue(context.Background())
	if polled["a"] != 0 {
		t.Fatalf("quarantined account a polled %d times, want 0", polled["a"])
	}
	if polled["b"] == 0 {
		t.Fatal("healthy account b should still be polled")
	}
}
