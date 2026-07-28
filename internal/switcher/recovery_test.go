package switcher

import (
	"context"
	"errors"
	"fmt"
	"os"
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

// TestRecoverySpliceFailureRollsBackKeychain: keychain write lands, splice fails →
// the pre-swap credential must be restored and the journal cleared.
func TestRecoverySpliceFailureRollsBackKeychain(t *testing.T) {
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

// TestRecoveryRetryDoesNotClobberBackup pins the adversarial-review
// P0: swap a→b dies after the keychain write AND the rollback also fails
// (journal survives). The config still claims a while the live credential is
// b's. The retry must NOT upsert b's token over a's backup.
func TestRecoveryRetryDoesNotClobberBackup(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	// Simulate the dead swap's leftovers by hand: the write LANDED b's
	// credential (live slot == b's target cred, unrotated), config identity
	// still a, journal records both the pre-swap From hash and the target
	// hash. The exact-target-hash match is what proves the write landed.
	aCred := fk.items[dir.KeychainService()+"\x00tester"]
	bCred := credJSON("token-b-STORED")
	if err := sw.writeJournal(ctx, swapJournal{
		FromID: "acct-a", ToID: "acct-b", FromCredHash: credHash(aCred), ToCredHash: credHash(bCred),
	}); err != nil {
		t.Fatal(err)
	}
	fk.items[dir.KeychainService()+"\x00tester"] = bCred
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
	if !strings.Contains(out.String(), "recovering") {
		t.Fatalf("transcript does not mention recovery:\n%s", out.String())
	}
}

// TestRecoveryAmbiguousRotationIsPreservedNotMisattributed is the Codex
// review P1: a swap kept its journal on a subprocess error whose write never
// landed, then the OUTGOING session refreshed — so the live credential is
// the outgoing account's rotated token, matching NEITHER the pre-swap From
// hash nor the target hash. The old "!= FromCredHash ⇒ it's the target's"
// heuristic saved that outgoing credential over the TARGET's valid backup.
// Recovery must instead PRESERVE it (stash) and overwrite no backup.
func TestRecoveryAmbiguousRotationIsPreservedNotMisattributed(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	// b (the target) has a good backup we must not poison.
	if err := sw.SaveBackup(ctx, "acct-b", credJSON("token-b-GOOD"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	// Journal from a dead a→b swap: From=a's pre-swap hash, To=b's target
	// hash. Neither matches the live slot below.
	if err := sw.writeJournal(ctx, swapJournal{
		FromID: "acct-a", ToID: "acct-b",
		FromCredHash: credHash(credJSON("token-a-PRESWAP")),
		ToCredHash:   credHash(credJSON("token-b-GOOD")),
	}); err != nil {
		t.Fatal(err)
	}
	// The write never landed; a's session then refreshed — live slot holds
	// a's ROTATED credential (unknown to any backup/index).
	aRotated := credJSON("token-a-ROTATED-AFTER-DEATH")
	fk.mu.Lock()
	fk.items[dir.KeychainService()+"\x00tester"] = aRotated
	fk.mu.Unlock()
	writeConfig(t, dir, "a@example.dev", `{"projects":{}}`)

	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}

	// b's backup MUST be untouched — never poisoned with a's rotated token.
	backupB := string(fk.items[BackupService+"\x00acct-b"])
	if strings.Contains(backupB, "ROTATED-AFTER-DEATH") {
		t.Fatalf("P1 REGRESSION: outgoing credential misattributed to the target's backup:\n%s", backupB)
	}
	if !strings.Contains(backupB, "token-b-GOOD") {
		t.Fatalf("b's good backup was altered: %s", backupB)
	}
	// a's rotated credential is preserved in the stash, not lost.
	entries, _ := sw.StashEntries()
	if len(entries) != 1 {
		t.Fatalf("ambiguous live credential not preserved in the stash: %v", entries)
	}
	t.Logf("ambiguous rotation preserved in the stash; target backup untouched")
}

// TestRecoveryJournalClearedOnCleanSwap: the journal must not outlive a verified swap.
func TestRecoveryJournalClearedOnCleanSwap(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	if err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatal(err)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal left behind after a clean swap")
	}
}

// TestRecoveryKeychainWriteJournalFailureLeavesStateIntact: a keychain
// failure during the pre-mutation journal write must leave pre-swap state
// fully intact and no journal behind (nothing was mutated yet). The
// SUBPROCESS-error-on-the-target-write path (a landed-then-killed write that
// must KEEP the journal) is covered separately by
// TestRecoveryTargetSetSubprocessErrorKeepsJournal — a service-targeted
// failer, not brittle call-index injection.
func TestRecoveryKeychainWriteJournalFailureLeavesStateIntact(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{}}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}

	// Call order through the fake: 1 LoadBackup(target), 2 Get(cur),
	// 3 readJournal, 4 SaveBackup(cur), 5 LoadBackup(target under lock),
	// 6 writeJournal, 7 target Set. Failing call 6 aborts at the journal
	// write — before any credential mutation — so pre-swap state is intact
	// and no journal is left behind.
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
		t.Fatal("journal present after a journal-write failure (nothing should have been written)")
	}
}

