package signin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// memKeychain stands in for /usr/bin/security: an in-memory item table
// behind the Keychain adapter's own command lines.
type memKeychain struct {
	mu    sync.Mutex
	items map[string][]byte // service \x00 account
}

func (k *memKeychain) run(_ context.Context, stdin []byte, _ string, args ...string) ([]byte, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	flag := func(list []string, f string) string {
		for i, a := range list {
			if a == f && i+1 < len(list) {
				return strings.Trim(list[i+1], `"`)
			}
		}
		return ""
	}
	switch {
	case len(args) > 0 && args[0] == "-i":
		line := string(stdin)
		quoted := func(f string) string {
			_, rest, _ := strings.Cut(line, f+` "`)
			v, _, _ := strings.Cut(rest, `"`)
			return v
		}
		_, hexPart, _ := strings.Cut(line, "-X ")
		var val []byte
		if _, err := fmt.Sscanf(strings.Fields(hexPart)[0], "%x", &val); err != nil {
			return nil, err
		}
		k.items[quoted("-s")+"\x00"+quoted("-a")] = val
		return nil, nil
	case args[0] == "add-generic-password":
		var val []byte
		if _, err := fmt.Sscanf(flag(args, "-X"), "%x", &val); err != nil {
			return nil, err
		}
		k.items[flag(args, "-s")+"\x00"+flag(args, "-a")] = val
		return nil, nil
	case args[0] == "find-generic-password":
		svc, acct := flag(args, "-s"), flag(args, "-a")
		for key, v := range k.items {
			s, a, _ := strings.Cut(key, "\x00")
			if s == svc && (acct == "" || a == acct) {
				return append(append([]byte{}, v...), '\n'), nil
			}
		}
		return nil, exit44{}
	case args[0] == "delete-generic-password":
		delete(k.items, flag(args, "-s")+"\x00"+flag(args, "-a"))
		return nil, nil
	case args[0] == "dump-keychain":
		var b strings.Builder
		for key := range k.items {
			s, a, _ := strings.Cut(key, "\x00")
			fmt.Fprintf(&b, "keychain: \"/tmp/x.keychain-db\"\nclass: \"genp\"\nattributes:\n    \"acct\"<blob>=%q\n    \"svce\"<blob>=%q\n", a, s)
		}
		return []byte(b.String()), nil
	}
	return nil, fmt.Errorf("unhandled: %v", args)
}

type exit44 struct{}

func (exit44) Error() string { return "exit status 44" }
func (exit44) ExitCode() int { return 44 }

const fakeScript = `#!/bin/sh
printf 'Opening browser to sign in…\n'
printf 'If the browser didn'"'"'t open, visit: https://claude.com/cai/oauth/authorize?code=true&state=s\n'
case "$FAKE_MODE" in
  ok)
    printf '{"oauthAccount":{"accountUuid":"u-1","emailAddress":"%s"}}' "$FAKE_EMAIL" > "$CLAUDE_CONFIG_DIR/.claude.json"
    printf '{"claudeAiOauth":{"accessToken":"tok-NEW","refreshToken":"r-NEW","expiresAt":4102444800000}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
    exit 0 ;;
  fail) printf 'OAuth error: access_denied\n'; exit 1 ;;
  *) trap '' TERM; while :; do sleep 1; done ;;
esac
`

type harness struct {
	m     *Manager
	sw    *switcher.Switcher
	kc    *memKeychain
	fleet claudecfg.Dir
	home  string
	bin   string
	log   *bytes.Buffer
}

