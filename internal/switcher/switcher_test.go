package switcher

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// fakeKeychain is an in-memory /usr/bin/security stand-in for unit tests.
// Keyed service+"\x00"+account; Get without account matches any account on
// the service (like `security find-generic-password -s`).
type fakeKeychain struct {
	mu    sync.Mutex
	items map[string][]byte
	log   []string
}

func newFakeKeychain() *fakeKeychain { return &fakeKeychain{items: map[string][]byte{}} }

func (f *fakeKeychain) keychain() *Keychain {
	return &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: f.run}
}

func (f *fakeKeychain) run(_ context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log = append(f.log, name+" "+strings.Join(args, " "))
	joined := strings.Join(args, " ")
	switch {
	case len(args) > 0 && args[0] == "-i": // add-generic-password via stdin
		line := string(stdin)
		svc := extractQuoted(line, "-s")
		acct := extractQuoted(line, "-a")
		hexPos := strings.Index(line, "-X ")
		if svc == "" || acct == "" || hexPos < 0 {
			return nil, fmt.Errorf("bad add line: %s", line)
		}
		hexStr := strings.Fields(line[hexPos+3:])[0]
		var val []byte
		if _, err := fmt.Sscanf(hexStr, "%x", &val); err != nil {
			return nil, err
		}
		f.items[svc+"\x00"+acct] = val
		return nil, nil
	case strings.HasPrefix(joined, "add-generic-password"): // argv form (oversized payloads)
		svc, acct, hexStr := flagVal(args, "-s"), flagVal(args, "-a"), flagVal(args, "-X")
		if svc == "" || acct == "" || hexStr == "" {
			return nil, fmt.Errorf("bad add argv: %s", joined)
		}
		var val []byte
		if _, err := fmt.Sscanf(hexStr, "%x", &val); err != nil {
			return nil, err
		}
		f.items[svc+"\x00"+acct] = val
		return nil, nil
	case strings.HasPrefix(joined, "find-generic-password"):
		svc, acct := flagVal(args, "-s"), flagVal(args, "-a")
		for k, v := range f.items {
			parts := strings.SplitN(k, "\x00", 2)
			if parts[0] == svc && (acct == "" || parts[1] == acct) {
				// Return a FRESH copy — the real /usr/bin/security hands back
				// its own bytes. Aliasing the stored slice lets a concurrent
				// reader and this appender race on one backing array (and would
				// hand two callers the same mutable buffer).
				out := make([]byte, len(v)+1)
				copy(out, v)
				out[len(v)] = '\n'
				return out, nil
			}
		}
		return nil, fakeExit44{}
	case strings.HasPrefix(joined, "delete-generic-password"):
		svc, acct := flagVal(args, "-s"), flagVal(args, "-a")
		delete(f.items, svc+"\x00"+acct)
		return nil, nil
	}
	return nil, fmt.Errorf("unhandled security call: %s", joined)
}

type fakeExit44 struct{}

func (fakeExit44) Error() string { return "exit status 44" }

func flagVal(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func extractQuoted(line, flag string) string {
	i := strings.Index(line, flag+` "`)
	if i < 0 {
		return ""
	}
	rest := line[i+len(flag)+2:]
	j := strings.Index(rest, `"`)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

// exitCode must see 44 through our fake error too.
func (fakeExit44) ExitCode() int { return 44 }

// sandbox builds a fake config dir with a logged-in account "a" and
// registers backups for both accounts in the fake keychain.
func sandbox(t *testing.T) (*Switcher, *fakeKeychain, claudecfg.Dir, *bytes.Buffer) {
	t.Helper()
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	cfgDir := filepath.Join(root, "claude-a")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cfgDir)
	writeConfig(t, dir, "a@example.dev", `{"projects":{"/x":{"allowed":true}},"userSettings":{"theme":"dark"}}`)

	fk := newFakeKeychain()
	kc := fk.keychain()
	// current live credential for a
	if err := kc.Set(context.Background(), dir.KeychainService(), "tester", credJSON("token-a-LIVE")); err != nil {
		t.Fatal(err)
	}

	st := store.At(filepath.Join(root, "llmpilot"))
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-a", Label: "a", Email: "a@example.dev", ConfigDir: cfgDir},
		{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: cfgDir},
	}); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	sw := &Switcher{Dir: dir, Keychain: kc, Registry: st, Out: &out, KeychainAccount: "tester"}
	// seed b's backup (as `llmpilot account add` would have)
	if err := sw.SaveBackup(context.Background(), "acct-b", credJSON("token-b-STORED"), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	return sw, fk, dir, &out
}

