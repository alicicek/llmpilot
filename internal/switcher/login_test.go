package switcher

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

func TestInstallLoginWritesRegistersAndStaysSwappable(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	acct, err := sw.InstallLogin(ctx, credJSON("token-c-FRESH"), oauthJSON("c@example.dev"))
	if err != nil {
		t.Fatalf("install login: %v\n%s", err, out.String())
	}
	if acct.Email != "c@example.dev" || acct.Label != "c" {
		t.Errorf("account = %+v", acct)
	}
	// GLOBAL-SWAPPABLE: registered on the switcher's dir, not pinned.
	if acct.ConfigDir != dir.Path() || acct.KeychainService != dir.KeychainService() {
		t.Errorf("account dir binding = %q / %q", acct.ConfigDir, acct.KeychainService)
	}
	if sw.isPinned(acct) {
		t.Error("fresh login registered as pinned")
	}

	// The credential landed in the (throwaway) keychain's live slot and the
	// identity was spliced into .claude.json.
	if live := fk.items[dir.KeychainService()+"\x00tester"]; !strings.Contains(string(live), "token-c-FRESH") {
		t.Fatalf("live credential = %s", live)
	}
	if got := readEmail(t, dir); got != "c@example.dev" {
		t.Fatalf("config identity after login = %s", got)
	}
	// The previously active account was backed up before the overwrite.
	if backup := fk.items[BackupService+"\x00acct-a"]; !strings.Contains(string(backup), "token-a-LIVE") {
		t.Fatalf("backup for previous active = %s", backup)
	}
	// The fresh mint is persisted under the new account's backup key.
	if backup := fk.items[BackupService+"\x00"+acct.ID]; !strings.Contains(string(backup), "token-c-FRESH") {
		t.Fatalf("backup for new account = %s", backup)
	}
	// Registry carries the new account.
	accs, err := sw.Registry.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, a := range accs {
		if a.ID == acct.ID && a.Email == "c@example.dev" {
			found = true
		}
	}
	if !found {
		t.Fatalf("registry after login = %+v", accs)
	}
	// No token material in the transcript.
	for _, secret := range []string{"token-c-FRESH", "r-token", "token-a-LIVE"} {
		if strings.Contains(out.String(), secret) {
			t.Fatalf("transcript leaked %q:\n%s", secret, out.String())
		}
	}
	// Locks all released.
	for _, p := range []string{dir.OAuthRefreshLockPath(), dir.StorageWriteLockPath(),
		dir.LegacyCredentialsLockPath(), dir.LegacyConfigLockPath()} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("lock %s not released", p)
		}
	}
	// Swap works both away from and back to the fresh account.
	if err := sw.Swap(ctx, store.Account{ID: "acct-a", Label: "a", Email: "a@example.dev"}); err != nil {
		t.Fatalf("swap away from fresh login: %v", err)
	}
	if err := sw.Swap(ctx, acct); err != nil {
		t.Fatalf("swap back to fresh login: %v", err)
	}
	if got := readEmail(t, dir); got != "c@example.dev" {
		t.Fatalf("after round-trip swap: %s", got)
	}
}

// TestInstallLoginReloginKeepsFreshLineage pins the ordering hazard: a
// re-login to the CURRENTLY ACTIVE account writes the old live credential and
// the fresh mint to the SAME backup key — the fresh lineage must win.
func TestInstallLoginReloginKeepsFreshLineage(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	acct, err := sw.InstallLogin(ctx, credJSON("token-a2-FRESH"), oauthJSON("a@example.dev"))
	if err != nil {
		t.Fatalf("re-login: %v\n%s", err, out.String())
	}
	if acct.ID != "acct-a" {
		t.Fatalf("re-login resolved to %q, want the registered acct-a", acct.ID)
	}
	if live := fk.items[dir.KeychainService()+"\x00tester"]; !strings.Contains(string(live), "token-a2-FRESH") {
		t.Fatalf("live credential = %s", live)
	}
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if !strings.Contains(backup, "token-a2-FRESH") {
		t.Fatalf("fresh lineage lost — backup = %s", backup)
	}
	if strings.Contains(backup, "token-a-LIVE") {
		t.Fatalf("old lineage clobbered the fresh backup: %s", backup)
	}
}

