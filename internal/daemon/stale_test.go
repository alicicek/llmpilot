package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestExpiredIdleAccountGoesStaleWithoutNetwork pins the Phase 1 read-only
// posture: an idle account whose stored token expired is NEVER polled (no
// network, no refresh — issue #38248), keeps serving its last-known snapshot,
// and carries the honest stale flag + note.
func TestExpiredIdleAccountGoesStaleWithoutNetwork(t *testing.T) {
	st := testStore(t)
	lastKnown := &store.UsageSnapshot{
		AccountID: "a",
		AsOf:      time.Now().Add(-9 * time.Hour).UTC(),
		Buckets:   []store.Bucket{{Kind: "five_hour", Percent: 42}},
	}
	if err := st.SaveSnapshot(lastKnown); err != nil {
		t.Fatal(err)
	}
	polled := map[string]int{}
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled[a.ID]++
			return []store.Bucket{{Kind: "five_hour", Percent: 1}}, nil
		},
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return time.Now().Add(-time.Hour), nil // expired while idle
			}
			return time.Now().Add(8 * time.Hour), nil
		},
	}
	d.init()
	d.pollDue(context.Background())
	if polled["a"] != 0 {
		t.Fatalf("expired account a polled %d times, want 0 (stale gate must block the network)", polled["a"])
	}
	if polled["b"] != 1 {
		t.Fatalf("healthy account b polled %d times, want 1", polled["b"])
	}
	stt, _ := d.State(context.Background())
	for _, acc := range stt.Accounts {
		switch acc.ID {
		case "a":
			if !acc.Stale {
				t.Fatal("expired account a must carry the stale flag")
			}
			if acc.TokenNote != staleNote {
				t.Fatalf("account a note = %q, want staleNote", acc.TokenNote)
			}
			if acc.Snapshot == nil || acc.Snapshot.Buckets[0].Percent != 42 {
				t.Fatalf("account a snapshot = %+v, want the frozen last-known", acc.Snapshot)
			}
		case "b":
			if acc.Stale || acc.TokenNote != "" {
				t.Fatalf("account b stale=%v note=%q, want clean", acc.Stale, acc.TokenNote)
			}
		}
	}
}

// TestStaleClearsWhenCredentialWakes: the user used or switched to the
// account, so Claude Code refreshed the stored credential — the gate reopens
// on the next due pass, the poll resumes, and the stale mark clears.
func TestStaleClearsWhenCredentialWakes(t *testing.T) {
	st := testStore(t)
	exp := time.Now().Add(-time.Hour) // expired
	polled := 0
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled++
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return exp, nil
			}
			return time.Now().Add(8 * time.Hour), nil
		},
	}
	d.init()
	d.pollDue(context.Background())
	stt, _ := d.State(context.Background())
	if !stt.Accounts[0].Stale {
		t.Fatal("account a should be stale while its token is expired")
	}

	// The credential wakes (CC refreshed it on use).
	exp = time.Now().Add(8 * time.Hour)
	time.Sleep(2 * time.Millisecond) // let the re-check cadence lapse
	d.pollDue(context.Background())
	stt, _ = d.State(context.Background())
	if stt.Accounts[0].Stale || stt.Accounts[0].TokenNote != "" {
		t.Fatalf("account a stale=%v note=%q after the credential woke, want clean",
			stt.Accounts[0].Stale, stt.Accounts[0].TokenNote)
	}
	if polled < 3 { // b twice + a once at minimum
		t.Fatalf("polled %d times, want the woken account polled again", polled)
	}
}

// TestPoll401MarksStale: a 401 with NO stored expiry available marks the
// account stale (honest badge, no refresh) while polls keep probing at
// cadence — with an unknown expiry the poll is the only recovery signal.
// The known-expiry freeze is TestPoll401FreezesUntilCredentialChanges.
func TestPoll401MarksStale(t *testing.T) {
	st := testStore(t)
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			if a.ID == "a" {
				return nil, &anthropic.StatusError{StatusCode: 401}
			}
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
	}
	d.init()
	d.pollDue(context.Background())
	stt, _ := d.State(context.Background())
	for _, acc := range stt.Accounts {
		if acc.ID == "a" && (!acc.Stale || acc.TokenNote != staleNote) {
			t.Fatalf("401'd account a stale=%v note=%q, want stale + staleNote", acc.Stale, acc.TokenNote)
		}
		if acc.ID == "b" && (acc.Stale || acc.TokenNote != "") {
			t.Fatalf("account b stale=%v note=%q, want clean", acc.Stale, acc.TokenNote)
		}
	}
}

