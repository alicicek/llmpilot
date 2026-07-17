// Package anthropic is the adapter for Anthropic's undocumented OAuth usage
// surface: the /api/oauth/usage endpoint, its headers, and the credential
// payload layout. This knowledge is fragile and lives here only.
//
// Receipts (verified live on this machine, as-of 2026-07-08):
//   - GET https://api.anthropic.com/api/oauth/usage with
//     "Authorization: Bearer <access token>" plus
//     "anthropic-beta: oauth-2025-04-20" returns the usage document. We also
//     send "User-Agent: claude-code/<ver>" — community reports missing UA
//     can draw aggressive 429s.
//   - 429s carry no Retry-After and can persist 30+ minutes. Poll no more
//     than once per 300s per account; back off exponentially, capped 30m.
//   - The credential payload (macOS Keychain item value and
//     .credentials.json alike) is JSON carrying the access token at
//     claudeAiOauth.accessToken.
//
// Tokens never appear in logs, errors, or cache files. Tests assert it.
package anthropic

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// TokenSource yields an OAuth access token for one account.
type TokenSource interface {
	Token(ctx context.Context) (string, error)
}

// ExpirySource additionally reports when the stored access token expires,
// without exposing the token. The daemon's proactive idle refresh consumes
// this; a zero time means the payload carries no expiry.
type ExpirySource interface {
	Expiry(ctx context.Context) (time.Time, error)
}

// accessTokenFromJSON extracts claudeAiOauth.accessToken from a credential
// payload. Error messages deliberately never include any payload content.
func accessTokenFromJSON(data []byte) (string, error) {
	var doc struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return "", errors.New("credential payload: not valid JSON")
	}
	if doc.ClaudeAiOauth.AccessToken == "" {
		return "", errors.New("credential payload: no claudeAiOauth.accessToken")
	}
	return doc.ClaudeAiOauth.AccessToken, nil
}

// expiryFromJSON extracts claudeAiOauth.expiresAt (epoch milliseconds).
// A missing or zero field yields the zero time — not an error, because the
// payload layout may drop the field in a future Claude Code release.
func expiryFromJSON(data []byte) (time.Time, error) {
	var doc struct {
		ClaudeAiOauth struct {
			ExpiresAt int64 `json:"expiresAt"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return time.Time{}, errors.New("credential payload: not valid JSON")
	}
	if doc.ClaudeAiOauth.ExpiresAt == 0 {
		return time.Time{}, nil
	}
	return time.UnixMilli(doc.ClaudeAiOauth.ExpiresAt), nil
}

// Runner executes a subprocess and returns its stdout. Injectable so tests
// and CI never invoke the real /usr/bin/security.
type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)

// ExecRunner runs the command for real.
func ExecRunner(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

// KeychainSource reads a Claude Code credential item from the macOS
// Keychain via /usr/bin/security (subprocess — the item value is JSON).
//
// Interlock (Protocol: a buggy test path must never touch real
// credentials): when LLMPILOT_TEST is set, a Keychain file path is
// mandatory, so tests can only ever operate on a throwaway keychain —
// /usr/bin/security targets the login keychain regardless of $HOME.
type KeychainSource struct {
	Service  string // e.g. "Claude Code-credentials" (see claudecfg)
	Keychain string // optional keychain file; REQUIRED under LLMPILOT_TEST
	Run      Runner // nil = ExecRunner
}

// Token reads and parses the Keychain item.
func (k *KeychainSource) Token(ctx context.Context) (string, error) {
	raw, err := k.raw(ctx)
	if err != nil {
		return "", err
	}
	return accessTokenFromJSON(raw)
}

// Expiry reads the stored token's expiry from the Keychain item.
func (k *KeychainSource) Expiry(ctx context.Context) (time.Time, error) {
	raw, err := k.raw(ctx)
	if err != nil {
		return time.Time{}, err
	}
	return expiryFromJSON(raw)
}

func (k *KeychainSource) raw(ctx context.Context) ([]byte, error) {
	if os.Getenv("LLMPILOT_TEST") != "" {
		if err := AssertThrowawayKeychain(k.Keychain); err != nil {
			return nil, err
		}
	}
	run := k.Run
	if run == nil {
		run = ExecRunner
	}
	args := []string{"find-generic-password", "-s", k.Service, "-w"}
	if k.Keychain != "" {
		args = append(args, k.Keychain)
	}
	out, err := run(ctx, "/usr/bin/security", args...)
	if err != nil {
		// exec errors carry no secret material (the item value only ever
		// arrives on success); the service name is safe to surface.
		return nil, fmt.Errorf("keychain read for service %q: %w", k.Service, err)
	}
	return []byte(strings.TrimSpace(string(out))), nil
}

// AssertThrowawayKeychain enforces the LLMPILOT_TEST interlock by identity,
// not just presence: tests may only ever touch an explicit throwaway
// keychain. The login keychain (by name, wherever it lives, symlinks
// resolved) and anything inside a real Keychains directory are refused.
// Exported so every keychain WRITE path (internal/switcher) enforces the
// same interlock — one definition, no drift.
func AssertThrowawayKeychain(path string) error {
	if path == "" {
		return errors.New("LLMPILOT_TEST is set: refusing the login keychain (interlock; point Keychain at a throwaway keychain file)")
	}
	resolved := path
	if r, err := filepath.EvalSymlinks(path); err == nil {
		resolved = r
	}
	abs, err := filepath.Abs(resolved)
	if err != nil {
		return fmt.Errorf("interlock: cannot resolve keychain path: %w", err)
	}
	if strings.HasPrefix(strings.ToLower(filepath.Base(abs)), "login.keychain") {
		return errors.New("LLMPILOT_TEST is set: refusing the login keychain (interlock)")
	}
	for _, dir := range realKeychainDirs() {
		// Case-folded: the default APFS volume is case-insensitive, so a
		// case-variant spelling reaches the same real directory.
		if strings.HasPrefix(strings.ToLower(abs), strings.ToLower(dir)+string(filepath.Separator)) {
			return fmt.Errorf("LLMPILOT_TEST is set: refusing keychain under %s (interlock; use a throwaway keychain in a temp dir)", dir)
		}
	}
	return nil
}

func realKeychainDirs() []string {
	dirs := []string{"/Library/Keychains", "/System/Library/Keychains"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "Library", "Keychains"))
	}
	return dirs
}

// FileSource reads a credential file (.credentials.json layout).
type FileSource struct {
	Path string
}

// Token reads and parses the credentials file.
func (f *FileSource) Token(_ context.Context) (string, error) {
	data, err := os.ReadFile(f.Path)
	if err != nil {
		return "", err
	}
	return accessTokenFromJSON(data)
}

// Expiry reads the stored token's expiry from the credentials file.
func (f *FileSource) Expiry(_ context.Context) (time.Time, error) {
	data, err := os.ReadFile(f.Path)
	if err != nil {
		return time.Time{}, err
	}
	return expiryFromJSON(data)
}

// FirstSource tries each source in order and yields the first token found.
// On macOS the Keychain is Claude Code's primary store, so it goes first;
// the credentials file may exist yet hold no claudeAiOauth block.
type FirstSource []TokenSource

// Token returns the first source's token, or the last error seen.
func (s FirstSource) Token(ctx context.Context) (string, error) {
	var lastErr error
	for _, src := range s {
		tok, err := src.Token(ctx)
		if err == nil {
			return tok, nil
		}
		lastErr = err
	}
	if lastErr == nil {
		lastErr = errors.New("no token sources configured")
	}
	return "", lastErr
}