// TestInstallLoginSerializesAgainstKeepWarm drives the real interleaving: a
// keep-warm rotation holds the backups lock across its POST while a fresh
// login for the same account arrives. The login must wait and land LAST, so
// the fresh lineage survives; afterwards keep-warm refuses to touch it (it is
// now the live credential).
func TestInstallLoginSerializesAgainstKeepWarm(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	now := time.Now()

	// Age b's backup to near expiry so keep-warm rotates it.
	nearExpiry := json.RawMessage(`{"claudeAiOauth":{"accessToken":"token-b-OLD","refreshToken":"r-old","expiresAt":` +
		itoa(int(now.Add(10*time.Minute).UnixMilli())) + `}}`)
	if err := sw.SaveBackup(ctx, "acct-b", nearExpiry, oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}

	entered := make(chan struct{})
	release := make(chan struct{})
	opts := KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(context.Context, string) (anthropic.RefreshResult, error) {
			close(entered)
			<-release
			return anthropic.RefreshResult{AccessToken: "token-b-ROTATED", RefreshToken: "r-rot",
				ExpiresAt: now.Add(8 * time.Hour)}, nil
		},
	}
	kwDone := make(chan KeepWarmResult, 1)
	go func() {
		res, err := sw.KeepWarm(ctx, store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: dir.Path()}, opts)
		if err != nil {
			t.Errorf("keep-warm: %v", err)
		}
		kwDone <- res
	}()
	<-entered // keep-warm now holds the backups lock, mid-POST

	loginDone := make(chan error, 1)
	go func() {
		_, err := sw.InstallLogin(ctx, credJSON("token-b2-FRESH"), oauthJSON("b@example.dev"))
		loginDone <- err
	}()
	// The login must block on the backups lock while keep-warm holds it.
	select {
	case err := <-loginDone:
		t.Fatalf("login finished while keep-warm held the backups lock (err=%v)\n%s", err, out.String())
	case <-time.After(300 * time.Millisecond):
	}
	close(release)
	if res := <-kwDone; !res.Rotated {
		t.Fatalf("keep-warm did not rotate: %+v", res)
	}
	if err := <-loginDone; err != nil {
		t.Fatalf("login after keep-warm: %v\n%s", err, out.String())
	}

	// The fresh login lineage won everywhere.
	backup := string(fk.items[BackupService+"\x00acct-b"])
	if !strings.Contains(backup, "token-b2-FRESH") || strings.Contains(backup, "token-b-ROTATED") {
		t.Fatalf("backup after login = %s", backup)
	}
	if live := fk.items[dir.KeychainService()+"\x00tester"]; !strings.Contains(string(live), "token-b2-FRESH") {
		t.Fatalf("live credential = %s", live)
	}
	// And keep-warm now stands down: the backup IS the live credential.
	res, err := sw.KeepWarm(ctx, store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: dir.Path()}, opts)
	if err != nil {
		t.Fatal(err)
	}
	if res.Skipped != "backup is the live credential" {
		t.Fatalf("keep-warm after login: %+v, want the live-credential skip", res)
	}
}

// TestInstallLoginInterlocks tests both sandbox layers' FAIL cases: the real
// config-dir identity and the login keychain are refused under LLMPILOT_TEST.
func TestInstallLoginInterlocks(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	// Filesystem layer: a switcher pointed at the REAL ~/.claude refuses
	// before anything is written.
	swReal := &Switcher{Dir: claudecfg.DirAt(filepath.Join(home, ".claude")), Keychain: newFakeKeychain().keychain()}
	if _, err := swReal.InstallLogin(ctx, credJSON("t"), oauthJSON("x@example.dev")); err == nil ||
		!strings.Contains(err.Error(), "LLMPILOT_TEST") {
		t.Fatalf("real config dir not refused: %v", err)
	}

	// Keychain layer: no keychain file under LLMPILOT_TEST = the login
	// keychain — refused by the keychain interlock inside the write path.
	root := t.TempDir()
	cfg := filepath.Join(root, "claude-x")
	if err := os.MkdirAll(cfg, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cfg)
	writeConfig(t, dir, "x@example.dev", `{}`)
	swLogin := &Switcher{Dir: dir, Keychain: &Keychain{}}
	if _, err := swLogin.InstallLogin(ctx, credJSON("t"), oauthJSON("x@example.dev")); err == nil ||
		!strings.Contains(err.Error(), "interlock") {
		t.Fatalf("login keychain not refused: %v", err)
	}
}

func TestInstallLoginRejectsBadInput(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	before := string(fk.items[dir.KeychainService()+"\x00tester"])

	if _, err := sw.InstallLogin(ctx, json.RawMessage(`{"nope":true}`), oauthJSON("c@example.dev")); err == nil {
		t.Fatal("corrupt credential accepted")
	}
	if _, err := sw.InstallLogin(ctx, credJSON("t"), json.RawMessage(`{"accountUuid":"u"}`)); err == nil {
		t.Fatal("identity without email accepted")
	}
	// Nothing was installed and the registry gained nothing.
	if after := string(fk.items[dir.KeychainService()+"\x00tester"]); after != before {
		t.Fatalf("live credential changed on a rejected login")
	}
	accs, err := sw.Registry.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accs) != 2 {
		t.Fatalf("registry after rejected logins = %+v", accs)
	}
}

// TestInstallLoginKeepsTheGuardWhenTheLoginFails: clearing the clone-suspect
// mark before the fresh grant is durable disarms the guard for a login that
// then fails on a lock or a read — the old backup and its surviving source
// copy stay duplicated, unguarded (Codex review P1).
func TestInstallLoginKeepsTheGuardWhenTheLoginFails(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()
	if err := sw.Registry.RecordRetirement(store.RetiredDir{
		ConfigDir: "/somewhere/leftover", Email: "b@example.dev", AccountID: "acct-b", Complete: false,
	}); err != nil {
		t.Fatal(err)
	}
	if suspect, _ := sw.Registry.IsCloneSuspect("acct-b"); !suspect {
		t.Fatal("setup: acct-b should be clone-suspect")
	}
	// Fail the install AFTER registration: hold the config dir's lock so
	// swapTo cannot take it.
	sw.LockTimeout = 50 * time.Millisecond
	held, err := acquireLock(ctx, dir.OAuthRefreshLockPath(), time.Hour, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer held.release()

	if _, err := sw.InstallLogin(ctx, credJSON("token-fresh"), oauthJSON("b@example.dev")); err == nil {
		t.Fatal("the login should have failed on the held lock")
	}
	suspect, err := sw.Registry.IsCloneSuspect("acct-b")
	if err != nil {
		t.Fatal(err)
	}
	if !suspect {
		t.Fatal("a FAILED login cleared the clone-suspect guard — nothing fresh was persisted")
	}
}