// TestPollSuccessClearsStaleAndNote: one proven success wipes the stale flag
// and any lingering note — live data outranks every stale/throttle mark.
func TestPollSuccessClearsStaleAndNote(t *testing.T) {
	st := testStore(t)
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
	}
	d.init()
	d.markStale("a", time.Now().Add(-time.Hour))
	d.setTokenNote("b", rateLimitedNote)
	d.pollDue(context.Background())
	stt, _ := d.State(context.Background())
	for _, acc := range stt.Accounts {
		if acc.Stale || acc.TokenNote != "" {
			t.Fatalf("account %s stale=%v note=%q after a successful poll, want clean",
				acc.ID, acc.Stale, acc.TokenNote)
		}
	}
}

// TestStaleNoteIsHonest guards the copy contract: the stale note must NOT
// promise automatic recovery (a stale idle token only heals on user action),
// and must differ from the self-clearing usage-poll 429 note.
func TestStaleNoteIsHonest(t *testing.T) {
	if strings.Contains(staleNote, "automatically") {
		t.Fatalf("stale note %q promises automatic recovery — misleading for an expired idle token", staleNote)
	}
	if !strings.Contains(staleNote, "Claude Code") || !strings.Contains(staleNote, "switch") {
		t.Fatalf("stale note %q must point the user to open/switch to the account", staleNote)
	}
	if staleNote == rateLimitedNote {
		t.Fatal("stale note must differ from the self-clearing usage-poll note")
	}
}

// TestQuarantineLiftsWhenAccountBecomesActive: a quarantined account (Phase 2
// populates the map at switch/classify time) the user recovers by
// re-logging-in becomes the ACTIVE account, and that observation is the only
// quarantine lift that needs no switch or re-poll. Without it the account is
// a permanent black hole (the poll loop skips quarantined accounts forever).
func TestQuarantineLiftsWhenAccountBecomesActive(t *testing.T) {
	st := testStore(t)
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(context.Context, store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
		Active: func(context.Context) string { return "a" },
	}
	d.init()
	d.mu.Lock()
	d.quarantine["a"] = "sha256:dead"
	d.mu.Unlock()
	d.pollDue(context.Background())
	d.mu.Lock()
	_, still := d.quarantine["a"]
	d.mu.Unlock()
	if still {
		t.Fatal("quarantine must lift once the account is observed active (CC owns it)")
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

// TestPoll401FreezesUntilCredentialChanges pins the reviewer-found flap: a
// 401 on a VALID-LOOKING stored expiry must freeze the account — "expiry
// looks valid" is exactly the 401 condition, so it must never reopen the
// gate. Only the credential actually changing (the user re-logged-in, CC
// refreshed it) resumes polling.
func TestPoll401FreezesUntilCredentialChanges(t *testing.T) {
	st := testStore(t)
	exp := time.Now().Add(2 * time.Hour) // looks valid — the server disagrees
	fail := true
	polled := 0
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			if a.ID != "a" {
				return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
			}
			polled++
			if fail {
				return nil, &anthropic.StatusError{StatusCode: 401}
			}
			return []store.Bucket{{Kind: "five_hour", Percent: 7}}, nil
		},
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return exp, nil
			}
			return time.Now().Add(8 * time.Hour), nil
		},
	}
	d.init()
	d.pollDue(context.Background()) // 401 → stale, expiry recorded
	for i := 0; i < 3; i++ {        // frozen: same credential, zero network
		time.Sleep(2 * time.Millisecond)
		d.pollDue(context.Background())
	}
	if polled != 1 {
		t.Fatalf("401'd account polled %d times, want 1 (frozen until the credential changes)", polled)
	}
	stt, _ := d.State(context.Background())
	if !stt.Accounts[0].Stale {
		t.Fatal("account a must stay stale while frozen")
	}

	// The user re-logs-in: the stored credential (and its expiry) changes.
	exp = exp.Add(8 * time.Hour)
	fail = false
	time.Sleep(2 * time.Millisecond)
	d.pollDue(context.Background())
	if polled != 2 {
		t.Fatalf("woken account polled %d times total, want 2 (gate reopened)", polled)
	}
	stt, _ = d.State(context.Background())
	if stt.Accounts[0].Stale || stt.Accounts[0].TokenNote != "" {
		t.Fatalf("account a stale=%v note=%q after recovery, want clean",
			stt.Accounts[0].Stale, stt.Accounts[0].TokenNote)
	}
}

