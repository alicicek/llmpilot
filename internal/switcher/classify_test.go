package switcher

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// bTarget is the swap target every classification case swaps TO.
var bTarget = store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}

// TestClassifyOutgoingOwn: the outgoing credential's email matches the
// registered active account → normal backup under its own ID.
func TestClassifyOutgoingOwn(t *testing.T) {
	sw, fk, _, out := sandbox(t)
	if err := sw.Swap(context.Background(), bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if !strings.Contains(string(fk.items[BackupService+"\x00acct-a"]), "token-a-LIVE") {
		t.Fatal("own credential not backed up under its own ID")
	}
	t.Logf("classify path OWN: backup updated for acct-a")
}

// TestClassifyOutgoingFamily: the dir is logged into ANOTHER registered
// account (not the expected active one) — its backup is updated under THAT
// account's ID; nothing is stashed.
func TestClassifyOutgoingFamily(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	// Register a third account c and make the dir hold c's identity+cred.
	accs, _ := sw.Registry.Accounts()
	accs = append(accs, store.Account{ID: "acct-c", Label: "c", Email: "c@example.dev", ConfigDir: dir.Path()})
	if err := sw.Registry.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	writeConfig(t, dir, "c@example.dev", `{}`)
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", credJSON("token-c-LIVE")); err != nil {
		t.Fatal(err)
	}
	if err := sw.Swap(ctx, bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if !strings.Contains(string(fk.items[BackupService+"\x00acct-c"]), "token-c-LIVE") {
		t.Fatal("family credential not backed up under the family account's ID")
	}
	entries, err := sw.StashEntries()
	if err != nil || len(entries) != 0 {
		t.Fatalf("family credential must not be stashed: %v %v", entries, err)
	}
	t.Logf("classify path FAMILY: backup updated for acct-c, stash empty")
}

// TestClassifyOutgoingForeign: unknown email, unknown fingerprint → the
// credential lands in the append-only stash, keyed by fingerprint, labeled
// from the local oauthAccount; and a SECOND stash of the same fingerprint
// appends nothing (no overwrite).
func TestClassifyOutgoingForeign(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	writeConfig(t, dir, "stranger@example.dev", `{}`)
	foreign := credJSON("token-foreign-LIVE")
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", foreign); err != nil {
		t.Fatal(err)
	}
	if err := sw.Swap(ctx, bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	entries, err := sw.StashEntries()
	if err != nil || len(entries) != 1 {
		t.Fatalf("stash entries = %v (%v), want exactly 1", entries, err)
	}
	e := entries[0]
	if e.Fingerprint != anthropic.CredFingerprint(foreign) {
		t.Fatalf("stash keyed %q, want the credential fingerprint", e.Fingerprint)
	}
	if e.Label != "stranger@example.dev" {
		t.Fatalf("stash label = %q, want the local oauthAccount email", e.Label)
	}
	stored := fk.items[BackupService+"\x00"+e.Key]
	if !strings.Contains(string(stored), "token-foreign-LIVE") {
		t.Fatal("stash payload does not hold the foreign credential")
	}
	t.Logf("classify path FOREIGN: stashed as %s (label %s)", e.Key, e.Label)

	// Append-only: stash the same fingerprint again — payload and entry
	// count must not change.
	before := string(stored)
	if err := sw.stashForeign(ctx, foreign, oauthJSON("stranger@example.dev")); err != nil {
		t.Fatalf("second stash: %v", err)
	}
	entries2, _ := sw.StashEntries()
	if len(entries2) != 1 || string(fk.items[BackupService+"\x00"+e.Key]) != before {
		t.Fatal("second stash of the same fingerprint modified the stash")
	}
	t.Logf("append-only: second stash of the same fingerprint appended nothing")
}

// TestClassifyOutgoingEmptyAlien: an empty/absent live slot means nothing to
// preserve — no backup write, no stash entry, swap proceeds.
func TestClassifyOutgoingEmptyAlien(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	if err := sw.Keychain.Delete(ctx, dir.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	writeConfig(t, dir, "", `{}`)
	if err := sw.Swap(ctx, bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if entries, _ := sw.StashEntries(); len(entries) != 0 {
		t.Fatalf("empty slot produced stash entries: %v", entries)
	}
	if _, ok := fk.items[BackupService+"\x00acct-a"]; ok {
		t.Fatal("empty slot produced a backup for acct-a")
	}
	t.Logf("classify path EMPTY-ALIEN: no backup, no stash, swap landed")
}

// TestClassifyOutgoingRotatedRegistered is the NEW-C case — the one defect
// class that could silently kill an account: the outgoing credential is a
// registered account's but ROTATED (fingerprint not in the index). The
// oauthAccount identity match must OUTRANK the fingerprint miss: backup
// updated under the account's ID, NEVER stashed.
func TestClassifyOutgoingRotatedRegistered(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	// Rotate a's live credential (new refresh token → new fingerprint); the
	// index only knows the seeded backups' fingerprints.
	rotated := json.RawMessage(`{"claudeAiOauth":{"accessToken":"token-a-ROTATED","refreshToken":"r-ROTATED-NEW","expiresAt":4102444800000}}`)
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", rotated); err != nil {
		t.Fatal(err)
	}
	if err := sw.Swap(ctx, bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if !strings.Contains(backup, "token-a-ROTATED") {
		t.Fatalf("rotated credential not saved to acct-a's backup:\n%s", backup)
	}
	if entries, _ := sw.StashEntries(); len(entries) != 0 {
		t.Fatalf("NEW-C violation: rotated registered credential was STASHED: %v", entries)
	}
	t.Logf("classify path ROTATED-REGISTERED: identity match outranked fingerprint miss — backup updated, never stashed")
}

// TestClassifyOutgoingStashFailureAborts: an injected stash-write failure
// must abort the swap BEFORE any overwrite — the live slot stays untouched.
func TestClassifyOutgoingStashFailureAborts(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	writeConfig(t, dir, "stranger@example.dev", `{}`)
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", credJSON("token-foreign-LIVE")); err != nil {
		t.Fatal(err)
	}
	// Fail the stash write: it is the first Set after the swap enters its
	// locked span (LoadBackup, Get, readJournal precede it).
	fkc := &failingKeychain{fakeKeychain: fk, failOn: map[int]bool{4: true}}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: fkc.run}
	err := sw.Swap(ctx, bTarget)
	if err == nil || !strings.Contains(err.Error(), "could not be stashed") {
		t.Fatalf("err = %v, want stash-abort", err)
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "token-foreign-LIVE") {
		t.Fatalf("slot mutated by an aborted swap: %s", live)
	}
	if got := readEmail(t, dir); got != "stranger@example.dev" {
		t.Fatalf("config mutated by an aborted swap: %s", got)
	}
	t.Logf("stash failure ABORTED the swap with the slot untouched")
}

// TestClassifyOutgoingLegacyUnmatchedSweep: a pre-seeded legacy unmatched-* backup
// item is migrated into the stash by the one-time sweep (unit path; the e2e
// exercises the real `security dump-keychain` enumeration).
func TestClassifyOutgoingLegacyUnmatchedSweep(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	legacy := credJSON("token-legacy-LIVE")
	if err := sw.SaveBackup(ctx, "unmatched-old.stranger_example.dev", legacy, oauthJSON("old.stranger@example.dev")); err != nil {
		t.Fatal(err)
	}
	// SaveBackup indexed it as an "account" — the sweep must reclassify it
	// into the stash regardless.
	if err := sw.SweepLegacyUnmatched(ctx); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, ok := fk.items[BackupService+"\x00unmatched-old.stranger_example.dev"]; ok {
		t.Fatal("legacy item not removed after migration")
	}
	entries, err := sw.StashEntries()
	if err != nil || len(entries) != 1 {
		t.Fatalf("stash after sweep = %v (%v), want 1 entry", entries, err)
	}
	if entries[0].Label != "old.stranger@example.dev" {
		t.Fatalf("migrated label = %q", entries[0].Label)
	}
	if !strings.Contains(string(fk.items[BackupService+"\x00"+entries[0].Key]), "token-legacy-LIVE") {
		t.Fatal("migrated payload lost")
	}
	// Idempotent: a second sweep changes nothing.
	if err := sw.SweepLegacyUnmatched(ctx); err != nil {
		t.Fatal(err)
	}
	if entries2, _ := sw.StashEntries(); len(entries2) != 1 {
		t.Fatalf("second sweep changed the stash: %v", entries2)
	}
	t.Logf("legacy unmatched-* item surfaced by the migration sweep, sweep idempotent")
}

// TestClassifyOutgoingIndexNeverHoldsTokens: the index file must contain no
// token material — fingerprint hashes and keys only (cache rule).
func TestClassifyOutgoingIndexNeverHoldsTokens(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	ctx := context.Background()
	writeConfig(t, dir, "stranger@example.dev", `{}`)
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", credJSON("token-foreign-LIVE")); err != nil {
		t.Fatal(err)
	}
	if err := sw.Swap(ctx, bTarget); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	path, ok := sw.credIndexPath()
	if !ok {
		t.Fatal("no index path")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"token-", "r-token", "accessToken", "refreshToken"} {
		if strings.Contains(string(data), secret) {
			t.Fatalf("index leaks %q:\n%s", secret, data)
		}
	}
	t.Logf("index file holds fingerprints/keys only — no token material")
}
