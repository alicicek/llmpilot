package claudecfg

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// The golden pair was computed outside Go:
//
//	printf '%s' "/Users/demo/.claude-work" | shasum -a 256 | cut -c1-8  →  4fbe0f72
//
// The same scheme was verified live against a real Claude Code Keychain
// entry on 2026-07-08.
func TestKeychainServiceDerivation(t *testing.T) {
	d := DirAt("/Users/demo/.claude-work")
	want := "Claude Code-credentials-4fbe0f72"
	if got := d.KeychainService(); got != want {
		t.Fatalf("KeychainService() = %q, want %q", got, want)
	}
}

func TestKeychainServiceTrailingSlashCleaned(t *testing.T) {
	a := DirAt("/Users/demo/.claude-work")
	b := DirAt("/Users/demo/.claude-work/")
	if a.KeychainService() != b.KeychainService() {
		t.Fatalf("trailing slash changed service name: %q vs %q",
			a.KeychainService(), b.KeychainService())
	}
}

func TestDefaultDirLayout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")

	d, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	if !d.IsDefault() {
		t.Fatal("unset CLAUDE_CONFIG_DIR should yield the default dir")
	}
	if got, want := d.Path(), filepath.Join(home, ".claude"); got != want {
		t.Fatalf("Path() = %q, want %q", got, want)
	}
	if got, want := d.ConfigJSONPath(), filepath.Join(home, ".claude.json"); got != want {
		t.Fatalf("ConfigJSONPath() = %q, want %q (default keeps the $HOME sibling)", got, want)
	}
	if got := d.KeychainService(); got != "Claude Code-credentials" {
		t.Fatalf("default KeychainService() = %q, want bare name", got)
	}
}

func TestCustomDirLayout(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	custom := filepath.Join(home, "work", "claude-b")
	t.Setenv("CLAUDE_CONFIG_DIR", custom)

	d, err := DefaultDir()
	if err != nil {
		t.Fatal(err)
	}
	if d.IsDefault() {
		t.Fatal("set CLAUDE_CONFIG_DIR must not be the default dir")
	}
	if got, want := d.ConfigJSONPath(), filepath.Join(custom, ".claude.json"); got != want {
		t.Fatalf("ConfigJSONPath() = %q, want %q (custom keeps the file inside the dir)", got, want)
	}
	if got, want := d.CredentialsFilePath(), filepath.Join(custom, ".credentials.json"); got != want {
		t.Fatalf("CredentialsFilePath() = %q, want %q", got, want)
	}
}

func TestDirAtHomeClaudeIsDefault(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	d := DirAt(filepath.Join(home, ".claude"))
	if !d.IsDefault() {
		t.Fatal("DirAt(~/.claude) should behave as the default layout")
	}
}

func TestOAuthAccountParsesSubset(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	custom := filepath.Join(home, "cfg-a")
	if err := os.MkdirAll(custom, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := `{
	  "numStartups": 42,
	  "oauthAccount": {
	    "accountUuid": "11111111-2222-3333-4444-555555555555",
	    "emailAddress": "a@example.dev",
	    "organizationUuid": "66666666-7777-8888-9999-000000000000",
	    "displayName": "A Demo",
	    "billingType": "stripe_subscription",
	    "organizationRateLimitTier": "default_claude_max_20x",
	    "someFutureField": {"nested": true}
	  },
	  "otherTopLevelNoise": [1, 2, 3]
	}`
	if err := os.WriteFile(filepath.Join(custom, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}

	acct, err := DirAt(custom).OAuthAccount()
	if err != nil {
		t.Fatal(err)
	}
	if acct == nil {
		t.Fatal("want oauthAccount, got nil")
	}
	if acct.EmailAddress != "a@example.dev" {
		t.Fatalf("EmailAddress = %q", acct.EmailAddress)
	}
	if acct.OrganizationRateLimitTier != "default_claude_max_20x" {
		t.Fatalf("OrganizationRateLimitTier = %q", acct.OrganizationRateLimitTier)
	}
}

func TestOAuthAccountMissingFileIsNil(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	acct, err := DirAt(filepath.Join(home, "nonexistent")).OAuthAccount()
	if err != nil {
		t.Fatalf("missing config file should not error, got %v", err)
	}
	if acct != nil {
		t.Fatalf("want nil account, got %+v", acct)
	}
}

func TestOAuthAccountLoggedOutIsNil(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	custom := filepath.Join(home, "cfg-b")
	if err := os.MkdirAll(custom, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(custom, ".claude.json"), []byte(`{"numStartups": 1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	acct, err := DirAt(custom).OAuthAccount()
	if err != nil {
		t.Fatal(err)
	}
	if acct != nil {
		t.Fatalf("logged-out dir should have nil account, got %+v", acct)
	}
}

func TestVersionDetection(t *testing.T) {
	ctx := context.Background()
	cases := []struct {
		name string
		out  string
		err  error
		want string
	}{
		{"real output", "2.1.205 (Claude Code)\n", nil, "2.1.205"},
		{"newer version", "3.0.1 (Claude Code)\n", nil, "3.0.1"},
		{"binary missing", "", errors.New("exec: not found"), FallbackVersion},
		{"garbage", "surprise!\n", nil, FallbackVersion},
		{"empty", "", nil, FallbackVersion},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			run := func(context.Context, string, ...string) ([]byte, error) {
				return []byte(c.out), c.err
			}
			if got := Version(ctx, run); got != c.want {
				t.Fatalf("Version() = %q, want %q", got, c.want)
			}
		})
	}
}
