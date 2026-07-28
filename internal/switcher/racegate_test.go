package switcher

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestSwapUnderConcurrentCCRefresh is THE GATE: a swap racing a
// simulated Claude Code refresh — a goroutine that holds the REAL
// .oauth_refresh.lock (mkdir mutex, 10s stale, exactly like the binary),
// rotates the live credential's refresh token mid-flight, and writes back —
// must end with:
//   - the TARGET credential installed byte-exact,
//   - the outgoing account's ROTATED token in its backup (the pre-rotation
//     token is server-dead — backing IT up is the clobber hazard),
//   - no empty or mixed write anywhere.
//
// Fixtures only: the test asserts LLMPILOT_TEST + a throwaway keychain
// before printing anything.
func TestSwapUnderConcurrentCCRefresh(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	// Protocol 10, asserted mechanically before any output.
	if os.Getenv("LLMPILOT_TEST") == "" {
		t.Fatal("LLMPILOT_TEST not set — refusing to run the race gate outside the sandbox")
	}
	if err := anthropic.AssertThrowawayKeychain(sw.Keychain.File); err != nil {
		t.Fatalf("keychain is not a throwaway: %v", err)
	}
	t.Logf("sandbox asserted: LLMPILOT_TEST=1, throwaway keychain %s", sw.Keychain.File)

	liveBefore := append([]byte(nil), fk.items[dir.KeychainService()+"\x00tester"]...)
	targetStored, _, err := sw.LoadBackup(ctx, "acct-b")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("before: live(outgoing) fingerprint %s", anthropic.CredFingerprint(liveBefore))
	t.Logf("before: target(stored) fingerprint %s", anthropic.CredFingerprint(targetStored))

	sw.LockTimeout = 5 * time.Second
	lockHeld := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	refresherErr := make(chan error, 1)
	go func() {
		defer wg.Done()
		// Simulated CC refresh: hold the real oauth_refresh mkdir lock across
		// a "network round-trip", rotating the refresh token mid-flight.
		l, err := acquireLock(ctx, dir.OAuthRefreshLockPath(), 10*time.Second, 5*time.Second)
		if err != nil {
			close(lockHeld)
			refresherErr <- err
			return
		}
		close(lockHeld)
		fk.mu.Lock()
		cur := string(fk.items[dir.KeychainService()+"\x00tester"])
		fk.mu.Unlock()
		time.Sleep(150 * time.Millisecond)
		rotated := strings.NewReplacer(
			"token-a-LIVE", "token-a-ROTATED2",
			"r-token-a-LIVE", "r-token-a-ROTATED2",
		).Replace(cur)
		fk.mu.Lock()
		fk.items[dir.KeychainService()+"\x00tester"] = []byte(rotated)
		fk.mu.Unlock()
		l.release()
		refresherErr <- nil
	}()

	<-lockHeld // the swap must find CC's lock held and wait it out
	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap under concurrent refresh: %v\n%s", err, out.String())
	}
	wg.Wait()
	if err := <-refresherErr; err != nil {
		t.Fatalf("refresher: %v", err)
	}

	// 1. Target installed byte-exact (structural equality — the adapter
	// hands back the exact stored bytes).
	live := fk.items[dir.KeychainService()+"\x00tester"]
	if !jsonEqual(live, targetStored) {
		t.Fatalf("installed credential is not byte-exact the target:\nlive:   %s\nstored: %s", live, targetStored)
	}
	// 2. The outgoing account's ROTATED token is in its backup.
	backupCred, _, err := sw.LoadBackup(ctx, "acct-a")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(backupCred), "r-token-a-ROTATED2") {
		t.Fatalf("backup holds a pre-rotation (server-dead) token:\n%s\n%s", backupCred, out.String())
	}
	// 3. No empty or mixed write anywhere in the store.
	fk.mu.Lock()
	defer fk.mu.Unlock()
	for k, v := range fk.items {
		if len(v) == 0 {
			t.Fatalf("EMPTY item at %q", k)
		}
		var probe map[string]json.RawMessage
		if err := json.Unmarshal(v, &probe); err != nil {
			t.Fatalf("unparseable (mixed?) item at %q: %s", k, v)
		}
		if strings.Contains(string(v), "token-a-") && strings.Contains(string(v), "token-b-") {
			t.Fatalf("MIXED credential write at %q: %s", k, v)
		}
	}
	t.Logf("after: live(installed) fingerprint %s", anthropic.CredFingerprint(live))
	t.Logf("after: outgoing backup fingerprint %s (rotated lineage)", anthropic.CredFingerprint(backupCred))
	t.Logf("GATE: swap under concurrent CC refresh left exact, coherent credentials")
}
