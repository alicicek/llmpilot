// Package claudecfg is the adapter for Claude Code's own on-disk layout:
// config directories, the .claude.json config file, its oauthAccount block,
// and macOS Keychain service naming. Every Claude-Code-internal detail lives
// here and nowhere else — this surface is undocumented and version-fragile.
//
// Verified live against Claude Code 2.1.205 on 2026-07-08:
//   - default (CLAUDE_CONFIG_DIR unset): config dir ~/.claude, config file
//     ~/.claude.json (sibling, at $HOME), Keychain service
//     "Claude Code-credentials".
//   - custom CLAUDE_CONFIG_DIR: config file <dir>/.claude.json (inside the
//     dir), Keychain service "Claude Code-credentials-<h>" where <h> is the
//     first 8 hex chars of sha256 of the directory path as Claude Code saw
//     it (absolute, no trailing slash).
package claudecfg

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"crypto/sha256"
)

const keychainServiceBase = "Claude Code-credentials"

// Dir is one Claude Code config directory.
type Dir struct {
	path      string
	isDefault bool
}

// DefaultDir resolves the config dir Claude Code itself would use in this
// process's environment: $CLAUDE_CONFIG_DIR if set, else ~/.claude.
func DefaultDir() (Dir, error) {
	if p := os.Getenv("CLAUDE_CONFIG_DIR"); p != "" {
		return DirAt(p), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return Dir{}, fmt.Errorf("resolve home dir: %w", err)
	}
	return Dir{path: filepath.Join(home, ".claude"), isDefault: true}, nil
}

// GlobalDir resolves the machine-GLOBAL config dir (~/.claude) regardless of
// this process's CLAUDE_CONFIG_DIR. The daemon's autonomous paths (active-
// account detection, rotation writes, delegated refresh) MUST use this: a
// daemon started foreground in a pinned terminal would otherwise adopt that
// terminal's pin as "the global account" and autonomously rotate the wrong
// one. Under LLMPILOT_TEST the env redirect is honored — sandboxes point
// the whole daemon at a fake dir.
func GlobalDir() (Dir, error) {
	if os.Getenv("LLMPILOT_TEST") != "" {
		return DefaultDir()
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return Dir{}, fmt.Errorf("resolve home dir: %w", err)
	}
	return Dir{path: filepath.Join(home, ".claude"), isDefault: true}, nil
}

// DirAt wraps an explicit config directory path. A path equal to ~/.claude is
// treated as the default layout, matching Claude Code's unset-variable case.
func DirAt(path string) Dir {
	path = filepath.Clean(path)
	if home, err := os.UserHomeDir(); err == nil && path == filepath.Join(home, ".claude") {
		return Dir{path: path, isDefault: true}
	}
	return Dir{path: path}
}

// Path is the config directory itself.
func (d Dir) Path() string { return d.path }

// IsDefault reports whether this is Claude Code's default config dir
// (~/.claude), which uses the sibling config file and bare Keychain service.
func (d Dir) IsDefault() bool { return d.isDefault }

// ConfigJSONPath is the .claude.json location for this dir: ~/.claude.json
// for the default dir, <dir>/.claude.json for custom dirs.
func (d Dir) ConfigJSONPath() string {
	if d.isDefault {
		return filepath.Join(filepath.Dir(d.path), ".claude.json")
	}
	return filepath.Join(d.path, ".claude.json")
}

// CredentialsFilePath is the on-disk credential fallback location for this
// dir. On macOS the Keychain is the primary store; this file may hold other
// credential material (e.g. MCP OAuth) or the full payload on other setups.
func (d Dir) CredentialsFilePath() string {
	return filepath.Join(d.path, ".credentials.json")
}

// KeychainService is the macOS Keychain service name Claude Code uses for
// this dir's OAuth credentials. Derivation verified live (see package doc);
// if a Claude Code release changes it, enumerate "Claude Code-credentials*"
// items and match instead of deriving.
func (d Dir) KeychainService() string {
	if d.isDefault {
		return keychainServiceBase
	}
	sum := sha256.Sum256([]byte(d.path))
	return keychainServiceBase + "-" + hex.EncodeToString(sum[:4])
}