func credJSON(tok string) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(
		`{"claudeAiOauth":{"accessToken":%q,"refreshToken":"r-%s","expiresAt":4102444800000}}`, tok, tok))
}

func oauthJSON(email string) json.RawMessage {
	return json.RawMessage(fmt.Sprintf(`{"accountUuid":"uuid-%s","emailAddress":%q}`, email, email))
}

func writeConfig(t *testing.T, dir claudecfg.Dir, email, base string) {
	t.Helper()
	var doc map[string]json.RawMessage
	if err := json.Unmarshal([]byte(base), &doc); err != nil {
		t.Fatal(err)
	}
	doc["oauthAccount"] = oauthJSON(email)
	data, _ := json.MarshalIndent(doc, "", "  ")
	if err := os.WriteFile(dir.ConfigJSONPath(), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func readEmail(t *testing.T, dir claudecfg.Dir) string {
	t.Helper()
	acct, err := dir.OAuthAccount()
	if err != nil || acct == nil {
		t.Fatalf("read oauthAccount: %v %v", acct, err)
	}
	return acct.EmailAddress
}

func TestSwapFullCycle(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()

	if got := readEmail(t, dir); got != "a@example.dev" {
		t.Fatalf("before: %s", got)
	}
	target := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}
	if err := sw.Swap(ctx, target); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if got := readEmail(t, dir); got != "b@example.dev" {
		t.Fatalf("after: %s", got)
	}
	// live credential is now b's
	live := fk.items[dir.KeychainService()+"\x00tester"]
	if !strings.Contains(string(live), "token-b-STORED") {
		t.Fatalf("live credential = %s", live)
	}
	// a's credential was backed up before the overwrite
	backup := fk.items[BackupService+"\x00acct-a"]
	if !strings.Contains(string(backup), "token-a-LIVE") {
		t.Fatalf("backup for acct-a = %s", backup)
	}
	// untouched config keys survived the splice
	docBytes, _ := os.ReadFile(dir.ConfigJSONPath())
	if !strings.Contains(string(docBytes), `"theme": "dark"`) && !strings.Contains(string(docBytes), `"theme":"dark"`) {
		t.Fatalf("splice dropped unrelated keys:\n%s", docBytes)
	}
	// no token material in the transcript
	for _, secret := range []string{"token-a-LIVE", "token-b-STORED", "r-token"} {
		if strings.Contains(out.String(), secret) {
			t.Fatalf("transcript leaked %q:\n%s", secret, out.String())
		}
	}
	// locks all released
	for _, p := range []string{dir.OAuthRefreshLockPath(), dir.StorageWriteLockPath(),
		dir.LegacyCredentialsLockPath(), dir.LegacyConfigLockPath()} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("lock %s not released", p)
		}
	}
}

// TestBackupRoundTrip is the Proof line: add → swap → restore.
func TestBackupRoundTrip(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	a := store.Account{ID: "acct-a", Label: "a", Email: "a@example.dev"}
	b := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}

	if err := sw.Swap(ctx, b); err != nil {
		t.Fatalf("swap to b: %v\n%s", err, out.String())
	}
	if err := sw.Swap(ctx, a); err != nil { // restore
		t.Fatalf("swap back to a: %v\n%s", err, out.String())
	}
	if got := readEmail(t, dir); got != "a@example.dev" {
		t.Fatalf("after round trip: %s", got)
	}
	live := fk.items[dir.KeychainService()+"\x00tester"]
	if !strings.Contains(string(live), "token-a-LIVE") {
		t.Fatalf("round trip lost a's original token: %s", live)
	}
}

