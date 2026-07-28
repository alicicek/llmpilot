package switcher

// Move-into-the-fleet proofs. These tests DELETE credentials, so every one of
// them runs under the two-layer sandbox (LLMPILOT_TEST + a fake keychain that
// asserts a throwaway file): a sandbox escape here would destroy a real
// sign-in.

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// moveSandbox builds a fleet dir (the swap-managed global slot, signed in as
// a@) plus a SEPARATE source dir signed in as b@ with its own Keychain item
// and a credentials file that also holds unrelated material.
func moveSandbox(t *testing.T) (*Switcher, *fakeKeychain, claudecfg.Dir, claudecfg.Dir, *store.Store) {
	t.Helper()
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	fleetPath := filepath.Join(root, "claude-fleet")
	srcPath := filepath.Join(root, "claude-src")
	for _, p := range []string{fleetPath, srcPath} {
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	fleet, src := claudecfg.DirAt(fleetPath), claudecfg.DirAt(srcPath)
	writeConfig(t, fleet, "a@example.dev", `{"projects":{"/x":{"allowed":true}}}`)
	writeConfig(t, src, "b@example.dev", `{"userSettings":{"theme":"dark"}}`)
	// The source credentials file carries a NON-credential key too: the
	// retirement must remove our block and leave that byte-identical.
	credFile := `{"claudeAiOauth":{"accessToken":"token-b-LIVE","refreshToken":"r-token-b-LIVE","expiresAt":4102444800000},"mcpOAuth":{"server":"keep-me","token":"unrelated"}}`
	if err := os.WriteFile(src.CredentialsFilePath(), []byte(credFile), 0o600); err != nil {
		t.Fatal(err)
	}

	fk := newFakeKeychain()
	kc := fk.keychain()
	ctx := context.Background()
	if err := kc.Set(ctx, fleet.KeychainService(), "tester", credJSON("token-a-LIVE")); err != nil {
		t.Fatal(err)
	}
	if err := kc.Set(ctx, src.KeychainService(), "tester", credJSON("token-b-LIVE")); err != nil {
		t.Fatal(err)
	}
	st := store.At(filepath.Join(root, "llmpilot"))
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-a", Label: "a", Email: "a@example.dev", ConfigDir: fleetPath, KeychainService: fleet.KeychainService()},
	}); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	sw := &Switcher{Dir: fleet, Keychain: kc, Registry: st, Out: &out, KeychainAccount: "tester",
		ScanDirs: func() ([]string, error) { return nil, nil }}
	t.Cleanup(func() {
		for _, secret := range []string{"token-a-LIVE", "token-b-LIVE", "r-token"} {
			if strings.Contains(out.String(), secret) {
				t.Errorf("transcript leaked %q:\n%s", secret, out.String())
			}
		}
	})
	return sw, fk, fleet, src, st
}

const movedID = "acct-b_example.dev" // sanitizeID("b@example.dev")