// OAuthRefreshLockPath is the mkdir-mutex directory Claude Code holds while
// it refreshes OAuth tokens (read → network refresh → write-back). Staleness
// 10s. Verified by strings-dump of the 2.1.205 binary, 2026-07-09.
func (d Dir) OAuthRefreshLockPath() string {
	return filepath.Join(d.path, ".oauth_refresh.lock")
}

// StorageWriteLockPath is the mkdir-mutex directory Claude Code holds around
// secure-storage (Keychain) writes. Staleness 15s. Same verification.
func (d Dir) StorageWriteLockPath() string {
	return filepath.Join(d.path, ".storage-write")
}

// LegacyCredentialsLockPath and LegacyConfigLockPath are the lock dirs
// claude-swap (and possibly older Claude Code builds) use: <configdir>.lock
// and <config json>.lock. Claude Code 2.1.205 never touches them; we take
// them anyway so a concurrent claude-swap cannot interleave with a swap.
func (d Dir) LegacyCredentialsLockPath() string { return d.path + ".lock" }

// LegacyConfigLockPath is the legacy lock guarding the .claude.json file.
func (d Dir) LegacyConfigLockPath() string { return d.ConfigJSONPath() + ".lock" }

// keychainAccountRe mirrors Claude Code's username validation for the
// Keychain item's account attribute.
var keychainAccountRe = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)

// KeychainAccount is the account attribute (-a) Claude Code sets on its
// Keychain items: the current username, or the literal "claude-code-user"
// fallback when it looks unusable (verified in the 2.1.205 binary: `-a` =
// process.env.USER validated against a regex, else "claude-code-user").
func KeychainAccount() string {
	u := os.Getenv("USER")
	if u == "" || !keychainAccountRe.MatchString(u) {
		return "claude-code-user"
	}
	return u
}

// OAuthAccount is the account identity block Claude Code keeps in
// .claude.json. Fields are a lenient subset — unknown fields are ignored and
// absent fields stay zero-valued.
type OAuthAccount struct {
	AccountUUID               string `json:"accountUuid"`
	EmailAddress              string `json:"emailAddress"`
	OrganizationUUID          string `json:"organizationUuid"`
	DisplayName               string `json:"displayName"`
	BillingType               string `json:"billingType"`
	OrganizationRateLimitTier string `json:"organizationRateLimitTier"`
}

// OAuthAccount reads this dir's logged-in account identity. It returns
// (nil, nil) when the config file does not exist or carries no oauthAccount —
// a dir that was never logged in is not an error.
func (d Dir) OAuthAccount() (*OAuthAccount, error) {
	data, err := os.ReadFile(d.ConfigJSONPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var doc struct {
		OAuthAccount *OAuthAccount `json:"oauthAccount"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", d.ConfigJSONPath(), err)
	}
	return doc.OAuthAccount, nil
}

// Runner executes a subprocess and returns its stdout. Injectable so tests
// and CI never depend on a real `claude` binary.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// ExecRunner runs the command for real.
func ExecRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

// FallbackVersion is the Claude Code CLI version assumed when detection
// fails. Pinned against the owner's installed CLI, as-of 2026-07-08.
const FallbackVersion = "2.1.205"

var versionRe = regexp.MustCompile(`^\d+\.\d+\.\d+`)

// Version reports the installed Claude Code CLI version (e.g. "2.1.205",
// from `claude --version` output like "2.1.205 (Claude Code)"), or
// FallbackVersion when the binary is absent or its output unrecognizable.
func Version(ctx context.Context, run Runner) string {
	out, err := run(ctx, "claude", "--version")
	if err != nil {
		return FallbackVersion
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 || !versionRe.MatchString(fields[0]) {
		return FallbackVersion
	}
	return fields[0]
}
