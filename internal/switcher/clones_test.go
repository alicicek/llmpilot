package switcher

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestKeepWarmSkipsLineageLiveElsewhere is the clone-guard proof. Rotating a
// lineage that is ALSO signed into a config dir outside the fleet kills that
// copy (the refresh token rotates server-side), so the rotation must not
// happen — and the guard must decide it WITHOUT reading a Keychain item
// outside the fleet's own services (an ACL prompt at 02:00 is a product
// failure).
func TestKeepWarmSkipsLineageLiveElsewhere(t *testing.T) {
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
	sw.ScanDirs = func() ([]string, error) { return []string{foreign}, nil }

	// A Keychain that FAILS the test on any read outside the fleet's own two
	// services: llmpilot's backups and the fleet dir's own item.
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
	if res.Rotated || len(calls) != 0 {
		t.Fatalf("a lineage live in another dir was rotated: %+v calls=%v", res, calls)
	}
	if !strings.Contains(res.Skipped, "also live in") || !strings.Contains(res.Skipped, foreign) {
		t.Fatalf("skip reason must name the other dir: %q", res.Skipped)
	}

	// A dir a MOVE retired is proven empty — it must not trigger the skip.
	if err := sw.Registry.RecordRetirement(store.RetiredDir{
		ConfigDir: foreign, Email: "b@example.dev", AccountID: acctB.ID, Complete: true,
	}); err != nil {
		t.Fatal(err)
	}
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, opts)
	if err != nil {
		t.Fatalf("keep-warm after a completed retirement: %v", err)
	}
	if !res.Rotated || len(calls) != 1 {
		t.Fatalf("a retired dir still blocked the rotation: %+v calls=%v", res, calls)
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

// TestCloneGuardReArmsAfterAFreshSignInInARetiredDir: a retirement is a fact
// about a MOMENT. The product tells the user "a terminal using that folder
// will need to sign in again" — and when they do, that dir holds a live grant
// again. A permanent exclusion would rotate our copy and kill theirs
// (adversarial review P0).
func TestCloneGuardReArmsAfterAFreshSignInInARetiredDir(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	retired := filepath.Join(t.TempDir(), "claude-retired")
	if err := os.MkdirAll(retired, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := filepath.Join(retired, ".claude.json")
	body := fmt.Sprintf(`{"oauthAccount":%s}`, oauthJSON("b@example.dev"))
	if err := os.WriteFile(cfg, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	// Retired: the identity block stays (llmpilot never blanks a foreign
	// dir's) but no credential remains there.
	sw.ScanDirs = func() ([]string, error) { return []string{retired}, nil }
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: dir.Path()}
	if err := sw.Registry.RecordRetirement(store.RetiredDir{
		ConfigDir: retired, Email: "b@example.dev", AccountID: acctB.ID,
		RetiredAt: now.Add(-time.Hour), Complete: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := sw.SaveBackup(ctx, acctB.ID, credWithExpiry("token-b", now.Add(20*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	var calls []string
	opts := nearExpiryOpts(now, &calls)
	res, err := sw.KeepWarm(ctx, acctB, opts)
	if err != nil || !res.Rotated {
		t.Fatalf("an untouched retired dir must not block rotation: %+v err=%v", res, err)
	}

	// The user signs in there again — a credential exists in that dir once
	// more (Claude Code writes the Keychain on macOS; the identity block may
	// look identical). The guard must re-arm on the CREDENTIAL, not on a
	// config-file mtime.
	if err := sw.Keychain.Set(ctx, claudecfg.DirAt(retired).KeychainService(), "tester", credJSON("token-b-REDONE")); err != nil {
		t.Fatal(err)
	}
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, opts)
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || len(calls) != 0 {
		t.Fatalf("a re-signed-in retired dir did not re-arm the guard: %+v calls=%v", res, calls)
	}
	if !strings.Contains(res.Skipped, retired) {
		t.Fatalf("skip reason must name the dir: %q", res.Skipped)
	}
}

// TestCorruptRetirementRecordSelfHealsAndTheScanStillGuards: an unreadable
// retirements.json must NOT freeze the fleet (it holds no credentials, so it
// is reconstructible) — but losing the mark must not lose the protection
// either. With the record gone, no dir is excluded, so the machine-wide scan
// catches the very copy the mark was standing in for.
func TestCorruptRetirementRecordSelfHealsAndTheScanStillGuards(t *testing.T) {
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

	// A leftover live copy of this account exists in another dir — the state
	// the lost mark described.
	leftover := filepath.Join(t.TempDir(), "claude-leftover")
	if err := os.MkdirAll(leftover, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`{"oauthAccount":%s}`, oauthJSON("b@example.dev"))
	if err := os.WriteFile(filepath.Join(leftover, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	sw.ScanDirs = func() ([]string, error) { return []string{leftover}, nil }

	var calls []string
	res, err := sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || len(calls) != 0 {
		t.Fatalf("the scan did not cover for the lost mark: %+v calls=%v", res, calls)
	}
	if !strings.Contains(res.Skipped, ReasonLineageElsewhere) {
		t.Fatalf("skip reason = %q", res.Skipped)
	}
	// The corrupt document was moved aside (uniquely named, so an earlier
	// quarantine is never clobbered), not left to fail forever.
	quarantined, err := filepath.Glob(recPath + ".corrupt-*")
	if err != nil || len(quarantined) != 1 {
		t.Fatalf("the corrupt record was not quarantined: %v %v", quarantined, err)
	}

	// And with nothing live elsewhere, the account is NOT frozen — the whole
	// point: one bad file must not stop every account on the machine.
	sw.ScanDirs = func() ([]string, error) { return nil, nil }
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil || !res.Rotated || len(calls) != 1 {
		t.Fatalf("a corrupt record froze an unrelated account: %+v err=%v calls=%v", res, err, calls)
	}
}
