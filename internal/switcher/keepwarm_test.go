package switcher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// credWithExpiry builds a credential blob whose access token expires at exp.
func credWithExpiry(tok string, exp time.Time) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(
		`{"claudeAiOauth":{"accessToken":%q,"refreshToken":"r-%s","expiresAt":%d,"scopes":["user:inference"]}}`,
		tok, tok, exp.UnixMilli()))
}

// rotatingRefresher returns a TokenRefresher that mints a deterministic new
// credential and records every refresh token it was called with.
func rotatingRefresher(now time.Time, calls *[]string) TokenRefresher {
	var mu sync.Mutex
	n := 0
	return func(_ context.Context, refreshToken string) (anthropic.RefreshResult, error) {
		mu.Lock()
		defer mu.Unlock()
		n++
		if calls != nil {
			*calls = append(*calls, refreshToken)
		}
		return anthropic.RefreshResult{
			AccessToken:  fmt.Sprintf("access-rotated-%d", n),
			RefreshToken: fmt.Sprintf("refresh-rotated-%d", n),
			ExpiresAt:    now.Add(8 * time.Hour),
			Scopes:       []string{"user:inference"},
		}, nil
	}
}

func nearExpiryOpts(now time.Time, calls *[]string) KeepWarmOpts {
	return KeepWarmOpts{
		Refresh:     rotatingRefresher(now, calls),
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
	}
}

// TestKeepWarmBackupRotates is the core mode-B proof: an idle global-dir
// account near expiry gets its BACKUP rotated, the new refresh token stored,
// and the chain survives a second rotation.
func TestKeepWarmBackupRotates(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	// Re-seed b's backup near expiry (sandbox seeds a far-future one).
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(30*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}

	var calls []string
	res, err := sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatalf("keep-warm: %v", err)
	}
	if !res.Rotated {
		t.Fatalf("expected rotation, got skip %q", res.Skipped)
	}
	if len(calls) != 1 || calls[0] != "r-token-b" {
		t.Fatalf("refresher called with %v, want [r-token-b]", calls)
	}
	backup := string(fk.items[BackupService+"\x00acct-b"])
	if !strings.Contains(backup, "access-rotated-1") || !strings.Contains(backup, "refresh-rotated-1") {
		t.Fatalf("backup not rotated: %s", backup)
	}

	// Second pass: the stored (rotated) refresh token is what gets used — the
	// chain survives. Re-seed near expiry to make it due again.
	rotated := credWithExpiry("x", now.Add(20*time.Minute))
	_ = rotated
	// Directly age the rotated backup's expiry so it's due again.
	reseed, _, _ := sw.LoadBackup(ctx, "acct-b")
	spliced, _ := anthropic.SpliceOAuthCred(reseed, anthropic.RefreshResult{
		AccessToken: "access-rotated-1", ExpiresAt: now.Add(10 * time.Minute),
	})
	if err := sw.SaveBackup(ctx, "acct-b", spliced, oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	calls = nil
	res, err = sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil || !res.Rotated {
		t.Fatalf("second rotation failed: %v %+v", err, res)
	}
	if len(calls) != 1 || calls[0] != "refresh-rotated-1" {
		t.Fatalf("second refresh used %v, want [refresh-rotated-1] (chain broken)", calls)
	}
}

