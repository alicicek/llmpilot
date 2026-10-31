package switcher

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestKeepWarmRefreshesDespiteTheSameEmailElsewhere: a folder outside the
// fleet signed in to the same account holds its own grant, so keeping ours
// warm cannot end it (owner 2026-10-31) — the account is refreshed, and
// without reading a Keychain item outside the fleet's own services (an ACL
// prompt at 02:00 is a product failure).
func TestKeepWarmRefreshesDespiteTheSameEmailElsewhere(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()

	foreign := filepath.Join(t.TempDir(), "claude-foreign")
	if err := os.MkdirAll(foreign, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`{"oauthAccount":%s}`, oauthJSON("b@example.dev"))
	if err := os.WriteFile(filepath.Join(foreign, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	// Live: the folder's own sign-in is stored too (a folder with only the
	// identity is signed out, and holds nothing to collide with).
	if err := fk.keychain().Set(ctx, claudecfg.DirAt(foreign).KeychainService(), "tester", credJSON("token-b-FOREIGN")); err != nil {
		t.Fatal(err)
	}
	sw.ScanDirs = func() ([]string, error) { return []string{foreign}, nil }

	// A Keychain that FAILS the test on any secret read outside the fleet's
	// own two services: llmpilot's backups and the fleet dir's own item.
	// Attribute-only enumeration (dump-keychain, no -s) stays allowed.
	ours := map[string]bool{BackupService: true, dir.KeychainService(): true}
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		if svc := flagVal(args, "-s"); svc != "" && !ours[svc] {
			t.Errorf("clone guard touched a foreign Keychain service %q", svc)
			return nil, fmt.Errorf("foreign keychain read")
		}
		return fk.run(ctx, stdin, name, args...)
	}}

	acctB := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: dir.Path()}
	if err := sw.SaveBackup(ctx, acctB.ID, credWithExpiry("token-b", now.Add(20*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	var calls []string
	opts := nearExpiryOpts(now, &calls)

	res, err := sw.KeepWarm(ctx, acctB, opts)
	if err != nil {
		t.Fatal(err)
	}
	if !res.Rotated || len(calls) != 1 {
		t.Fatalf("a sign-in in another folder blocked the refresh: %+v calls=%v", res, calls)
	}
}

// TestForeignSignInsExcludesTheFleet: the enumerator only ever reports dirs
// OUTSIDE the fleet — the fleet's own global dir and every registered
// account's dir are by definition not clones.
func TestForeignSignInsExcludesTheFleet(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	pinned := filepath.Join(t.TempDir(), "claude-pinned")
	stranger := filepath.Join(t.TempDir(), "claude-stranger")
	for _, p := range []string{pinned, stranger} {
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
		email := "pinned@example.dev"
		if p == stranger {
			email = "stranger@example.dev"
		}
		cfg := fmt.Sprintf(`{"oauthAccount":%s}`, oauthJSON(email))
		if err := os.WriteFile(filepath.Join(p, ".claude.json"), []byte(cfg), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	accs, _ := sw.Registry.Accounts()
	accs = append(accs, store.Account{ID: "acct-pinned", Email: "pinned@example.dev", ConfigDir: pinned})
	if err := sw.Registry.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	sw.ScanDirs = func() ([]string, error) { return []string{dir.Path(), pinned, stranger}, nil }

	got, err := sw.ForeignSignIns(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Dir != stranger || got[0].Email != "stranger@example.dev" {
		t.Fatalf("foreign sign-ins = %+v, want only the stranger", got)
	}
}

// TestCorruptRetirementRecordSelfHeals: an unreadable retirements.json must
// NOT freeze the fleet — it holds no credentials, so it is reconstructible.
// The corrupt document is moved aside and the account keeps refreshing.
func TestCorruptRetirementRecordSelfHeals(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: dir.Path()}
	if err := sw.SaveBackup(ctx, acctB.ID, credWithExpiry("token-b", now.Add(20*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	recPath := filepath.Join(sw.Registry.Home(), "retirements.json")
	if err := os.WriteFile(recPath, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	sw.ScanDirs = func() ([]string, error) { return nil, nil }

	var calls []string
	res, err := sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil || !res.Rotated || len(calls) != 1 {
		t.Fatalf("a corrupt record froze the account: %+v err=%v calls=%v", res, err, calls)
	}
	// Moved aside (uniquely named, so an earlier quarantine is never
	// clobbered), not left to fail forever.
	quarantined, err := filepath.Glob(recPath + ".corrupt-*")
	if err != nil || len(quarantined) != 1 {
		t.Fatalf("the corrupt record was not quarantined: %v %v", quarantined, err)
	}
}
