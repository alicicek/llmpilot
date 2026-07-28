package switcher

import (
	"context"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestFreshenStandsDownOnJournal is the adversarial-review P1 (#3): a
// leftover swap journal means the config identity may not describe the live
// credential. FreshenBackup — whose ONLY attribution is that config
// identity — must stand down, or it destroys the state the journal exists
// to let the next swap recover.
func TestFreshenStandsDownOnJournal(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	if err := sw.SaveBackup(ctx, "acct-a", credJSON("token-a-LIVE"), oauthJSON("a@example.dev")); err != nil {
		t.Fatal(err)
	}
	// The live slot holds an UNKNOWN rotated lineage (in no backup, so the
	// fingerprint guard is blind to it) while config still reads a@ (so the
	// config guard passes). ONLY the journal guard can stand this down — this
	// is the exact case the fingerprint guard cannot see (fix-delta review:
	// the earlier fixture reused b's backup credential and was caught by the
	// fingerprint guard instead, making the journal guard untested).
	fk.mu.Lock()
	fk.items[dir.KeychainService()+"\x00tester"] = credJSON("token-a-ROTATED-UNKNOWN")
	fk.mu.Unlock()
	if err := sw.writeJournal(ctx, swapJournal{FromID: "acct-a", ToID: "acct-b", FromCredHash: credHash(credJSON("token-a-LIVE"))}); err != nil {
		t.Fatal(err)
	}

	changed, err := sw.FreshenBackup(ctx, Identity{ID: "acct-a", Email: "a@example.dev"})
	if err != nil {
		t.Fatalf("freshen: %v", err)
	}
	if changed {
		t.Fatal("freshen wrote while a journal was pending — recovery state destroyed")
	}
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if strings.Contains(backup, "ROTATED-UNKNOWN") {
		t.Fatalf("P1 REGRESSION: freshen captured an unknown lineage under acct-a while a journal was pending:\n%s", backup)
	}
	if !strings.Contains(backup, "token-a-LIVE") {
		t.Fatalf("acct-a backup mutated: %s", backup)
	}
	t.Logf("freshen stood down on the pending journal (fingerprint guard blind to this lineage) — recovery state intact")
}

// TestFreshenSkipsCredentialOfAnotherAccount is the adversarial-review P1
// (#2): after a swap, a stale Claude Code session of the PREVIOUS account
// can write its (verifiably registered) credential into the global slot.
// Freshen's config-identity guard is a tautology in production, so the
// fingerprint anti-poisoning guard must refuse to capture a credential that
// verifiably belongs to a different account.
func TestFreshenSkipsCredentialOfAnotherAccount(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	// Two registered accounts, each with its own backup (both indexed).
	if err := sw.SaveBackup(ctx, "acct-a", credJSON("token-a-LIVE"), oauthJSON("a@example.dev")); err != nil {
		t.Fatal(err)
	}
	if err := sw.SaveBackup(ctx, "acct-b", credJSON("token-b-STORED"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	// The config dir reads b (we just swapped to b), but a stale CC session of
	// a wrote a's credential into the live slot.
	writeConfig(t, dir, "b@example.dev", `{"projects":{}}`)
	fk.mu.Lock()
	fk.items[dir.KeychainService()+"\x00tester"] = credJSON("token-a-LIVE")
	fk.mu.Unlock()
	_ = store.Account{} // keep the store import honest

	changed, err := sw.FreshenBackup(ctx, Identity{ID: "acct-b", Email: "b@example.dev"})
	if err != nil {
		t.Fatalf("freshen: %v", err)
	}
	if changed {
		t.Fatal("freshen captured another account's credential under acct-b")
	}
	backupB := string(fk.items[BackupService+"\x00acct-b"])
	if strings.Contains(backupB, "token-a-LIVE") {
		t.Fatalf("P1 REGRESSION: a's credential poisoned acct-b's backup:\n%s", backupB)
	}
	if !strings.Contains(backupB, "token-b-STORED") {
		t.Fatalf("acct-b backup mutated: %s", backupB)
	}
	t.Logf("freshen refused a credential that verifiably belongs to acct-a — acct-b's backup untouched")
}