// TestSwapWithRealSizedCredential: real Claude Code payloads are ~8KB, which
// overflows `security -i`'s line buffer — the argv fallback must kick in and
// the full swap must still round-trip.
func TestSwapWithRealSizedCredential(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	big := json.RawMessage(fmt.Sprintf(
		`{"claudeAiOauth":{"accessToken":"token-a-LIVE","refreshToken":"r-a","expiresAt":4102444800000,"padding":%q}}`,
		strings.Repeat("x", 8000)))
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", big); err != nil {
		t.Fatalf("oversized Set: %v", err)
	}
	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap with oversized current credential: %v\n%s", err, out.String())
	}
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if !strings.Contains(backup, "token-a-LIVE") || len(backup) < 8000 {
		t.Fatalf("oversized credential not fully backed up (%d bytes)", len(backup))
	}
}

func TestSwapRefusesUnknownBackup(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	err := sw.Swap(context.Background(), store.Account{ID: "acct-c", Label: "c"})
	if err == nil || !strings.Contains(err.Error(), "no stored credential") {
		t.Fatalf("err = %v", err)
	}
}

// TestRefreshClobberRace is the Proof line: a concurrent fake "Claude
// refresh" (which takes the SAME oauth_refresh mkdir lock the real binary
// takes, rotates the refresh token, and writes back) racing a swap. The
// invariant: no interleaving — after both finish, the rotated credential is
// exactly what the swap backed up; nothing is lost.
func TestRefreshClobberRace(t *testing.T) {
	sw, fk, dir, out := sandbox(t)
	ctx := context.Background()
	sw.LockTimeout = 5 * time.Second

	lockHeld := make(chan struct{})
	refresherDone := make(chan error, 1)
	go func() {
		// Fake Claude Code refresh: acquire .oauth_refresh.lock (10s stale,
		// like the real binary), then read-rotate-write the credential.
		l, err := acquireLock(ctx, dir.OAuthRefreshLockPath(), 10*time.Second, 5*time.Second)
		if err != nil {
			close(lockHeld)
			refresherDone <- err
			return
		}
		close(lockHeld) // deterministic: the swap starts only once we hold it
		fk.mu.Lock()
		cur := fk.items[dir.KeychainService()+"\x00tester"]
		fk.mu.Unlock()
		time.Sleep(150 * time.Millisecond) // hold the lock across the "network refresh"
		rotated := strings.Replace(string(cur), "token-a-LIVE", "token-a-ROTATED", 1)
		fk.mu.Lock()
		fk.items[dir.KeychainService()+"\x00tester"] = []byte(rotated)
		fk.mu.Unlock()
		l.release()
		refresherDone <- nil
	}()

	<-lockHeld // the swap below MUST find the lock taken and wait
	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if err := <-refresherDone; err != nil {
		t.Fatalf("refresher: %v", err)
	}

	// The swap ran AFTER the refresh completed (lock ordering), so the
	// backup captured the ROTATED token — the pre-rotation token would be a
	// permanently dead refresh token (the clobber hazard).
	backup := string(fk.items[BackupService+"\x00acct-a"])
	if !strings.Contains(backup, "token-a-ROTATED") {
		t.Fatalf("backup holds a pre-rotation token — refresh-clobber NOT closed:\n%s\n%s", backup, out.String())
	}
	live := string(fk.items[dir.KeychainService()+"\x00tester"])
	if !strings.Contains(live, "token-b-STORED") {
		t.Fatalf("live credential after swap = %s", live)
	}
}

// TestSwapWaitsOutStaleLock: a dead process's lock (old mtime) must be
// taken over, not waited on forever.
func TestSwapTakesOverStaleLock(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	if err := os.Mkdir(dir.OAuthRefreshLockPath(), 0o755); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute)
	if err := os.Chtimes(dir.OAuthRefreshLockPath(), old, old); err != nil {
		t.Fatal(err)
	}
	sw.LockTimeout = 2 * time.Second
	if err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap should take over the stale lock: %v\n%s", err, out.String())
	}
}