func newHarness(t *testing.T, mode, email string) *harness {
	t.Helper()
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}
	fleetPath := filepath.Join(root, "claude-fleet")
	if err := os.MkdirAll(fleetPath, 0o700); err != nil {
		t.Fatal(err)
	}
	fleet := claudecfg.DirAt(fleetPath)
	if err := os.WriteFile(fleet.ConfigJSONPath(), []byte(`{"oauthAccount":{"emailAddress":"a@example.dev"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	kc := &memKeychain{items: map[string][]byte{}}
	keychain := &switcher.Keychain{File: filepath.Join(root, "throwaway.keychain-db"), Run: kc.run}
	if err := keychain.Set(context.Background(), fleet.KeychainService(), "tester",
		[]byte(`{"claudeAiOauth":{"accessToken":"tok-A","refreshToken":"r-A","expiresAt":4102444800000}}`)); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(root, "llmpilot")
	st := store.At(home)
	if err := st.SaveAccounts([]store.Account{{ID: "acct-a", Label: "a", Email: "a@example.dev", ConfigDir: fleetPath}}); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	sw := &switcher.Switcher{Dir: fleet, Keychain: keychain, Registry: st, Out: &out, KeychainAccount: "tester",
		ScanDirs: func() ([]string, error) { return nil, nil }}
	bin := filepath.Join(root, "bin", "claude")
	if err := os.MkdirAll(filepath.Dir(bin), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(bin, []byte(fakeScript), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Manager{
		Home:     home,
		Switcher: sw,
		CLI: func(context.Context) (claudecfg.CLI, error) {
			return claudecfg.CLI{Path: bin, Env: []string{"PATH=/usr/bin:/bin", "FAKE_MODE=" + mode, "FAKE_EMAIL=" + email}}, nil
		},
	}
	t.Cleanup(func() {
		if strings.Contains(out.String(), "tok-NEW") || strings.Contains(out.String(), "r-NEW") {
			t.Errorf("transcript leaked a token:\n%s", out.String())
		}
	})
	return &harness{m: m, sw: sw, kc: kc, fleet: fleet, home: home, bin: bin, log: &out}
}

func (h *harness) stagingDirs(t *testing.T) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(h.home, stagingRoot))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func waitDone(t *testing.T, a *Attempt) {
	t.Helper()
	select {
	case <-a.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("sign-in never finished")
	}
}

func TestSignInAddsAccountAndCleansUp(t *testing.T) {
	h := newHarness(t, "ok", "c@example.dev")
	a, err := h.m.Start(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(a.dir.Path())
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("staging folder mode = %v, %v", info.Mode(), err)
	}
	waitDone(t, a)
	res, err := a.Finish(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if res.Outcome != switcher.ImportAdded || res.Account.Email != "c@example.dev" {
		t.Fatalf("result = %+v", res)
	}
	if left := h.stagingDirs(t); len(left) != 0 {
		t.Fatalf("staging left behind: %v", left)
	}
	b, _, err := h.sw.LoadBackup(context.Background(), res.Account.ID)
	if err != nil || !strings.Contains(string(b), "tok-NEW") {
		t.Fatalf("backup = %s, %v", b, err)
	}
	var cred struct {
		ClaudeAiOauth struct{ AccessToken string } `json:"claudeAiOauth"`
	}
	live, _ := h.sw.Keychain.Get(context.Background(), h.fleet.KeychainService())
	if json.Unmarshal(live, &cred) != nil || cred.ClaudeAiOauth.AccessToken != "tok-A" {
		t.Fatalf("Claude Code's sign-in changed: %s", live)
	}
}

func TestSignInFailureCleansUp(t *testing.T) {
	h := newHarness(t, "fail", "")
	a, err := h.m.Start(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	waitDone(t, a)
	if _, err := a.Finish(context.Background()); err == nil || !strings.Contains(err.Error(), "access_denied") {
		t.Fatalf("Finish err = %v", err)
	}
	if left := h.stagingDirs(t); len(left) != 0 {
		t.Fatalf("staging left behind: %v", left)
	}
}

func TestAbortStopsAndCleansUp(t *testing.T) {
	h := newHarness(t, "hang", "")
	a, err := h.m.Start(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	pid := a.sess.PID()
	a.Abort()
	if syscall.Kill(pid, 0) == nil {
		t.Fatal("sign-in process still running after Abort")
	}
	if left := h.stagingDirs(t); len(left) != 0 {
		t.Fatalf("staging left behind: %v", left)
	}
	a.Abort() // idempotent
}

func TestStartWithoutClaudeCode(t *testing.T) {
	h := newHarness(t, "ok", "")
	h.m.CLI = func(context.Context) (claudecfg.CLI, error) { return claudecfg.CLI{}, claudecfg.ErrCLINotFound }
	if _, err := h.m.Start(context.Background(), ""); !errors.Is(err, claudecfg.ErrCLINotFound) {
		t.Fatalf("err = %v", err)
	}
	if left := h.stagingDirs(t); len(left) != 0 {
		t.Fatalf("staging left behind: %v", left)
	}
}

func TestRemoveRefusesAnythingButAStagingFolder(t *testing.T) {
	h := newHarness(t, "ok", "")
	root := filepath.Join(h.home, stagingRoot)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	victims := []string{
		h.fleet.Path(),               // Claude Code's own folder
		root,                         // the staging root itself
		filepath.Join(root, "notes"), // not an attempt folder
		filepath.Join(root, "attempt-x", "..", "..", "x"), // escapes the root
		filepath.Join(h.home, attemptPrefix+"outside"),    // right name, wrong parent
	}
	for _, v := range victims {
		if err := os.MkdirAll(v, 0o700); err != nil {
			t.Fatal(err)
		}
		h.m.remove(context.Background(), v)
		if _, err := os.Stat(v); err != nil {
			t.Errorf("remove deleted %s", v)
		}
	}
	// A symlink named like an attempt that points at the fleet folder.
	link := filepath.Join(root, attemptPrefix+"link")
	if err := os.Symlink(h.fleet.Path(), link); err != nil {
		t.Fatal(err)
	}
	h.m.remove(context.Background(), link)
	if _, err := os.Stat(h.fleet.ConfigJSONPath()); err != nil {
		t.Fatal("a symlinked attempt name reached the fleet folder")
	}
	live, err := h.sw.Keychain.Get(context.Background(), h.fleet.KeychainService())
	if err != nil || !strings.Contains(string(live), "tok-A") {
		t.Fatal("Claude Code's Keychain item was touched")
	}
}

func TestSweepStopsLeftoverSignInAndRemovesIt(t *testing.T) {
	h := newHarness(t, "hang", "")
	root := filepath.Join(h.home, stagingRoot)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	// A leftover from a daemon that died mid-attempt: a running sign-in in
	// its folder, the pid recorded, and a staging Keychain item.
	leftover := filepath.Join(root, attemptPrefix+"crashed")
	if err := os.MkdirAll(leftover, 0o700); err != nil {
		t.Fatal(err)
	}
	cli, _ := h.m.CLI(context.Background())
	sess, err := claudecfg.StartLogin(claudecfg.LoginOptions{CLI: cli, ConfigDir: leftover})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sess.Stop)
	if err := os.WriteFile(filepath.Join(leftover, pidFile), []byte(strconv.Itoa(sess.PID())), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := h.sw.Keychain.Set(context.Background(), claudecfg.DirAt(leftover).KeychainService(), "tester", []byte(`{"x":1}`)); err != nil {
		t.Fatal(err)
	}
	// Another leftover whose recorded pid now belongs to something else.
	other := exec.Command("/bin/sleep", "30")
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = other.Process.Kill(); _ = other.Wait() })
	recycled := filepath.Join(root, attemptPrefix+"recycled")
	if err := os.MkdirAll(recycled, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(recycled, pidFile), []byte(strconv.Itoa(other.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}

	h.m.Sweep(context.Background())

	select {
	case <-sess.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("the leftover sign-in is still running")
	}
	if syscall.Kill(other.Process.Pid, 0) != nil {
		t.Fatal("Sweep killed a process that was not a sign-in")
	}
	if left := h.stagingDirs(t); len(left) != 0 {
		t.Fatalf("staging left behind: %v", left)
	}
	if svc, _ := h.sw.Keychain.List(context.Background(), claudecfg.DirAt(leftover).KeychainService()); len(svc) != 0 {
		t.Fatalf("staging Keychain item left behind: %v", svc)
	}
}
