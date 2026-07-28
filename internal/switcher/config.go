package switcher

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// assertSandboxConfigPath is the filesystem half of the LLMPILOT_TEST
// interlock: under test, the switcher refuses to write the real user's
// .claude.json (or anything under the real home's .claude layout) BY
// IDENTITY — symlinks resolved — no matter what a buggy sandbox setup
// passed in.
func assertSandboxConfigPath(path string) error {
	if os.Getenv("LLMPILOT_TEST") == "" {
		return nil
	}
	resolved := path
	if r, err := filepath.EvalSymlinks(path); err == nil {
		resolved = r
	} else if r, err := filepath.EvalSymlinks(filepath.Dir(path)); err == nil {
		resolved = filepath.Join(r, filepath.Base(path))
	}
	abs, err := filepath.Abs(resolved)
	if err != nil {
		return fmt.Errorf("interlock: cannot resolve config path: %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("interlock: cannot resolve home: %w", err)
	}
	real := []string{
		filepath.Join(home, ".claude.json"),
		filepath.Join(home, ".claude"),
	}
	for _, r := range real {
		if samePath(abs, r) || isUnder(abs, r) {
			return fmt.Errorf("LLMPILOT_TEST is set: refusing to write %s (interlock; tests must use a sandbox config dir)", abs)
		}
	}
	return nil
}

// assertSandboxDir is the interlock for keep-warm's PINNED mode, which is the
// only writer of arbitrary per-account config dirs (not just the real home's
// .claude layout that assertSandboxConfigPath covers). Under LLMPILOT_TEST it
// refuses any dir under the real user home — real Claude Code config dirs
// (~/.claude, ~/.claude-*) all live there, while test sandboxes live in temp
// dirs. A buggy test path can thus never rotate a real account's on-disk
// credential file.
func assertSandboxDir(path string) error {
	if os.Getenv("LLMPILOT_TEST") == "" {
		return nil
	}
	resolved := path
	if r, err := filepath.EvalSymlinks(path); err == nil {
		resolved = r
	}
	abs, err := filepath.Abs(resolved)
	if err != nil {
		return fmt.Errorf("interlock: cannot resolve config dir: %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("interlock: cannot resolve home: %w", err)
	}
	if samePath(abs, home) || isUnder(abs, home) {
		return fmt.Errorf("LLMPILOT_TEST is set: refusing to keep-warm a config dir under the real home (%s) — tests must use a sandbox dir", abs)
	}
	return nil
}

// samePath reports path identity robustly on macOS: inode identity when both
// exist (os.SameFile — catches APFS case-insensitivity, hard links, firm
// links), case-folded string equality otherwise (the default APFS volume is
// case-insensitive, so /Users/X/.CLAUDE.json IS ~/.claude.json).
func samePath(a, b string) bool {
	if fa, errA := os.Stat(a); errA == nil {
		if fb, errB := os.Stat(b); errB == nil {
			return os.SameFile(fa, fb)
		}
	}
	return strings.EqualFold(a, b)
}

func isUnder(path, dir string) bool {
	if strings.HasPrefix(strings.ToLower(path), strings.ToLower(dir)+string(filepath.Separator)) {
		return true
	}
	// Inode check on the first existing ancestor catches spellings the
	// string fold misses (e.g. Unicode normalization differences on APFS).
	for p := filepath.Dir(path); ; p = filepath.Dir(p) {
		if samePath(p, dir) {
			return true
		}
		if p == filepath.Dir(p) {
			return false
		}
	}
}

// readConfigDoc loads a .claude.json into a key-preserving map so a splice
// never drops fields this build has never heard of.
func readConfigDoc(path string) (map[string]json.RawMessage, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return doc, nil
}

// spliceOAuthAccount replaces ONLY the oauthAccount key in the config file,
// preserving every other byte of structure, then writes atomically
// (tempfile+rename, 0600 — the same discipline Claude Code itself uses).
func spliceOAuthAccount(path string, oauthAccount json.RawMessage) error {
	if err := assertSandboxConfigPath(path); err != nil {
		return err
	}
	doc, err := readConfigDoc(path)
	if err != nil {
		return err
	}
	if oauthAccount == nil {
		// CAS: a nil splice over a live identity would blank .claude.json's
		// oauthAccount — and the swap's verify (empty==empty) would then pass
		// over the hole. A backup that carries no identity block must not
		// erase one; the identity keeps describing whoever was last known.
		if cur, ok := doc["oauthAccount"]; ok && len(cur) > 0 && string(cur) != "null" {
			return errors.New("splice: refusing to blank a non-empty oauthAccount with an identity-less target")
		}
		delete(doc, "oauthAccount")
	} else {
		doc["oauthAccount"] = oauthAccount
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	// Validate the exact bytes we are about to install parse back — a
	// corrupt .claude.json locks the user out of every claude session.
	var check map[string]json.RawMessage
	if err := json.Unmarshal(data, &check); err != nil {
		return fmt.Errorf("refusing to write unparseable config: %w", err)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".claude.json.tmp-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// oauthAccountRaw reads the raw oauthAccount block (nil if absent).
func oauthAccountRaw(path string) (json.RawMessage, error) {
	doc, err := readConfigDoc(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return doc["oauthAccount"], nil
}