func TestKeepWarmSkipsNotNearExpiry(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(5*time.Hour)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	var calls []string
	res, err := sw.KeepWarm(ctx, acctB, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || res.Skipped != "not near expiry" {
		t.Fatalf("res = %+v, want skip not-near-expiry", res)
	}
	if len(calls) != 0 {
		t.Fatalf("refresher must not be called: %v", calls)
	}
}

// TestKeepWarmSkipsActiveAccount: the active account's backup equals the live
// global credential; keep-warm must refuse to touch it (CC owns it).
func TestKeepWarmSkipsActiveAccount(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	// Make acct-a the "active" account: its live global credential and its
	// backup are the same near-expiry lineage.
	liveA := credWithExpiry("token-a", now.Add(20*time.Minute))
	fk.items[dir.KeychainService()+"\x00tester"] = liveA
	if err := sw.SaveBackup(ctx, "acct-a", liveA, oauthJSON("a@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctA := store.Account{ID: "acct-a", Email: "a@example.dev", ConfigDir: dir.Path()}
	var calls []string
	res, err := sw.KeepWarm(ctx, acctA, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, "live credential") {
		t.Fatalf("res = %+v, want skip (backup is live)", res)
	}
	if len(calls) != 0 {
		t.Fatalf("must not refresh the active account: %v", calls)
	}
}

func TestKeepWarmQuarantinesOnInvalidGrant(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	before := credWithExpiry("token-b", now.Add(10*time.Minute))
	if err := sw.SaveBackup(ctx, "acct-b", before, oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	opts := KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(context.Context, string) (anthropic.RefreshResult, error) {
			return anthropic.RefreshResult{}, &anthropic.RefreshError{StatusCode: 400, Code: "invalid_grant"}
		},
	}
	res, err := sw.KeepWarm(ctx, acctB, opts)
	if !errors.Is(err, ErrLineageDead) {
		t.Fatalf("err = %v, want ErrLineageDead", err)
	}
	if res.Fingerprint == "" {
		t.Fatal("dead result must carry the lineage fingerprint")
	}
	// The credential must be UNCHANGED after a permanent failure.
	after, _, _ := sw.LoadBackup(ctx, "acct-b")
	if string(after) != string(before) {
		t.Fatalf("dead-lineage failure mutated the credential:\n%s", after)
	}
}

func TestKeepWarmTransientFailureLeavesCredential(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	before := credWithExpiry("token-b", now.Add(10*time.Minute))
	if err := sw.SaveBackup(ctx, "acct-b", before, oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	opts := KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(context.Context, string) (anthropic.RefreshResult, error) {
			return anthropic.RefreshResult{}, &anthropic.RefreshError{StatusCode: 429}
		},
	}
	_, err := sw.KeepWarm(ctx, acctB, opts)
	if err == nil || errors.Is(err, ErrLineageDead) {
		t.Fatalf("err = %v, want transient (not ErrLineageDead)", err)
	}
	after, _, _ := sw.LoadBackup(ctx, "acct-b")
	if string(after) != string(before) {
		t.Fatal("transient failure mutated the credential")
	}
}

// pinnedSandbox adds a per-dir account "c" with its own config dir + keychain
// service holding a near-expiry live credential.
func pinnedSandbox(t *testing.T, sw *Switcher, fk *fakeKeychain, root string, exp time.Time) (store.Account, claudecfg.Dir) {
	t.Helper()
	cDir := filepath.Join(root, "claude-c")
	if err := os.MkdirAll(cDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cDir)
	writeConfig(t, dir, "c@example.dev", `{"projects":{}}`)
	if err := fk.keychain().Set(context.Background(), dir.KeychainService(), "tester", credWithExpiry("token-c", exp)); err != nil {
		t.Fatal(err)
	}
	return store.Account{ID: "acct-c", Label: "c", Email: "c@example.dev", ConfigDir: cDir, KeychainService: dir.KeychainService()}, dir
}

// TestKeepWarmPinnedRotatesInPlace is the mode-A proof: a per-dir idle account
// is refreshed in its OWN keychain service (not a backup), under its own locks.
func TestKeepWarmPinnedRotatesInPlace(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	root := filepath.Dir(sw.Dir.Path())
	acctC, dir := pinnedSandbox(t, sw, fk, root, now.Add(20*time.Minute))

	var calls []string
	res, err := sw.KeepWarm(ctx, acctC, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatalf("keep-warm pinned: %v", err)
	}
	if !res.Rotated {
		t.Fatalf("expected rotation, got skip %q", res.Skipped)
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "access-rotated-1") {
		t.Fatalf("pinned dir keychain not rotated in place: %s", live)
	}
	// Locks on the pinned dir are released.
	for _, p := range []string{dir.OAuthRefreshLockPath(), dir.StorageWriteLockPath()} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("pinned lock %s not released", p)
		}
	}
}

// TestKeepWarmPinnedSkipsGlobalClone: a pinned account whose lineage is ALSO
// live in the global slot must not be rotated (would kill the active account).
func TestKeepWarmPinnedSkipsGlobalClone(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	root := filepath.Dir(sw.Dir.Path())
	acctC, cdir := pinnedSandbox(t, sw, fk, root, now.Add(20*time.Minute))
	// Clone c's credential into the global slot (the hazard: one lineage, two
	// live copies).
	clone := fk.items[cdir.KeychainService()+"\x00tester"]
	fk.items[dir.KeychainService()+"\x00tester"] = clone

	var calls []string
	res, err := sw.KeepWarm(ctx, acctC, nearExpiryOpts(now, &calls))
	if err != nil {
		t.Fatal(err)
	}
	if res.Rotated || !strings.Contains(res.Skipped, "global slot") {
		t.Fatalf("res = %+v, want skip (lineage also live globally)", res)
	}
	if len(calls) != 0 {
		t.Fatalf("must not rotate a cloned lineage: %v", calls)
	}
}

// TestKeepWarmBackupVsSwapRace is the mode-B lock-race proof: a keep-warm
// refresh holding the backups lock across its POST, racing a concurrent Swap
// to the same account. The invariant: Swap installs the ROTATED credential
// (never the pre-rotation one keep-warm replaced), so the chain never dies.
func TestKeepWarmBackupVsSwapRace(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	sw.LockTimeout = 5 * time.Second
	now := time.Now()
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(10*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: dir.Path()}

	// A refresher that blocks until signalled, so the keep-warm holds the
	// backups lock across the "network" while the swap tries to proceed.
	refreshing := make(chan struct{})
	proceed := make(chan struct{})
	opts := KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(_ context.Context, rt string) (anthropic.RefreshResult, error) {
			close(refreshing)
			<-proceed
			return anthropic.RefreshResult{
				AccessToken: "access-KW", RefreshToken: "refresh-KW", ExpiresAt: now.Add(8 * time.Hour),
			}, nil
		},
	}

	kwDone := make(chan error, 1)
	go func() {
		_, err := sw.KeepWarm(ctx, acctB, opts)
		kwDone <- err
	}()

	<-refreshing // keep-warm now holds the backups lock, mid-POST
	swapErr := make(chan error, 1)
	go func() {
		swapErr <- sw.Swap(ctx, acctB) // must block on the backups lock
	}()

	// Give the swap a moment to reach (and block on) the backups lock, then
	// let keep-warm finish and release it.
	time.Sleep(200 * time.Millisecond)
	close(proceed)

	if err := <-kwDone; err != nil {
		t.Fatalf("keep-warm: %v\n%s", err, out.String())
	}
	if err := <-swapErr; err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}

	// Swap ran after keep-warm rotated the backup, so the live credential is
	// the ROTATED one — the pre-rotation token would be a dead lineage.
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "access-KW") || !strings.Contains(live, "refresh-KW") {
		t.Fatalf("swap installed a pre-rotation credential — clobber NOT closed:\n%s", live)
	}
}