// TestMoveIntoFleet is the migration proof: after a move EXACTLY one readable
// copy exists (ours), the account is registered global-swappable, and Swap
// accepts it — the whole point of the verb.
func TestMoveIntoFleet(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()

	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("move: %v", err)
	}
	if res.Outcome != MoveComplete || res.Note != "" {
		t.Fatalf("outcome = %q note = %q, want a clean complete", res.Outcome, res.Note)
	}
	// Registered global-swappable (NOT pinned to the source dir).
	if res.Account.ID != movedID || res.Account.Email != "b@example.dev" || res.Account.Label != "b" {
		t.Fatalf("account = %+v", res.Account)
	}
	if res.Account.ConfigDir != fleet.Path() || res.Account.KeychainService != fleet.KeychainService() {
		t.Fatalf("account not registered on the fleet dir: %+v", res.Account)
	}
	accs, err := st.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range accs {
		if a.ID == movedID {
			found = true
			if a.ConfigDir != fleet.Path() {
				t.Fatalf("registry row is pinned: %+v", a)
			}
		}
	}
	if !found {
		t.Fatalf("moved account missing from the registry: %+v", accs)
	}

	// COPY 1 (ours) is readable.
	backup, oauthRaw, err := sw.LoadBackup(ctx, movedID)
	if err != nil {
		t.Fatalf("backup after move: %v", err)
	}
	if !strings.Contains(string(backup), "token-b-LIVE") {
		t.Fatalf("backup does not hold the moved credential: %s", backup)
	}
	if oauthEmail(oauthRaw) != "b@example.dev" {
		t.Fatalf("backup identity = %s", oauthRaw)
	}
	// COPY 2 (the source) is gone: Keychain item deleted...
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; ok {
		t.Fatal("source Keychain item survived the move")
	}
	// ...and the credentials file no longer carries a claudeAiOauth block,
	// with every other key byte-identical and NO file created elsewhere.
	data, err := os.ReadFile(src.CredentialsFilePath())
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("credentials file is not JSON after the move: %s", data)
	}
	if _, ok := doc["claudeAiOauth"]; ok {
		t.Fatalf("credentials file still holds a sign-in: %s", data)
	}
	if string(doc["mcpOAuth"]) != `{"server":"keep-me","token":"unrelated"}` {
		t.Fatalf("unrelated credential material was not preserved byte-for-byte: %s", doc["mcpOAuth"])
	}
	// The source dir's identity block is deliberately left alone (no splice
	// bypass over a foreign dir) — the retirement RECORD carries the truth.
	if got := readEmail(t, src); got != "b@example.dev" {
		t.Fatalf("source identity = %q, want it untouched", got)
	}
	rec, err := st.Retirements()
	if err != nil || len(rec.Dirs) != 1 || !rec.Dirs[0].Complete || rec.Dirs[0].ConfigDir != src.Path() {
		t.Fatalf("retirement record = %+v err=%v", rec, err)
	}
	if len(rec.CloneSuspect) != 0 {
		t.Fatalf("a complete move must not mark the account clone-suspect: %+v", rec)
	}

	// The point of the whole verb: Swap now ACCEPTS this account.
	if err := sw.Swap(ctx, res.Account); err != nil {
		t.Fatalf("swap to the moved account: %v", err)
	}
	if got := readEmail(t, fleet); got != "b@example.dev" {
		t.Fatalf("active identity after swap = %s", got)
	}
}

// TestMoveIntoFleetNeverCreatesACredentialsFile: a dir that keeps its
// credential only in the Keychain must stay that way — the retirement may
// remove, never create.
func TestMoveIntoFleetNeverCreatesACredentialsFile(t *testing.T) {
	sw, _, _, src, _ := moveSandbox(t)
	if err := os.Remove(src.CredentialsFilePath()); err != nil {
		t.Fatal(err)
	}
	if _, err := sw.MoveIntoFleet(context.Background(), src, ""); err != nil {
		t.Fatalf("move: %v", err)
	}
	if _, err := os.Stat(src.CredentialsFilePath()); !os.IsNotExist(err) {
		t.Fatalf("the move created a credentials file where none existed (err=%v)", err)
	}
}

// TestMoveIntoFleetRefusesAForeignBackup is the CAS: the target ID already
// holds ANOTHER identity's only stored sign-in. Overwriting it would destroy
// that account's copy — refuse, and leave the source untouched.
func TestMoveIntoFleetRefusesAForeignBackup(t *testing.T) {
	sw, fk, _, src, st := moveSandbox(t)
	ctx := context.Background()
	if err := sw.SaveBackup(ctx, movedID, credJSON("token-c-STORED"), oauthJSON("c@example.dev")); err != nil {
		t.Fatal(err)
	}
	_, err := sw.MoveIntoFleet(ctx, src, "")
	if !errors.Is(err, ErrStashConflict) {
		t.Fatalf("err = %v, want a stash conflict", err)
	}
	// Nothing was taken from the source, and the foreign backup survived.
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("a refused move deleted the source Keychain item")
	}
	got, _, err := sw.LoadBackup(ctx, movedID)
	if err != nil || !strings.Contains(string(got), "token-c-STORED") {
		t.Fatalf("foreign backup was clobbered: %s err=%v", got, err)
	}
	accs, _ := st.Accounts()
	for _, a := range accs {
		if a.ID == movedID {
			t.Fatalf("a refused move registered an account anyway: %+v", a)
		}
	}
}

