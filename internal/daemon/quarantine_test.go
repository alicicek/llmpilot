package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestQuarantinePersistSurvivesRestart: a dead-lineage marking must outlive
// the daemon process — a launchd bounce that forgot it would let autopilot
// re-nominate the dead account and adopt silently resurrect the lineage.
func TestQuarantinePersistSurvivesRestart(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st}
	d.init()
	d.QuarantineDeadLineage(context.Background(), "a", "sha256:deadbeef")

	// "Restart": a brand-new Daemon over the same store home.
	d2 := &Daemon{Store: st}
	d2.init()
	d2.mu.Lock()
	fp, ok := d2.quarantine["a"]
	note := d2.tokenNotes["a"]
	d2.mu.Unlock()
	if !ok || fp != "sha256:deadbeef" {
		t.Fatalf("restart forgot the quarantine: %q %v", fp, ok)
	}
	if note != deadLineageNote {
		t.Fatalf("restart forgot the honest note: %q", note)
	}
	if !d2.IsLineageDead("sha256:deadbeef") {
		t.Fatal("IsLineageDead lost the fingerprint across restart")
	}
	t.Logf("quarantine + note survived a daemon restart (fingerprint-keyed file)")
}

// TestQuarantinePersistLiftSurvivesRestart: the clear-on-active lift must
// persist too — a restart must not resurrect a lifted quarantine.
func TestQuarantinePersistLiftSurvivesRestart(t *testing.T) {
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
	d.QuarantineDeadLineage(context.Background(), "a", "sha256:deadbeef")
	d.pollDue(context.Background()) // observed active → lift

	d2 := &Daemon{Store: st}
	d2.init()
	d2.mu.Lock()
	_, still := d2.quarantine["a"]
	d2.mu.Unlock()
	if still {
		t.Fatal("lifted quarantine resurrected by a restart")
	}
	if d2.IsLineageDead("sha256:deadbeef") {
		t.Fatal("lifted lineage still reported dead after restart")
	}
	t.Logf("clear-on-active lift persisted across restart")
}

// TestQuarantinePersistFileHoldsNoTokenMaterial: the quarantine file is
// fingerprints + account IDs + timestamps only (the cache rule).
func TestQuarantinePersistFileHoldsNoTokenMaterial(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st}
	d.init()
	d.QuarantineDeadLineage(context.Background(), "a", "sha256:deadbeef")
	data, err := os.ReadFile(filepath.Join(st.Home(), quarantineFile))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"accessToken", "refreshToken", "token-", "Bearer"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("quarantine file leaks %q:\n%s", secret, data)
		}
	}
	t.Logf("quarantine file: fingerprint-keyed metadata only")
}

// TestQuarantinePersistConcurrentWritesAllSurvive is the Codex review P2:
// concurrent dead-lineage discoveries must not lose a quarantine to an
// out-of-order rename. Run under -race.
func TestQuarantinePersistConcurrentWritesAllSurvive(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st}
	d.init()
	const n = 12
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			d.QuarantineDeadLineage(context.Background(),
				fmt.Sprintf("acct-%d", i), fmt.Sprintf("sha256:dead-%d", i))
		}(i)
	}
	wg.Wait()

	// A fresh daemon (restart) must see every quarantine on disk.
	d2 := &Daemon{Store: st}
	d2.init()
	d2.mu.Lock()
	got := len(d2.quarantine)
	d2.mu.Unlock()
	if got != n {
		t.Fatalf("after concurrent persists + restart: %d quarantines survived, want %d (an out-of-order rename dropped one)", got, n)
	}
	t.Logf("all %d concurrent quarantine writes survived a restart", n)
}