// TestKeepWarmPinnedVsCCRefreshRace is the mode-A lock-race proof: a fake CC
// refresh holds the pinned dir's .oauth_refresh.lock and rotates the live
// credential; keep-warm must wait, then re-read the ROTATED credential under
// the lock (never rotate the stale one it first saw).
func TestKeepWarmPinnedVsCCRefreshRace(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	sw.LockTimeout = 5 * time.Second
	now := time.Now()
	root := filepath.Dir(sw.Dir.Path())
	acctC, cdir := pinnedSandbox(t, sw, fk, root, now.Add(20*time.Minute))

	lockHeld := make(chan struct{})
	ccDone := make(chan error, 1)
	go func() {
		l, err := acquireLock(ctx, cdir.OAuthRefreshLockPath(), 10*time.Second, 5*time.Second)
		if err != nil {
			close(lockHeld)
			ccDone <- err
			return
		}
		close(lockHeld)
		time.Sleep(150 * time.Millisecond)
		// CC rotates the live credential in the pinned dir's keychain.
		fk.mu.Lock()
		fk.items[cdir.KeychainService()+"\x00tester"] = credWithExpiry("token-c-CCROT", now.Add(20*time.Minute))
		fk.mu.Unlock()
		l.release()
		ccDone <- nil
	}()

	<-lockHeld
	var seen []string
	res, err := sw.KeepWarm(ctx, acctC, nearExpiryOpts(now, &seen))
	if err != nil {
		t.Fatalf("keep-warm: %v", err)
	}
	if err := <-ccDone; err != nil {
		t.Fatalf("fake CC refresh: %v", err)
	}
	if !res.Rotated {
		t.Fatalf("expected rotation, got %q", res.Skipped)
	}
	// keep-warm ran AFTER the CC refresh (lock ordering), so it refreshed the
	// ROTATED token, never the stale one it might have read before locking.
	if len(seen) != 1 || seen[0] != "r-token-c-CCROT" {
		t.Fatalf("keep-warm refreshed %v, want [r-token-c-CCROT] (raced CC)", seen)
	}
}