// TestRecoveryBackupFailureAbortsBeforeMutation: the pre-mutation backup failing must
// abort the swap before any journal or credential write.
func TestRecoveryBackupFailureAbortsBeforeMutation(t *testing.T) {
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

// TestRecoveryStashFailureAbortsBeforeMutation: the stash leg failing (a
// foreign outgoing credential that cannot be preserved) aborts with the
// slot, config, and journal all untouched.
func TestRecoveryStashFailureAbortsBeforeMutation(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	writeConfig(t, dir, "stranger@example.dev", `{}`)
	if err := sw.Keychain.Set(context.Background(), dir.KeychainService(), "tester", credJSON("token-foreign-LIVE")); err != nil {
		t.Fatal(err)
	}
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{4: true}} // first Set inside the locked span = the stash write
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}
	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "could not be stashed") {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-foreign-LIVE") {
		t.Fatal("slot mutated by an aborted swap")
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal written before the stash succeeded")
	}
	t.Logf("recovery: stash failure aborted before any mutation")
}

// TestRecoveryCredFileSpliceFailureRollsBack: the credentials-file splice
// failing (after the keychain write) rolls the keychain back and leaves the
// config identity untouched.
func TestRecoveryCredFileSpliceFailureRollsBack(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	credFile := dir.CredentialsFilePath()
	if err := os.WriteFile(credFile, []byte(`{"claudeAiOauth":{"accessToken":"token-a-LIVE","refreshToken":"r-token-a-LIVE","expiresAt":4102444800000},"mcpOauth":{"keep":"me"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("/usr/bin/chflags", "uchg", credFile).CombinedOutput(); err != nil {
		t.Skipf("chflags unavailable: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/chflags", "nouchg", credFile).Run() })

	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "credentials file splice failed") {
		t.Fatalf("err = %v\n%s", err, out.String())
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("keychain not rolled back after credentials-file splice failure")
	}
	if got := readEmail(t, dir); got != "a@example.dev" {
		t.Fatalf("config mutated: %s", got)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal not cleared after a successful rollback")
	}
	t.Logf("recovery: credentials-file splice failure rolled back the keychain, config untouched")
}

// TestRecoveryConfigSpliceFailureRestoresCredFile: the oauthAccount splice
// failing AFTER the credentials file was spliced restores the file's prior
// bytes and rolls back the keychain.
func TestRecoveryConfigSpliceFailureRestoresCredFile(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	credFile := dir.CredentialsFilePath()
	prior := []byte(`{"claudeAiOauth":{"accessToken":"token-a-LIVE","refreshToken":"r-token-a-LIVE","expiresAt":4102444800000},"mcpOauth":{"keep":"me"}}`)
	if err := os.WriteFile(credFile, prior, 0o600); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("/usr/bin/chflags", "uchg", dir.ConfigJSONPath()).CombinedOutput(); err != nil {
		t.Skipf("chflags unavailable: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/chflags", "nouchg", dir.ConfigJSONPath()).Run() })

	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "oauthAccount splice failed") {
		t.Fatalf("err = %v\n%s", err, out.String())
	}
	after, rerr := os.ReadFile(credFile)
	if rerr != nil {
		t.Fatal(rerr)
	}
	if string(after) != string(prior) {
		t.Fatalf("credentials file not restored:\n%s", after)
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("keychain not rolled back")
	}
	t.Logf("recovery: config splice failure restored the credentials file and rolled back the keychain")
}

// TestRecoveryVerifyFailureJournalRecoverable: a verify failure keeps the
// journal, and a FOLLOW-UP swap recovers attribution from it — the journal
// is proven recoverable, not just retained.
func TestRecoveryVerifyFailureJournalRecoverable(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	lk := &lyingKeychain{fakeKeychain: fk, lieService: dir.KeychainService(), lieAfter: 6}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: lk.run}
	err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "verify") {
		t.Fatalf("err = %v, want verify failure", err)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; !ok {
		t.Fatal("journal missing after verify failure")
	}
	// Follow-up swap with an honest keychain: recovery attributes the live
	// credential (b's — the write DID land) to acct-b by hash, then swaps
	// back to a cleanly.
	sw.Keychain = fk.keychain()
	if err := sw.Swap(ctx, store.Account{ID: "acct-a", Label: "a", Email: "a@example.dev"}); err != nil {
		t.Fatalf("follow-up swap: %v\n%s", err, out.String())
	}
	if !strings.Contains(out.String(), "recovering") {
		t.Fatalf("follow-up swap did not run journal recovery:\n%s", out.String())
	}
	if !strings.Contains(string(fk.items[BackupService+"\x00acct-b"]), "token-b-STORED") {
		t.Fatal("recovery lost b's credential")
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("follow-up swap did not land a's credential")
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; ok {
		t.Fatal("journal left behind after recovery + clean swap")
	}
	t.Logf("recovery: verify-failure journal recovered by the follow-up swap")
}

// svcFailKeychain fails the add-generic-password (Set) targeting a specific
// service with a plain subprocess-style error (NOT ErrWriteNotAttempted) —
// the SIGKILLed-but-maybe-landed class.
type svcFailKeychain struct {
	*fakeKeychain
	failService string
}

func (s *svcFailKeychain) run(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	isAdd := (len(args) > 0 && args[0] == "-i" && strings.Contains(string(stdin), "add-generic-password")) ||
		strings.HasPrefix(joined, "add-generic-password")
	svc := flagVal(args, "-s")
	if svc == "" {
		svc = extractQuoted(string(stdin), "-s")
	}
	if isAdd && svc == s.failService {
		return nil, injectedExit{}
	}
	return s.fakeKeychain.run(ctx, stdin, name, args...)
}

type injectedExit struct{}

func (injectedExit) Error() string { return "exit status 1 (injected subprocess failure)" }
func (injectedExit) ExitCode() int { return 1 }

// TestRecoveryTargetSetSubprocessErrorKeepsJournal is the fix-delta P2: a
// subprocess error on the TARGET credential write (not a pre-exec refusal)
// may have landed the write before a SIGKILL — the journal MUST be kept for
// the next swap's hash recovery, never cleared. (The old index-based test
// failed writeJournal instead of the target Set, so it never exercised this.)
func TestRecoveryTargetSetSubprocessErrorKeepsJournal(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	sk := &svcFailKeychain{fakeKeychain: fk, failService: dir.KeychainService()}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: sk.run}
	err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil {
		t.Fatal("swap should surface the injected target-Set failure")
	}
	if errors.Is(err, ErrWriteNotAttempted) {
		t.Fatalf("a subprocess error must NOT be ErrWriteNotAttempted: %v", err)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; !ok {
		t.Fatal("journal cleared after a subprocess Set error — a landed-then-killed write is now unrecoverable")
	}
	t.Logf("subprocess error on the target write KEPT the journal for recovery")
}
