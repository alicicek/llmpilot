package switcher

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

// failingKeychain wraps the fake, failing the Nth security invocation —
// simulating a crash/cancel mid-mutation.
type failingKeychain struct {
	*fakeKeychain
	failOn map[int]bool // 1-based call index → fail
	calls  int
}

func (f *failingKeychain) run(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	f.calls++
	if f.failOn[f.calls] {
		return nil, fmt.Errorf("injected failure on call %d", f.calls)
	}
	return f.fakeKeychain.run(ctx, stdin, name, args...)
}

// TestSpliceFailureRollsBackKeychain: keychain write lands, splice fails →
// the pre-swap credential must be restored and the journal cleared.
func TestSpliceFailureRollsBackKeychain(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	// Break ONLY the splice's final rename: mark .claude.json immutable
	// (chflags uchg). Locks and keychain calls proceed; the rename onto the
	// immutable file fails — exactly the post-keychain-write window.
	writeConfig(t, dir, "a@example.dev", `{"k":1}`)
	if out, err := exec.Command("/usr/bin/chflags", "uchg", dir.ConfigJSONPath()).CombinedOutput(); err != nil {
		t.Skipf("chflags unavailable: %v %s", err, out)
	}
	t.Cleanup(func() {
		_ = exec.Command("/usr/bin/chflags", "nouchg", dir.ConfigJSONPath()).Run()
	})

	err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil {
		t.Fatal("swap should fail when the splice cannot write")
	}
	if !strings.Contains(err.Error(), "rolled back") && !strings.Contains(err.Error(), "keychain rolled back") {
		t.Fatalf("error does not report the rollback: %v", err)
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "token-a-LIVE") {
		t.Fatalf("keychain not rolled back to the pre-swap credential: %s\n%s", live, out.String())
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal not cleared after a successful rollback")
	}
}

// TestRetryAfterPartialSwapDoesNotClobberBackup pins the adversarial-review
// P0: swap a→b dies after the keychain write AND the rollback also fails
// (journal survives). The config still claims a while the live credential is
// b's. The retry must NOT upsert b's token over a's backup.
func TestRetryAfterPartialSwapDoesNotClobberBackup(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	// Simulate the dead swap's leftovers by hand: live credential = b's,
	// config identity still a, journal present with a's cred hash.
	aCred := fk.items[dir.KeychainService()+"\x00tester"]
	if err := sw.writeJournal(ctx, swapJournal{
		FromID: "acct-a", ToID: "acct-b", FromCredHash: credHash(aCred),
	}); err != nil {
		t.Fatal(err)
	}
	fk.items[dir.KeychainService()+"\x00tester"] = []byte(strings.Replace(
		string(credJSON("token-b-STORED")), "token-b-STORED", "token-b-ROTATED", 1))
	// a's backup holds a's real token (captured at add time)
	if err := sw.SaveBackup(ctx, "acct-a", aCred, oauthJSON("a@example.dev")); err != nil {
		t.Fatal(err)
	}

	// Retry the swap to b.
	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("retry swap: %v\n%s", err, out.String())
	}

	// a's backup must still hold a's token — NOT b's.
	backupA := string(fk.items[BackupService+"\x00acct-a"])
	if !strings.Contains(backupA, "token-a-LIVE") {
		t.Fatalf("P0 regression: a's backup clobbered:\n%s\n%s", backupA, out.String())
	}
	// b's backup was refreshed with the rotated live credential.
	backupB := string(fk.items[BackupService+"\x00acct-b"])
	if !strings.Contains(backupB, "token-b-ROTATED") {
		t.Fatalf("recovery did not capture b's rotated token:\n%s", backupB)
	}
	if !strings.Contains(out.String(), "recovering") {
		t.Fatalf("transcript does not mention recovery:\n%s", out.String())
	}
}

// TestJournalClearedOnCleanSwap: the journal must not outlive a verified swap.
func TestJournalClearedOnCleanSwap(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	if err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatal(err)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal left behind after a clean swap")
	}
}

// TestKeychainSetFailureLeavesStateIntact: the very first mutation call
// failing must leave pre-swap state fully intact and no stale journal.
func TestKeychainSetFailureLeavesStateIntact(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{}}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}

	// Call order through the fake: 1 LoadBackup(target), 2 Get(cur),
	// 3 readJournal, 4 SaveBackup(cur), 5 writeJournal, 6 target Set.
	// Failing call 6 exercises the target-Set failure path: pre-swap state
	// intact AND the just-written journal cleaned up.
	fkc.failOn[6] = true
	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil {
		t.Fatal("swap should surface the injected failure")
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "token-a-LIVE") {
		t.Fatalf("live credential mutated by a failed swap: %s", live)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal not cleared after a target-Set failure (nothing was written)")
	}
}

// TestBackupFailureAbortsBeforeMutation: the pre-mutation backup failing must
// abort the swap before any journal or credential write.
func TestBackupFailureAbortsBeforeMutation(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{4: true}}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}

	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "backing up current account") {
		t.Fatalf("err = %v", err)
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "token-a-LIVE") {
		t.Fatalf("live credential mutated: %s", live)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal written before the backup succeeded")
	}
}