// TestSwapRefusesPinnedTarget pins the product decision: a per-dir account is
// never installed into the global slot.
func TestSwapRefusesPinnedTarget(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	root := filepath.Dir(sw.Dir.Path())
	acctC, _ := pinnedSandbox(t, sw, fk, root, time.Now().Add(time.Hour))
	// Give it a backup so the failure is the pin refusal, not missing backup.
	if err := sw.SaveBackup(ctx, acctC.ID, credJSON("token-c"), oauthJSON("c@example.dev")); err != nil {
		t.Fatal(err)
	}
	err := sw.Swap(ctx, acctC)
	if err == nil || !strings.Contains(err.Error(), "pinned to its own config dir") {
		t.Fatalf("err = %v, want pinned-target refusal", err)
	}
}

// TestFreshenBlocksOnBackupsLockAndSkipsForeignCredential is the regression
// for the HIGH lock-race finding: FreshenBackup must read the credential UNDER
// the backups lock, never before it. We simulate a swap mid-mutation — the
// backups lock held, the live keychain already the NEW account, config still
// the OLD one (the dangerous window) — and prove Freshen(old) blocks until the
// swap settles, then skips, never cloning the new account's lineage into the
// old account's backup.
func TestFreshenBlocksOnBackupsLockAndSkipsForeignCredential(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	sw.LockTimeout = 5 * time.Second
	if err := sw.SaveBackup(ctx, "acct-a", credJSON("token-a-LIVE"), oauthJSON("a@example.dev")); err != nil {
		t.Fatal(err)
	}

	// Simulate a swap holding the backups lock across its mutation, having
	// already installed b's credential while config still reads a.
	bl, err := sw.acquireBackupsLock(ctx)
	if err != nil {
		t.Fatal(err)
	}
	fk.mu.Lock()
	fk.items[dir.KeychainService()+"\x00tester"] = credJSON("token-b-STORED")
	fk.mu.Unlock()

	done := make(chan error, 1)
	go func() {
		_, err := sw.FreshenBackup(ctx, Identity{ID: "acct-a", Email: "a@example.dev"})
		done <- err
	}()

	// Freshen must be blocked on the backups lock — it may not have read the
	// credential yet.
	time.Sleep(100 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("Freshen proceeded without the backups lock — the TOCTOU window is open")
	default:
	}

	// Finish the swap: config becomes b, then release the lock.
	writeConfig(t, dir, "b@example.dev", `{"projects":{}}`)
	releaseLock(bl)

	if err := <-done; err != nil {
		t.Fatalf("freshen: %v", err)
	}
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if strings.Contains(backup, "token-b-STORED") {
		t.Fatalf("Freshen captured b's credential under acct-a — clone/death bug:\n%s", backup)
	}
	if !strings.Contains(backup, "token-a-LIVE") {
		t.Fatalf("acct-a backup corrupted: %s", backup)
	}
}

func TestFingerprintTracksReLogin(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b", now.Add(10*time.Minute)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	acctB := store.Account{ID: "acct-b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}
	fp1, err := sw.Fingerprint(ctx, acctB)
	if err != nil || fp1 == "" {
		t.Fatalf("fp1 = %q, %v", fp1, err)
	}
	// A re-login rewrites the backup with a new lineage.
	if err := sw.SaveBackup(ctx, "acct-b", credWithExpiry("token-b2", now.Add(3*time.Hour)), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	fp2, _ := sw.Fingerprint(ctx, acctB)
	if fp2 == fp1 {
		t.Fatal("fingerprint must change when the lineage changes (re-login)")
	}
}