// TestMoveIntoFleetAcceptsOurOwnOlderSnapshot: adopt-as-watched saves a
// backup, then the pinned dir's credential rotates, then the user moves. The
// stored fingerprint no longer matches — but the identity does, and identity
// OUTRANKS fingerprint (classify.go's precedence rule: the refresh token
// rotates). Refusing here would break the primary flow.
func TestMoveIntoFleetAcceptsOurOwnOlderSnapshot(t *testing.T) {
	sw, _, _, src, _ := moveSandbox(t)
	ctx := context.Background()
	if err := sw.SaveBackup(ctx, movedID, credJSON("token-b-OLD"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("move over our own older snapshot: %v", err)
	}
	if res.Outcome != MoveComplete {
		t.Fatalf("outcome = %q", res.Outcome)
	}
	got, _, err := sw.LoadBackup(ctx, movedID)
	if err != nil || !strings.Contains(string(got), "token-b-LIVE") {
		t.Fatalf("the live copy did not win: %s err=%v", got, err)
	}
	// The replaced copy is NOT lost: same identity does not prove same grant
	// (the dir could hold a genuinely separate login for this email), and the
	// stored copy may be the only one llmpilot has. It lands in the
	// append-only stash, recoverable from the cockpit.
	entries, err := sw.StashEntries()
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("the replaced sign-in was not preserved: %+v", entries)
	}
	stashed, err := sw.LoadStash(ctx, entries[0].Fingerprint)
	if err != nil || !strings.Contains(string(stashed.Credential), "token-b-OLD") {
		t.Fatalf("stash payload = %s err=%v", stashed.Credential, err)
	}
}

// TestMoveIntoFleetRefusesTheFleetsOwnDir: the global dir's sign-in IS the
// live slot. "Moving" it would delete the active credential.
func TestMoveIntoFleetRefusesTheFleetsOwnDir(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	if _, err := sw.MoveIntoFleet(context.Background(), fleet, ""); err == nil {
		t.Fatal("moving the fleet's own dir must be refused")
	}
	if _, ok := fk.items[fleet.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move deleted the ACTIVE credential")
	}
}

// failingRunner wraps the fake keychain, failing calls a test wants to fail.
func failingRunner(fk *fakeKeychain, fail func(stdin []byte, args []string) bool) StdinRunner {
	return func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		if fail(stdin, args) {
			return nil, errors.New("injected keychain failure")
		}
		return fk.run(ctx, stdin, name, args...)
	}
}

// TestMovePartialRetirementRollsBack: a failure BEFORE anything is deleted
// unwinds completely — the previous stored sign-in is restored, no account is
// registered, and the source still holds its copy. Never neither copy.
func TestMovePartialRetirementRollsBack(t *testing.T) {
	sw, fk, _, src, st := moveSandbox(t)
	ctx := context.Background()
	// A prior backup of OUR OWN older snapshot, so the rollback has something
	// to put back (the destructive case: restoring must not leave it empty).
	if err := sw.SaveBackup(ctx, movedID, credJSON("token-b-OLD"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	// Fail exactly the write that would store the moved credential.
	needle := hex.EncodeToString([]byte("token-b-LIVE"))
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: failingRunner(fk, func(stdin []byte, args []string) bool {
		joined := strings.Join(args, " ") + string(stdin)
		return strings.Contains(joined, "add-generic-password") &&
			strings.Contains(joined, BackupService) && strings.Contains(joined, needle)
	})}

	_, err := sw.MoveIntoFleet(ctx, src, "")
	if err == nil {
		t.Fatal("a failed backup write must fail the move")
	}
	if !strings.Contains(err.Error(), "nothing was deleted") {
		t.Fatalf("the error must say the source is intact, got: %v", err)
	}
	// Source untouched: both of its copies survive.
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("rollback left the source Keychain item deleted")
	}
	data, _ := os.ReadFile(src.CredentialsFilePath())
	if !bytes.Contains(data, []byte("claudeAiOauth")) {
		t.Fatalf("rollback left the source credentials file stripped: %s", data)
	}
	// No orphan registration.
	accs, _ := st.Accounts()
	for _, a := range accs {
		if a.ID == movedID {
			t.Fatalf("rollback left an account registered: %+v", a)
		}
	}
	// The previous stored sign-in is exactly as it was.
	got, _, err := sw.LoadBackup(ctx, movedID)
	if err != nil || !strings.Contains(string(got), "token-b-OLD") {
		t.Fatalf("prior backup not restored: %s err=%v", got, err)
	}
	rec, _ := st.Retirements()
	if len(rec.Dirs) != 0 {
		t.Fatalf("a rolled-back move must record no retirement: %+v", rec)
	}
}