// TestMarkStaleKeepsBaselineOnFailedRead pins the recorded-expiry baseline:
// a re-mark with a ZERO expiry (a transiently failed Keychain read during a
// 401) must preserve the known baseline — clobbering it would make the next
// successful read look like a credential change and re-open the flap. A
// re-mark with a REAL expiry still updates (a learned baseline is progress).
func TestMarkStaleKeepsBaselineOnFailedRead(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	d.init()
	base := time.Now().Add(2 * time.Hour)
	d.markStale("a", base)
	d.markStale("a", time.Time{}) // failed re-read
	d.mu.Lock()
	got := d.stale["a"]
	d.mu.Unlock()
	if !got.Equal(base) {
		t.Fatalf("recorded baseline = %v after a zero re-mark, want %v preserved", got, base)
	}
	moved := base.Add(8 * time.Hour)
	d.markStale("a", moved) // a real reading still updates
	d.mu.Lock()
	got = d.stale["a"]
	d.mu.Unlock()
	if !got.Equal(moved) {
		t.Fatalf("recorded baseline = %v after a real re-mark, want %v", got, moved)
	}
	// Zero-to-real also updates: an unknown baseline learns the expiry.
	d.markStale("b", time.Time{})
	d.markStale("b", base)
	d.mu.Lock()
	got = d.stale["b"]
	d.mu.Unlock()
	if !got.Equal(base) {
		t.Fatalf("unknown baseline = %v after learning an expiry, want %v", got, base)
	}
}

// TestStaleReopensOnEarlierExpiryRelogin pins the review P1 follow-up: a
// re-login can mint a token that expires EARLIER than the recorded baseline
// (old two-hour timestamp, fresh one-hour grant). Any CHANGE to the stored
// expiry must reopen the gate — gating on "later only" would freeze the
// recovered account forever.
func TestStaleReopensOnEarlierExpiryRelogin(t *testing.T) {
	st := testStore(t)
	exp := time.Now().Add(2 * time.Hour) // old credential: looks valid, server 401s
	fail := true
	polled := 0
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			if a.ID != "a" {
				return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
			}
			polled++
			if fail {
				return nil, &anthropic.StatusError{StatusCode: 401}
			}
			return []store.Bucket{{Kind: "five_hour", Percent: 7}}, nil
		},
		Expiry: func(_ context.Context, a store.Account) (time.Time, error) {
			if a.ID == "a" {
				return exp, nil
			}
			return time.Now().Add(8 * time.Hour), nil
		},
	}
	d.init()
	d.pollDue(context.Background()) // 401 → stale, baseline = exp
	time.Sleep(2 * time.Millisecond)
	d.pollDue(context.Background()) // frozen
	if polled != 1 {
		t.Fatalf("polled %d times while frozen, want 1", polled)
	}

	// Re-login mints a credential that expires EARLIER than the baseline.
	exp = time.Now().Add(time.Hour)
	fail = false
	time.Sleep(2 * time.Millisecond)
	d.pollDue(context.Background())
	if polled != 2 {
		t.Fatalf("polled %d times after an earlier-expiry re-login, want 2 (gate must reopen on ANY change)", polled)
	}
	stt, _ := d.State(context.Background())
	if stt.Accounts[0].Stale {
		t.Fatal("account a still stale after the re-login recovered it")
	}
}

// TestQuarantineDeadLineageBlocksPollsUntilActive pins the production
// quarantine writer: a switch-time dead-lineage discovery must stop polls and
// carry the honest note; the account being observed ACTIVE (re-login) lifts
// both.
func TestQuarantineDeadLineageBlocksPollsUntilActive(t *testing.T) {
	st := testStore(t)
	active := ""
	polled := map[string]int{}
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled[a.ID]++
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
		Active: func(context.Context) string { return active },
	}
	d.init()
	d.QuarantineDeadLineage(context.Background(), "a", "sha256:dead")

	d.pollDue(context.Background())
	if polled["a"] != 0 {
		t.Fatalf("quarantined account a polled %d times, want 0", polled["a"])
	}
	stt, _ := d.State(context.Background())
	if stt.Accounts[0].TokenNote != deadLineageNote {
		t.Fatalf("note = %q, want deadLineageNote", stt.Accounts[0].TokenNote)
	}

	// Re-login makes it active: quarantine and note lift, polling resumes.
	active = "a"
	time.Sleep(2 * time.Millisecond)
	d.pollDue(context.Background())
	if polled["a"] == 0 {
		t.Fatal("account a not polled after the quarantine lift")
	}
	stt, _ = d.State(context.Background())
	if stt.Accounts[0].TokenNote != "" {
		t.Fatalf("note = %q after the lift, want empty", stt.Accounts[0].TokenNote)
	}
}
