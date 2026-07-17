package switcher

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// writeStubClaude creates a real executable standing in for `claude`: it
// asserts it was invoked as `claude auth login`, then "logs in" by writing
// an oauthAccount into $CLAUDE_CONFIG_DIR's .claude.json — what the real
// binary does at the end of its OAuth flow.
func writeStubClaude(t *testing.T, dir, email string) string {
	t.Helper()
	stub := filepath.Join(dir, "claude")
	script := fmt.Sprintf(`#!/bin/sh
[ "$1" = "auth" ] && [ "$2" = "login" ] || { echo "unexpected args: $@" >&2; exit 2; }
[ -n "$CLAUDE_CONFIG_DIR" ] || { echo "CLAUDE_CONFIG_DIR not set" >&2; exit 3; }
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<EOF
{"oauthAccount":{"accountUuid":"uuid-stub","emailAddress":"%s"},"stubKey":true}
EOF
echo "stub login ok"
`, email)
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil { //nolint:gosec // test stub
		t.Fatal(err)
	}
	return stub
}

// TestAddAccountWrapsClaudeAuthLogin is the Proof line: the add flow runs a
// real subprocess (the stub) with inherited stdio under the target
// CLAUDE_CONFIG_DIR, then captures the credential and registers the account.
func TestAddAccountWrapsClaudeAuthLogin(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	cfgDir := filepath.Join(root, "claude-new")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cfgDir)
	stub := writeStubClaude(t, root, "new@example.dev")

	fk := newFakeKeychain()
	st := store.At(filepath.Join(root, "llmpilot"))
	sw := &Switcher{Dir: dir, Keychain: fk.keychain(), Registry: st, KeychainAccount: "tester"}

	// The login runner is ExecLoginRunner itself — a REAL subprocess exec —
	// wrapped only to seed the fake keychain afterwards (standing in for the
	// real binary's own Keychain write, which a shell stub cannot do against
	// an in-memory fake).
	login := func(ctx context.Context, env []string, name string, args ...string) error {
		if err := ExecLoginRunner(ctx, env, name, args...); err != nil {
			return err
		}
		return fk.keychain().Set(ctx, dir.KeychainService(), "tester", credJSON("token-new"))
	}

	res, err := sw.AddAccount(context.Background(), dir, "", login, stub)
	if err != nil {
		t.Fatal(err)
	}
	if res.LoggedVia != "claude auth login" {
		t.Fatalf("LoggedVia = %q", res.LoggedVia)
	}
	if res.Account.Email != "new@example.dev" || res.Account.Label != "new" {
		t.Fatalf("account = %+v", res.Account)
	}
	// registered in the store
	accs, err := st.Accounts()
	if err != nil || len(accs) != 1 || accs[0].Email != "new@example.dev" {
		t.Fatalf("registry = %+v, %v", accs, err)
	}
	// credential captured into backups
	backup := string(fk.items[BackupService+"\x00"+res.Account.ID])
	if !strings.Contains(backup, "token-new") {
		t.Fatalf("backup = %s", backup)
	}
	// and the captured account is immediately swappable
	if err := sw.Swap(context.Background(), res.Account); err != nil {
		t.Fatalf("swap to freshly added account: %v", err)
	}
}

func TestAddAccountExistingSessionSkipsLogin(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	cfgDir := filepath.Join(root, "claude-a")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cfgDir)
	if err := os.WriteFile(dir.ConfigJSONPath(),
		[]byte(`{"oauthAccount":{"emailAddress":"here@example.dev"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	fk := newFakeKeychain()
	if err := fk.keychain().Set(context.Background(), dir.KeychainService(), "tester", credJSON("token-here")); err != nil {
		t.Fatal(err)
	}
	sw := &Switcher{Dir: dir, Keychain: fk.keychain(), KeychainAccount: "tester"}

	res, err := sw.AddAccount(context.Background(), dir, "work",
		func(context.Context, []string, string, ...string) error {
			t.Fatal("login must not run for an already-logged-in dir")
			return nil
		}, "claude")
	if err != nil {
		t.Fatal(err)
	}
	if res.LoggedVia != "existing session" || res.Account.Label != "work" {
		t.Fatalf("res = %+v", res)
	}
}

func TestAddAccountFailsWhenLoginLeavesNoIdentity(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	root := t.TempDir()
	cfgDir := filepath.Join(root, "claude-x")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(cfgDir)
	fk := newFakeKeychain()
	sw := &Switcher{Dir: dir, Keychain: fk.keychain(), KeychainAccount: "tester"}
	_, err := sw.AddAccount(context.Background(), dir, "",
		func(context.Context, []string, string, ...string) error { return nil }, "claude")
	if err == nil || !strings.Contains(err.Error(), "no oauthAccount") {
		t.Fatalf("err = %v", err)
	}
}