// TestMovePartialRetirementKeepsRegistrationAndGuards: the source copy could
// not be deleted. The credential is already durable in our backups, so the
// registration STAYS — but the account is marked clone-suspect, the outcome
// says so honestly, and keep-warm then refuses to rotate it (rotating one of
// two live copies kills the other).
func TestMovePartialRetirementKeepsRegistrationAndGuards(t *testing.T) {
	sw, fk, _, src, st := moveSandbox(t)
	ctx := context.Background()
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: failingRunner(fk, func(_ []byte, args []string) bool {
		joined := strings.Join(args, " ")
		return strings.Contains(joined, "delete-generic-password") && strings.Contains(joined, src.KeychainService())
	})}

	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("a partial retirement must not fail the move: %v", err)
	}
	if res.Outcome != MoveCloneSuspect {
		t.Fatalf("outcome = %q, want clone_suspect", res.Outcome)
	}
	if !strings.Contains(res.Note, src.Path()) || !strings.Contains(res.Note, "sign in") {
		t.Fatalf("note must name the dir and what to do next: %q", res.Note)
	}
	// Registration kept, credential safe.
	accs, _ := st.Accounts()
	registered := false
	for _, a := range accs {
		if a.ID == movedID {
			registered = true
		}
	}
	if !registered {
		t.Fatal("a partial retirement must keep the registration (the credential is ours now)")
	}
	got, _, err := sw.LoadBackup(ctx, movedID)
	if err != nil || !strings.Contains(string(got), "token-b-LIVE") {
		t.Fatalf("backup missing after a partial retirement: %s err=%v", got, err)
	}
	// Marked, recorded, and guarded.
	suspect, err := st.IsCloneSuspect(movedID)
	if err != nil || !suspect {
		t.Fatalf("account not marked clone-suspect (err=%v)", err)
	}
	rec, _ := st.Retirements()
	if len(rec.Dirs) != 1 || rec.Dirs[0].Complete {
		t.Fatalf("retirement must be recorded as incomplete: %+v", rec)
	}
	// The guard: no refresh POST may go out for this account.
	acct := res.Account
	now := time.Now()
	if err := sw.SaveBackup(ctx, acct.ID, credWithExpiry("token-b-LIVE", now.Add(time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	kw, err := sw.KeepWarm(ctx, acct, KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(context.Context, string) (anthropic.RefreshResult, error) {
			t.Fatal("keep-warm refreshed a clone-suspect account")
			return anthropic.RefreshResult{}, nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if kw.Rotated || !strings.Contains(kw.Skipped, "second copy") {
		t.Fatalf("clone-suspect account was not guarded: %+v", kw)
	}
}

// TestMoveIntoFleetRefusesAnAliasOfTheFleetDir: detect follows symlinks
// (os.Stat + IsDir), so a sibling like ~/.claude-alt -> ~/.claude enumerates
// as its own dir. A string compare would call it foreign and the retirement
// would strip the ACTIVE dir's credentials file through the link — identity
// is the inode.
func TestMoveIntoFleetRefusesAnAliasOfTheFleetDir(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	alias := filepath.Join(t.TempDir(), "claude-alias")
	if err := os.Symlink(fleet.Path(), alias); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	if _, err := sw.MoveIntoFleet(context.Background(), claudecfg.DirAt(alias), ""); err == nil {
		t.Fatal("moving an alias of the fleet's own dir must be refused")
	}
	if _, ok := fk.items[fleet.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move deleted the ACTIVE credential")
	}
	data, err := os.ReadFile(fleet.CredentialsFilePath())
	if err == nil && !bytes.Contains(data, []byte("claudeAiOauth")) {
		t.Fatalf("the refused move stripped the active credentials file: %s", data)
	}
}

// TestMoveIntoFleetRefusesASecondGrantForTheLiveIdentity is the adversarial
// review's P0: the fleet's global slot is signed in as alice with grant1
// (unregistered), and another dir holds a SECOND grant for alice. Moving that
// dir would register grant2 under the ID whose live copy is grant1 — and the
// daemon's post-poll freshen of the ACTIVE account then overwrites the backup
// with grant1, after the move already deleted grant2's only other copy. The
// migration must refuse before deleting anything.
func TestMoveIntoFleetRefusesASecondGrantForTheLiveIdentity(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	// The fleet dir is signed in as the SAME email as the source, with a
	// DIFFERENT grant, and nobody is registered for it yet.
	writeConfig(t, fleet, "b@example.dev", `{"projects":{}}`)
	if err := sw.Keychain.Set(ctx, fleet.KeychainService(), "tester", credJSON("token-b-GLOBAL")); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveAccounts(nil); err != nil {
		t.Fatal(err)
	}

	_, err := sw.MoveIntoFleet(ctx, src, "")
	if err == nil {
		t.Fatal("moving a second grant for the live identity must be refused")
	}
	if !errors.Is(err, ErrMoveRefused) {
		t.Fatalf("err = %v, want a refusal the user can act on", err)
	}
	// Nothing deleted, nothing registered: both grants survive.
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move deleted the source copy")
	}
	if _, ok := fk.items[fleet.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move touched the live copy")
	}
	accs, _ := st.Accounts()
	if len(accs) != 0 {
		t.Fatalf("the refused move registered an account: %+v", accs)
	}

	// The BENIGN case — the source is a clone of the SAME live grant — still
	// moves: retiring a duplicate is exactly right.
	if err := sw.Keychain.Set(ctx, src.KeychainService(), "tester", credJSON("token-b-GLOBAL")); err != nil {
		t.Fatal(err)
	}
	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("moving a duplicate of the live grant: %v", err)
	}
	if res.Outcome != MoveComplete {
		t.Fatalf("outcome = %q", res.Outcome)
	}
}

// TestMoveRetryRepairsAPartialRetirement: the clone-suspect note tells the
// user to resolve the leftover copy. When they do and retry, the move must
// close the record out and CLEAR the mark — otherwise the rotation freeze is
// permanent (adversarial review P1).
func TestMoveRetryRepairsAPartialRetirement(t *testing.T) {
	sw, fk, _, src, st := moveSandbox(t)
	ctx := context.Background()
	base := fk.keychain()
	sw.Keychain = &Keychain{File: base.File, Run: failingRunner(fk, func(_ []byte, args []string) bool {
		joined := strings.Join(args, " ")
		return strings.Contains(joined, "delete-generic-password") && strings.Contains(joined, src.KeychainService())
	})}
	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil || res.Outcome != MoveCloneSuspect {
		t.Fatalf("setup: %+v err=%v", res, err)
	}
	if suspect, _ := st.IsCloneSuspect(movedID); !suspect {
		t.Fatal("setup: account should be clone-suspect")
	}

	// The user removes the leftover copy by hand, then retries.
	sw.Keychain = base
	delete(fk.items, src.KeychainService()+"\x00tester")
	repaired, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("retry after resolving the leftover copy: %v", err)
	}
	if repaired.Outcome != MoveComplete {
		t.Fatalf("outcome = %q, want complete", repaired.Outcome)
	}
	if suspect, _ := st.IsCloneSuspect(movedID); suspect {
		t.Fatal("the retry did not clear the clone-suspect mark — the freeze would be permanent")
	}
	// And the account rotates again.
	now := time.Now()
	acct := store.Account{ID: movedID, Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	if err := sw.SaveBackup(ctx, acct.ID, credWithExpiry("token-b", now.Add(20*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	var calls []string
	kw, err := sw.KeepWarm(ctx, acct, nearExpiryOpts(now, &calls))
	if err != nil || !kw.Rotated {
		t.Fatalf("account still frozen after the repair: %+v err=%v", kw, err)
	}
}

// TestClearCloneSuspectOnFreshSignIn: the other remedy the note names — a
// fresh sign-in mints a new grant, which makes any surviving duplicate of the
// old one irrelevant.
func TestClearCloneSuspectOnFreshSignIn(t *testing.T) {
	sw, _, _, _, st := moveSandbox(t)
	if err := st.RecordRetirement(store.RetiredDir{
		ConfigDir: "/somewhere/else", Email: "b@example.dev", AccountID: movedID, Complete: false,
	}); err != nil {
		t.Fatal(err)
	}
	if suspect, _ := st.IsCloneSuspect(movedID); !suspect {
		t.Fatal("setup: should be clone-suspect")
	}
	// A fresh grant makes the old leftover a DIFFERENT lineage, so the record
	// describing it is moot — it must be dropped, never rewritten to claim
	// the dir was proven empty.
	sw.ClearCloneSuspect(context.Background(), movedID)
	if suspect, _ := st.IsCloneSuspect(movedID); suspect {
		t.Fatal("a fresh sign-in did not clear the mark")
	}
	rec, err := st.Retirements()
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range rec.Dirs {
		if d.AccountID == movedID {
			t.Fatalf("a fresh sign-in must DROP the record, not assert it complete: %+v", d)
		}
	}
}

// TestMoveIntoFleetFailsClosedWhenTheLiveSlotIsUnreadable: the live-identity
// check is the one thing standing between the user and a destroyed grant, so
// "we could not look" must abort — not skip the check (re-review NEW-1).
func TestMoveIntoFleetFailsClosedWhenTheLiveSlotIsUnreadable(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: failingRunner(fk, func(_ []byte, args []string) bool {
		joined := strings.Join(args, " ")
		return strings.Contains(joined, "find-generic-password") && strings.Contains(joined, fleet.KeychainService())
	})}

	if _, err := sw.MoveIntoFleet(ctx, src, ""); err == nil {
		t.Fatal("an unreadable live slot must abort the move, not skip the safety check")
	}
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the aborted move deleted the source copy")
	}
	accs, _ := st.Accounts()
	for _, a := range accs {
		if a.ID == movedID {
			t.Fatalf("the aborted move registered an account: %+v", a)
		}
	}
}

// TestAddAccountKeepsADeservedCloneSuspectMark: AddAccount captures whatever
// credential is ALREADY in the dir — it mints nothing on the adopt/`init`
// path — so it must not clear a mark that says a second copy exists
// (re-review NEW-2: one `llmpilot init` disarmed the guard).
func TestAddAccountKeepsADeservedCloneSuspectMark(t *testing.T) {
	sw, _, _, src, st := moveSandbox(t)
	ctx := context.Background()
	if err := st.RecordRetirement(store.RetiredDir{
		ConfigDir: "/somewhere/leftover", Email: "b@example.dev", AccountID: movedID, Complete: false,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := sw.AddAccount(ctx, src, "", nil, "claude"); err != nil {
		t.Fatal(err)
	}
	suspect, err := st.IsCloneSuspect(movedID)
	if err != nil {
		t.Fatal(err)
	}
	if !suspect {
		t.Fatal("a re-add cleared a deserved clone-suspect mark — it captures the existing credential, it does not mint a fresh grant")
	}
	rec, _ := st.Retirements()
	for _, d := range rec.Dirs {
		if d.AccountID == movedID && d.Complete {
			t.Fatalf("a re-add asserted an unproven retirement was complete: %+v", d)
		}
	}
}

// TestFreshSignInKeepsAProvenRetirement: a proven-empty retirement record is
// the ONLY thing excluding that dir from the clone scan, and the dir keeps
// its identity block forever — so a fresh sign-in must drop the UNPROVEN
// records and keep the proven one, or the account freezes for good
// (re-review of the fix delta).
func TestFreshSignInKeepsAProvenRetirement(t *testing.T) {
	sw, _, _, src, st := moveSandbox(t)
	ctx := context.Background()
	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil || res.Outcome != MoveComplete {
		t.Fatalf("setup: %+v err=%v", res, err)
	}
	if err := st.RecordRetirement(store.RetiredDir{
		ConfigDir: "/somewhere/unproven", Email: "b@example.dev", AccountID: movedID, Complete: false,
	}); err != nil {
		t.Fatal(err)
	}

	sw.ClearCloneSuspect(ctx, movedID)

	rec, err := st.Retirements()
	if err != nil {
		t.Fatal(err)
	}
	var proven, unproven int
	for _, d := range rec.Dirs {
		if d.AccountID != movedID {
			continue
		}
		if d.Complete {
			proven++
		} else {
			unproven++
		}
	}
	if proven != 1 || unproven != 0 {
		t.Fatalf("proven=%d unproven=%d — a fresh sign-in must keep the proof and drop the doubt: %+v", proven, unproven, rec.Dirs)
	}
	if suspect, _ := st.IsCloneSuspect(movedID); suspect {
		t.Fatal("the mark survived a fresh sign-in")
	}
	// And the moved-from dir stays excluded, so the account still rotates.
	now := time.Now()
	acct := store.Account{ID: movedID, Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	if err := sw.SaveBackup(ctx, acct.ID, credWithExpiry("token-b", now.Add(20*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	sw.ScanDirs = func() ([]string, error) { return []string{src.Path()}, nil }
	var calls []string
	kw, err := sw.KeepWarm(ctx, acct, nearExpiryOpts(now, &calls))
	if err != nil || !kw.Rotated {
		t.Fatalf("the moved-from dir froze the account after a fresh sign-in: %+v err=%v", kw, err)
	}
}

// TestMoveIntoFleetSeesAFileModeLiveSlot: the fleet's slot may keep its
// credential in .credentials.json rather than the Keychain. Reading it
// Keychain-only made such a slot look EMPTY and skipped the identity check
// entirely. (The daemon's freshen reads the Keychain only, so a file-mode
// slot cannot drive the freshen-clobber chain — this guard is conservative
// on principle, not because that exact chain is reachable here.)
func TestMoveIntoFleetSeesAFileModeLiveSlot(t *testing.T) {
	sw, fk, fleet, src, _ := moveSandbox(t)
	ctx := context.Background()
	// The fleet slot: same email as the source, DIFFERENT grant, on disk only.
	writeConfig(t, fleet, "b@example.dev", `{"projects":{}}`)
	delete(fk.items, fleet.KeychainService()+"\x00tester")
	if err := os.WriteFile(fleet.CredentialsFilePath(), credJSON("token-b-FILE"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := sw.MoveIntoFleet(ctx, src, "")
	if !errors.Is(err, ErrMoveRefused) {
		t.Fatalf("a file-mode live slot was not seen: err = %v", err)
	}
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move deleted the source copy")
	}
}

// TestMoveIntoFleetIgnoresANonCredentialLiveFile: a .credentials.json holding
// only MCP tokens is NOT a sign-in. Treating it as "a sign-in we cannot
// identify" would refuse legitimate moves — including the first one on a
// machine with no global sign-in at all.
func TestMoveIntoFleetIgnoresANonCredentialLiveFile(t *testing.T) {
	sw, fk, fleet, src, _ := moveSandbox(t)
	ctx := context.Background()
	// The fleet config still NAMES the source's account (llmpilot never
	// blanks an identity block), so reading the MCP file as a credential
	// fingerprints it against the source's grant and cries "two separate
	// sign-ins" — the false clone accusation this test pins.
	writeConfig(t, fleet, "b@example.dev", `{"projects":{}}`)
	delete(fk.items, fleet.KeychainService()+"\x00tester")
	if err := os.WriteFile(fleet.CredentialsFilePath(),
		[]byte(`{"mcpOAuth":{"server":"x","token":"y"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := sw.MoveIntoFleet(ctx, src, "")
	if err != nil {
		t.Fatalf("an MCP-only credentials file blocked a legitimate move: %v", err)
	}
	if res.Outcome != MoveComplete {
		t.Fatalf("outcome = %q", res.Outcome)
	}
}

// TestMoveIntoFleetRefusesAnUnidentifiableLiveSlot pins a behaviour the
// normalization above must NOT relax: a real credential IS live in the fleet
// slot but nothing says whose it is. "Parsed and named nobody" is
// the same epistemic state as "could not look" — refuse, never delete on a
// guess.
func TestMoveIntoFleetRefusesAnUnidentifiableLiveSlot(t *testing.T) {
	sw, fk, fleet, src, _ := moveSandbox(t)
	ctx := context.Background()
	if err := os.WriteFile(fleet.ConfigJSONPath(), []byte(`{"projects":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := func() error { _, e := sw.MoveIntoFleet(ctx, src, ""); return e }()
	if err == nil {
		t.Fatal("an unidentifiable live slot must refuse the move")
	}
	// Pin the classification too: this is a decision the user can act on, so
	// it must reach the cockpit as 409 (dropping the %w here fails nothing
	// otherwise — re-review).
	if !errors.Is(err, ErrMoveRefused) {
		t.Fatalf("refusal is not classified as a user-actionable decision: %v", err)
	}
	if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
		t.Fatal("the refused move deleted the source copy")
	}
}

// TestMoveIntoFleetLiveSlotStates pins all three states of the fleet's slot.
// Collapsing UNKNOWN into either neighbour is a real defect: into ABSENT it
// deletes on a guess, into IDENTIFIED it fingerprints as a mismatch and
// accuses the user of a second sign-in that does not exist (re-review).
func TestMoveIntoFleetLiveSlotStates(t *testing.T) {
	for _, tc := range []struct {
		name      string
		payload   string // "" = remove the slot entirely
		wantMove  bool
		wantWords string
	}{
		{name: "absent slot moves", payload: "", wantMove: true},
		{name: "well-formed but no sign-in block moves", payload: `{"mcpOAuth":{"server":"x"}}`, wantMove: true},
		{name: "null sign-in block moves", payload: `{"claudeAiOauth":null}`, wantMove: true},
		{name: "unparseable material refuses honestly", payload: `{"mcpOAuth":{"server":"x"`, wantWords: "could not make sense"},
		{name: "empty payload refuses honestly", payload: "   ", wantWords: "could not make sense"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			sw, fk, fleet, src, _ := moveSandbox(t)
			ctx := context.Background()
			// The fleet config NAMES the source's account throughout, so a
			// state wrongly classified IDENTIFIED lands on the clone refusal.
			writeConfig(t, fleet, "b@example.dev", `{"projects":{}}`)
			delete(fk.items, fleet.KeychainService()+"\x00tester")
			_ = os.Remove(fleet.CredentialsFilePath())
			if tc.payload != "" {
				if err := os.WriteFile(fleet.CredentialsFilePath(), []byte(tc.payload), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			res, err := sw.MoveIntoFleet(ctx, src, "")
			if tc.wantMove {
				if err != nil {
					t.Fatalf("a %s slot blocked a legitimate move: %v", tc.name, err)
				}
				if res.Outcome != MoveComplete {
					t.Fatalf("outcome = %q", res.Outcome)
				}
				return
			}
			if err == nil {
				t.Fatal("an unreadable slot must refuse the move")
			}
			if !strings.Contains(err.Error(), tc.wantWords) {
				t.Fatalf("refusal must say what it could not do, got: %v", err)
			}
			if strings.Contains(err.Error(), "two separate sign-ins") {
				t.Fatalf("unknown material was misdiagnosed as a second sign-in: %v", err)
			}
			// A decision the user can act on, so the daemon answers 409 —
			// never a 500, which clients treat as a retryable fault.
			if !errors.Is(err, ErrMoveRefused) {
				t.Fatalf("refusal is not classified as a user-actionable decision: %v", err)
			}
			if _, ok := fk.items[src.KeychainService()+"\x00tester"]; !ok {
				t.Fatal("the refused move deleted the source copy")
			}
		})
	}
}

// TestMovedDirsStopsClaimingAFolderSomeoneSignedBackInto: `moved` feeds the
// cockpit's "Already moved into the fleet" row, which offers no verbs. A
// folder the user signed back into must drop out of that set, or the one
// affordance that resolves the new sign-in is hidden while the clone guard
// silently pauses that account (Codex review P2).
func TestMovedDirsStopsClaimingAFolderSomeoneSignedBackInto(t *testing.T) {
	sw, fk, _, src, _ := moveSandbox(t)
	ctx := context.Background()
	if _, err := sw.MoveIntoFleet(ctx, src, ""); err != nil {
		t.Fatal(err)
	}
	moved, err := sw.MovedDirs(ctx)
	if err != nil || !moved[src.Path()] {
		t.Fatalf("a retired folder should report moved: %+v err=%v", moved, err)
	}

	// The user signs in there again — the folder holds a credential once more.
	if err := sw.Keychain.Set(ctx, src.KeychainService(), "tester", credJSON("token-b-REDONE")); err != nil {
		t.Fatal(err)
	}
	moved, err = sw.MovedDirs(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if moved[src.Path()] {
		t.Fatal("a folder holding a fresh sign-in still claims it was moved — the cockpit would offer no way out")
	}
	_ = fk
}