func TestSwapTimesOutOnLiveLock(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	l, err := acquireLock(context.Background(), dir.OAuthRefreshLockPath(), 10*time.Second, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer l.release()
	sw.LockTimeout = 300 * time.Millisecond
	err = sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "held by a live process") {
		t.Fatalf("err = %v", err)
	}
}

// --- interlock fail cases (Protocol: test every guard's fail case) ---

func TestInterlockRefusesRealConfigJSON(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	err = assertSandboxConfigPath(filepath.Join(home, ".claude.json"))
	if err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Fatalf("real ~/.claude.json accepted under LLMPILOT_TEST: %v", err)
	}
	err = assertSandboxConfigPath(filepath.Join(home, ".claude", ".claude.json"))
	if err == nil {
		t.Fatal("path under real ~/.claude accepted under LLMPILOT_TEST")
	}
}

// TestInterlockRefusesCaseVariantPath pins the adversarial-review P1: the
// default APFS volume is case-insensitive, so a case-variant spelling of the
// real config path reaches the real file and must be refused by identity.
func TestInterlockRefusesCaseVariantPath(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	variants := []string{
		strings.ToUpper(home) + "/.claude.json",
		filepath.Join(home, ".CLAUDE.json"),
		filepath.Join(strings.ToUpper(home), ".claude", ".claude.json"),
	}
	for _, v := range variants {
		if err := assertSandboxConfigPath(v); err == nil {
			t.Fatalf("case-variant %q accepted under LLMPILOT_TEST", v)
		}
	}
}

func TestInterlockRefusesSymlinkEscape(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home, ".claude.json")); err != nil {
		t.Skip("no real ~/.claude.json on this machine")
	}
	tmp := t.TempDir()
	link := filepath.Join(tmp, "innocent.json")
	if err := os.Symlink(filepath.Join(home, ".claude.json"), link); err != nil {
		t.Fatal(err)
	}
	if err := assertSandboxConfigPath(link); err == nil {
		t.Fatal("symlink to real ~/.claude.json accepted under LLMPILOT_TEST")
	}
}

func TestKeychainWriteInterlockRequiresThrowaway(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	kc := &Keychain{ /* no File */ Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
		t.Fatal("runner must not be reached when the interlock trips")
		return nil, nil
	}}
	if err := kc.Set(context.Background(), "svc", "acct", []byte("x")); err == nil {
		t.Fatal("keychain write without throwaway file accepted under LLMPILOT_TEST")
	}
	if _, err := kc.Get(context.Background(), "svc"); err == nil {
		t.Fatal("keychain read without throwaway file accepted under LLMPILOT_TEST")
	}
	if err := kc.Delete(context.Background(), "svc", "acct"); err == nil {
		t.Fatal("keychain delete without throwaway file accepted under LLMPILOT_TEST")
	}
	home, _ := os.UserHomeDir()
	login := &Keychain{File: filepath.Join(home, "Library", "Keychains", "login.keychain-db")}
	if err := login.Set(context.Background(), "svc", "acct", []byte("x")); err == nil {
		t.Fatal("login keychain accepted under LLMPILOT_TEST")
	}
}

func TestSpliceRefusedOutsideSandboxLeavesConfigIntact(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	before, err := os.ReadFile(dir.ConfigJSONPath())
	if err != nil {
		t.Fatal(err)
	}
	// point the switcher at the real home config — must refuse before writing
	home, _ := os.UserHomeDir()
	sw.Dir = claudecfg.DirAt(filepath.Join(home, ".claude"))
	err = sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b"})
	if err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Fatalf("swap against real config dir: err = %v", err)
	}
	after, err := os.ReadFile(dir.ConfigJSONPath())
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("sandbox config mutated by a refused swap")
	}
}
