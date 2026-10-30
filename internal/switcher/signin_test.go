package switcher

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// stagedSignIn lays out what a finished `claude auth login` leaves in a
// private staging dir: the identity in .claude.json and the grant in that
// dir's own Keychain service.
func stagedSignIn(t *testing.T, fk *fakeKeychain, root, email, token string) claudecfg.Dir {
	t.Helper()
	path := filepath.Join(root, "signin-"+strings.ReplaceAll(email, "@", "_"))
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(path)
	writeConfig(t, dir, email, `{}`)
	if err := fk.keychain().Set(context.Background(), dir.KeychainService(), "tester", credJSON(token)); err != nil {
		t.Fatal(err)
	}
	return dir
}

func liveToken(t *testing.T, sw *Switcher) string {
	t.Helper()
	b, err := sw.Keychain.Get(context.Background(), sw.Dir.KeychainService())
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func backupToken(t *testing.T, sw *Switcher, id string) string {
	t.Helper()
	b, _, err := sw.LoadBackup(context.Background(), id)
	if err != nil {
		t.Fatalf("backup %s: %v", id, err)
	}
	return string(b)
}

func TestImportSignInNewAccountNeverSwitches(t *testing.T) {
	sw, fk, fleet, _, st := moveSandbox(t)
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	res, err := sw.ImportSignIn(context.Background(), staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportAdded || res.Account.ID != "acct-c_example.dev" || res.Account.Label != "c" {
		t.Fatalf("result = %+v", res)
	}
	if res.Account.ConfigDir != fleet.Path() || res.Account.KeychainService != fleet.KeychainService() {
		t.Fatalf("not registered switchable: %+v", res.Account)
	}
	if got := backupToken(t, sw, "acct-c_example.dev"); !strings.Contains(got, "token-c-NEW") {
		t.Fatalf("backup = %s", got)
	}
	// Claude Code's slot is untouched: same grant, same identity.
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") || readEmail(t, fleet) != "a@example.dev" {
		t.Fatal("adding an account switched Claude Code")
	}
	accs, _ := st.Accounts()
	if len(accs) != 2 {
		t.Fatalf("accounts = %+v", accs)
	}
}

func TestImportSignInSameAsActiveInstallsFreshGrant(t *testing.T) {
	sw, fk, fleet, _, st := moveSandbox(t)
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "A@example.dev", "token-a-NEW")
	res, err := sw.ImportSignIn(context.Background(), staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportActive || res.Account.ID != "acct-a" {
		t.Fatalf("result = %+v", res)
	}
	if !strings.Contains(liveToken(t, sw), "token-a-NEW") {
		t.Fatal("the fresh grant was not installed")
	}
	if got := backupToken(t, sw, "acct-a"); !strings.Contains(got, "token-a-NEW") {
		t.Fatalf("backup kept the old lineage: %s", got)
	}
	accs, _ := st.Accounts()
	if len(accs) != 1 {
		t.Fatalf("re-sign-in forked the account: %+v", accs)
	}
}

func TestImportSignInEmptySlotBecomesActive(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	if err := sw.Keychain.Delete(context.Background(), fleet.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	res, err := sw.ImportSignIn(context.Background(), staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportActive {
		t.Fatalf("outcome = %s, want active", res.Outcome)
	}
	if !strings.Contains(liveToken(t, sw), "token-c-NEW") || readEmail(t, fleet) != "c@example.dev" {
		t.Fatal("an empty Claude Code was not signed in")
	}
}

func TestImportSignInExistingInactiveAccountIsUpdated(t *testing.T) {
	sw, fk, fleet, _, st := moveSandbox(t)
	ctx := context.Background()
	accs, _ := st.Accounts()
	accs = append(accs, accs[0])
	accs[1].ID, accs[1].Label, accs[1].Email = "acct-b", "Work", "b@example.dev"
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	if err := sw.SaveBackup(ctx, "acct-b", credJSON("token-b-OLD"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")
	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportUpdated || res.Account.ID != "acct-b" || res.Account.Label != "Work" {
		t.Fatalf("result = %+v", res)
	}
	if got := backupToken(t, sw, "acct-b"); !strings.Contains(got, "token-b-NEW") {
		t.Fatalf("backup = %s", got)
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") {
		t.Fatal("updating an inactive account switched Claude Code")
	}
}

func TestImportSignInUnreadableSlotIsNotOverwritten(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	if err := sw.Keychain.Set(ctx, fleet.KeychainService(), "tester", []byte("not json at all")); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "a@example.dev", "token-a-NEW")
	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome == ImportActive {
		t.Fatal("installed over a slot llmpilot could not read")
	}
	if liveToken(t, sw) != "not json at all" {
		t.Fatal("the unreadable slot was changed")
	}
}

func TestImportSignInRefusesIncompleteStaging(t *testing.T) {
	sw, fk, fleet, _, st := moveSandbox(t)
	root := filepath.Dir(fleet.Path())
	ctx := context.Background()

	noIdentity := claudecfg.DirAt(filepath.Join(root, "no-identity"))
	if err := os.MkdirAll(noIdentity.Path(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(noIdentity.ConfigJSONPath(), []byte(`{"numStartups":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := fk.keychain().Set(ctx, noIdentity.KeychainService(), "tester", credJSON("token-x")); err != nil {
		t.Fatal(err)
	}
	if _, err := sw.ImportSignIn(ctx, noIdentity); !errors.Is(err, ErrSignInIncomplete) {
		t.Fatalf("no identity: err = %v", err)
	}

	noGrant := claudecfg.DirAt(filepath.Join(root, "no-grant"))
	if err := os.MkdirAll(noGrant.Path(), 0o700); err != nil {
		t.Fatal(err)
	}
	writeConfig(t, noGrant, "c@example.dev", `{}`)
	if _, err := sw.ImportSignIn(ctx, noGrant); !errors.Is(err, ErrSignInIncomplete) {
		t.Fatalf("no grant: err = %v", err)
	}

	accs, _ := st.Accounts()
	if len(accs) != 1 || !strings.Contains(liveToken(t, sw), "token-a-LIVE") {
		t.Fatal("an incomplete sign-in changed the fleet")
	}
}

func TestImportSignInRefusesForeignBackup(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	// A backup under the ID c@ would get, holding d@'s grant.
	if err := sw.SaveBackup(ctx, "acct-c_example.dev", credJSON("token-d-ONLY"), oauthJSON("d@example.dev")); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	if _, err := sw.ImportSignIn(ctx, staging); !errors.Is(err, ErrStashConflict) {
		t.Fatalf("err = %v, want ErrStashConflict", err)
	}
	if got := backupToken(t, sw, "acct-c_example.dev"); !strings.Contains(got, "token-d-ONLY") {
		t.Fatal("another account's only copy was overwritten")
	}
}

func TestImportSignInAndForgetDirRefuseTheFleetDir(t *testing.T) {
	sw, _, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	if _, err := sw.ImportSignIn(ctx, fleet); err == nil {
		t.Fatal("ImportSignIn accepted the fleet's own dir")
	}
	if err := sw.ForgetDir(ctx, fleet); err == nil {
		t.Fatal("ForgetDir accepted the fleet's own dir")
	}
	// Same dir, different spelling.
	if err := sw.ForgetDir(ctx, claudecfg.DirAt(fleet.Path()+"/")); err == nil {
		t.Fatal("ForgetDir accepted the fleet dir with a trailing slash")
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") {
		t.Fatal("the fleet's sign-in was touched")
	}
}

func TestForgetDirRemovesEveryStagingItem(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	// Claude Code may write under another account attribute.
	if err := fk.keychain().Set(ctx, staging.KeychainService(), "claude-code-user", credJSON("token-c-2")); err != nil {
		t.Fatal(err)
	}
	if err := sw.ForgetDir(ctx, staging); err != nil {
		t.Fatal(err)
	}
	if left, _ := sw.Keychain.List(ctx, staging.KeychainService()); len(left) != 0 {
		t.Fatalf("left behind: %v", left)
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") {
		t.Fatal("the fleet's sign-in was touched")
	}
}

func registerPinnedB(t *testing.T, st *store.Store, src claudecfg.Dir) {
	t.Helper()
	accs, _ := st.Accounts()
	accs = append(accs, store.Account{ID: "acct-b", Label: "b-work", Email: "b@example.dev",
		ConfigDir: src.Path(), KeychainService: src.KeychainService()})
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
}

func TestImportSignInWatchedAccountStaysWatched(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	registerPinnedB(t, st, src)
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")

	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportUpdated || !res.Existed || res.Account.ConfigDir != src.Path() {
		t.Fatalf("result = %+v", res)
	}
	// The fresh grant is in the watched folder's own slot...
	got, err := sw.Keychain.Get(ctx, src.KeychainService())
	if err != nil || !strings.Contains(string(got), "token-b-NEW") {
		t.Fatalf("watched folder slot = %s, %v", got, err)
	}
	// ...its credentials file is coherent and keeps unrelated material...
	file, _ := os.ReadFile(src.CredentialsFilePath())
	if !strings.Contains(string(file), "token-b-NEW") || !strings.Contains(string(file), "keep-me") {
		t.Fatalf("credentials file = %s", file)
	}
	// ...the row still points at its own folder, and Claude Code's slot is untouched.
	accs, _ := st.Accounts()
	for _, a := range accs {
		if a.ID == "acct-b" && a.ConfigDir != src.Path() {
			t.Fatalf("watched account turned switchable: %+v", a)
		}
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") {
		t.Fatal("Claude Code's slot changed")
	}
}

func TestImportSignInWatchedFolderNowSomeoneElseIsRefused(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	registerPinnedB(t, st, src)
	writeConfig(t, src, "z@example.dev", `{}`) // someone signed that folder in as z@
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")

	if _, err := sw.ImportSignIn(ctx, staging); !errors.Is(err, ErrMoveRefused) {
		t.Fatalf("err = %v, want ErrMoveRefused", err)
	}
	got, _ := sw.Keychain.Get(ctx, src.KeychainService())
	if strings.Contains(string(got), "token-b-NEW") {
		t.Fatal("wrote a grant into a folder signed in as someone else")
	}
}

func TestImportSignInFirstRunWithoutClaudeConfigStoresIt(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	// Claude Code never ran: no sign-in and no .claude.json.
	if err := sw.Keychain.Delete(ctx, fleet.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(fleet.ConfigJSONPath()); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")

	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatalf("a finished sign-in was lost on a first run: %v", err)
	}
	if res.Outcome != ImportAdded || res.Existed || res.Note != NoteOpenClaudeCodeFirst {
		t.Fatalf("result = %+v", res)
	}
	if got := backupToken(t, sw, "acct-c_example.dev"); !strings.Contains(got, "token-c-NEW") {
		t.Fatalf("backup = %s", got)
	}
}

func TestImportSignInRefusesAnotherAccountsID(t *testing.T) {
	sw, fk, fleet, _, st := moveSandbox(t)
	ctx := context.Background()
	// c_1@ owns acct-c_1_example.dev; c+1@ sanitizes to the same ID.
	accs, _ := st.Accounts()
	accs = append(accs, store.Account{ID: "acct-c_1_example.dev", Label: "c_1", Email: "c_1@example.dev", ConfigDir: fleet.Path()})
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	if err := sw.SaveBackup(ctx, "acct-c_1_example.dev", credJSON("token-c1-ONLY"), oauthJSON("c_1@example.dev")); err != nil {
		t.Fatal(err)
	}
	root := filepath.Dir(fleet.Path())

	// Store path (Claude Code holds a@).
	if _, err := sw.ImportSignIn(ctx, stagedSignIn(t, fk, root, "c+1@example.dev", "token-cplus-NEW")); !errors.Is(err, ErrStashConflict) {
		t.Fatalf("store path err = %v", err)
	}
	// Install path (Claude Code's slot empty).
	if err := sw.Keychain.Delete(ctx, fleet.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	if _, err := sw.ImportSignIn(ctx, stagedSignIn(t, fk, root, "c+1@example.dev", "token-cplus-2")); err == nil {
		t.Fatal("install path took over another account's ID")
	}
	if got := backupToken(t, sw, "acct-c_1_example.dev"); !strings.Contains(got, "token-c1-ONLY") {
		t.Fatalf("another account's only sign-in was overwritten: %s", got)
	}
}

func TestImportSignInWatchedFolderWithUnknownSignInIsRefused(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	registerPinnedB(t, st, src)
	// The folder lost its identity block but still holds someone's sign-in.
	if err := os.WriteFile(src.ConfigJSONPath(), []byte(`{"numStartups":3}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := sw.Keychain.Set(ctx, src.KeychainService(), "tester", credJSON("token-stranger")); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")
	if _, err := sw.ImportSignIn(ctx, staging); !errors.Is(err, ErrMoveRefused) {
		t.Fatalf("err = %v, want ErrMoveRefused", err)
	}
	got, _ := sw.Keychain.Get(ctx, src.KeychainService())
	if !strings.Contains(string(got), "token-stranger") {
		t.Fatalf("an unidentified sign-in was overwritten: %s", got)
	}
}

func TestImportSignInWatchedFolderSignedOutGetsIdentityBack(t *testing.T) {
	sw, fk, fleet, src, st := moveSandbox(t)
	ctx := context.Background()
	registerPinnedB(t, st, src)
	if err := os.WriteFile(src.ConfigJSONPath(), []byte(`{"numStartups":3}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := sw.Keychain.Delete(ctx, src.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(src.CredentialsFilePath()); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")
	if _, err := sw.ImportSignIn(ctx, staging); err != nil {
		t.Fatal(err)
	}
	if readEmail(t, src) != "b@example.dev" {
		t.Fatal("the folder's identity was not restored")
	}
}

// failingSlot makes writes to one Keychain service fail — after storing
// (landed) or before (never reached).
func failingSlot(fk *fakeKeychain, service string, landed bool) StdinRunner {
	return func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		write := (len(args) > 0 && args[0] == "-i" && strings.Contains(string(stdin), `-s "`+service+`"`)) ||
			(strings.HasPrefix(strings.Join(args, " "), "add-generic-password") && flagVal(args, "-s") == service)
		if write {
			if landed {
				_, _ = fk.run(ctx, stdin, name, args...)
			}
			return nil, errors.New("security: simulated failure")
		}
		return fk.run(ctx, stdin, name, args...)
	}
}

func TestImportSignInInstallThatNeverLandedIsStoredAsNew(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	if err := sw.Keychain.Delete(ctx, fleet.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: failingSlot(fk, fleet.KeychainService(), false)}
	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatalf("a sign-in whose install never ran was lost: %v", err)
	}
	if res.Outcome != ImportAdded || res.Existed {
		t.Fatalf("a brand-new account reported as old: %+v", res)
	}
}

func TestImportSignInInstallThatLandedReportsTheError(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	if err := sw.Keychain.Delete(ctx, fleet.KeychainService(), "tester"); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: failingSlot(fk, fleet.KeychainService(), true)}
	if _, err := sw.ImportSignIn(ctx, staging); err == nil {
		t.Fatal("reported success while Claude Code's slot holds the half-installed sign-in")
	}
}

func credWithMCP(tok string) json.RawMessage {
	return json.RawMessage(`{"claudeAiOauth":{"accessToken":"` + tok + `","refreshToken":"r-` + tok + `","expiresAt":4102444800000},"mcpOAuth":{"github":{"token":"mcp-keep-me"}}}`)
}

// A fresh Claude sign-in replaces only the Claude sign-in: MCP server
// sign-ins stored beside it survive, on every path.
func TestImportSignInKeepsMCPSignIns(t *testing.T) {
	ctx := context.Background()

	t.Run("same account in Claude Code's slot", func(t *testing.T) {
		sw, fk, fleet, _, _ := moveSandbox(t)
		if err := sw.Keychain.Set(ctx, fleet.KeychainService(), "tester", credWithMCP("token-a-LIVE")); err != nil {
			t.Fatal(err)
		}
		if _, err := sw.ImportSignIn(ctx, stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "a@example.dev", "token-a-NEW")); err != nil {
			t.Fatal(err)
		}
		live := liveToken(t, sw)
		if !strings.Contains(live, "token-a-NEW") || !strings.Contains(live, "mcp-keep-me") {
			t.Fatalf("live slot = %s", live)
		}
		if b := backupToken(t, sw, "acct-a"); !strings.Contains(b, "mcp-keep-me") {
			t.Fatalf("backup = %s", b)
		}
	})

	t.Run("stored account", func(t *testing.T) {
		sw, fk, fleet, _, st := moveSandbox(t)
		accs, _ := st.Accounts()
		accs = append(accs, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: fleet.Path()})
		if err := st.SaveAccounts(accs); err != nil {
			t.Fatal(err)
		}
		if err := sw.SaveBackup(ctx, "acct-b", credWithMCP("token-b-OLD"), oauthJSON("b@example.dev")); err != nil {
			t.Fatal(err)
		}
		if _, err := sw.ImportSignIn(ctx, stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")); err != nil {
			t.Fatal(err)
		}
		b := backupToken(t, sw, "acct-b")
		if !strings.Contains(b, "token-b-NEW") || !strings.Contains(b, "mcp-keep-me") {
			t.Fatalf("backup = %s", b)
		}
	})

	t.Run("watched account's own folder", func(t *testing.T) {
		sw, fk, fleet, src, st := moveSandbox(t)
		registerPinnedB(t, st, src)
		if err := sw.Keychain.Set(ctx, src.KeychainService(), "tester", credWithMCP("token-b-LIVE")); err != nil {
			t.Fatal(err)
		}
		if _, err := sw.ImportSignIn(ctx, stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "b@example.dev", "token-b-NEW")); err != nil {
			t.Fatal(err)
		}
		got, _ := sw.Keychain.Get(ctx, src.KeychainService())
		if !strings.Contains(string(got), "token-b-NEW") || !strings.Contains(string(got), "mcp-keep-me") {
			t.Fatalf("watched slot = %s", got)
		}
	})
}

// A switch that lands between ImportSignIn's first look and the install
// must not be undone: the install re-checks under its locks and the sign-in
// is stored instead.
func TestImportSignInDoesNotUndoASwitchThatLandedMeanwhile(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	service := fleet.KeychainService()
	reads := 0
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		// The first read of Claude Code's slot sees it empty; by the time
		// the install looks again, a@ has been switched in.
		if strings.HasPrefix(strings.Join(args, " "), "find-generic-password") && flagVal(args, "-s") == service {
			reads++
			if reads == 1 {
				return nil, fakeExit44{}
			}
		}
		return fk.run(ctx, stdin, name, args...)
	}}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	res, err := sw.ImportSignIn(ctx, staging)
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != ImportAdded {
		t.Fatalf("outcome = %s, want added", res.Outcome)
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") || readEmail(t, fleet) != "a@example.dev" {
		t.Fatal("the sign-in undid a switch that landed meanwhile")
	}
}

func TestInstallSignInRefusesAnotherAccountsSlot(t *testing.T) {
	sw, _, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	if _, err := sw.installSignIn(ctx, credJSON("token-c-NEW"), oauthJSON("c@example.dev")); !errors.Is(err, ErrSlotChanged) {
		t.Fatalf("err = %v, want ErrSlotChanged", err)
	}
	if !strings.Contains(liveToken(t, sw), "token-a-LIVE") || readEmail(t, fleet) != "a@example.dev" {
		t.Fatal("a guarded install replaced another account")
	}
}

func TestImportSignInUnreadableSlotAfterFailedInstallReportsTheError(t *testing.T) {
	sw, fk, fleet, _, _ := moveSandbox(t)
	ctx := context.Background()
	service := fleet.KeychainService()
	if err := sw.Keychain.Delete(ctx, service, "tester"); err != nil {
		t.Fatal(err)
	}
	staging := stagedSignIn(t, fk, filepath.Dir(fleet.Path()), "c@example.dev", "token-c-NEW")
	landed := failingSlot(fk, service, true)
	broken := false
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		isRead := strings.HasPrefix(strings.Join(args, " "), "find-generic-password") && flagVal(args, "-s") == service
		if isRead && broken {
			return nil, errors.New("security: simulated read failure")
		}
		out, err := landed(ctx, stdin, name, args...)
		if err != nil {
			broken = true // the write landed and failed; from now the slot can't be read
		}
		return out, err
	}}
	if _, err := sw.ImportSignIn(ctx, staging); err == nil {
		t.Fatal("reported success without being able to see Claude Code's slot")
	}
}
