// Package detect finds Claude Code config dirs with a logged-in account on
// this machine. It is a leaf package (only claudecfg and store below it) so
// both internal/cli (`llmpilot init`) and internal/daemon (the cockpit's
// GET /v1/detect and POST /v1/adopt) can depend on it without a cycle —
// internal/cli itself depends on internal/daemon (render.go takes a
// *daemon.State), so internal/daemon can never import internal/cli.
package detect

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// Detected is one config dir that holds a logged-in Claude Code account.
type Detected struct {
	Dir     claudecfg.Dir
	Account *claudecfg.OAuthAccount
}

// Dirs finds every config dir on this machine with a logged-in account:
// the default dir (CLAUDE_CONFIG_DIR-aware), ~/.claude, and every ~/.claude-*
// sibling — the layout multi-account setups actually use. Dirs without an
// oauthAccount are skipped silently (never logged in ≠ error).
func Dirs() ([]Detected, error) {
	seen := map[string]bool{}
	var candidates []claudecfg.Dir
	add := func(d claudecfg.Dir) {
		if p := d.Path(); !seen[p] {
			seen[p] = true
			candidates = append(candidates, d)
		}
	}

	if d, err := claudecfg.DefaultDir(); err == nil {
		add(d)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	add(claudecfg.DirAt(filepath.Join(home, ".claude")))
	matches, _ := filepath.Glob(filepath.Join(home, ".claude-*"))
	for _, m := range matches {
		if fi, err := os.Stat(m); err == nil && fi.IsDir() {
			add(claudecfg.DirAt(m))
		}
	}

	var out []Detected
	for _, d := range candidates {
		oa, err := d.OAuthAccount()
		if err != nil || oa == nil || oa.EmailAddress == "" {
			continue
		}
		out = append(out, Detected{Dir: d, Account: oa})
	}
	return out, nil
}

// SuggestLabel picks a label for a detected account: an already-registered
// label wins (init never renames), then a custom dir's suffix ("alt" from
// ~/.claude-alt), else "" so registration defaults to the email local part.
func SuggestLabel(d Detected, existing []store.Account) string {
	for _, a := range existing {
		if a.Email == d.Account.EmailAddress && a.Label != "" {
			return a.Label
		}
	}
	base := filepath.Base(d.Dir.Path())
	if suffix, ok := strings.CutPrefix(base, ".claude-"); ok && suffix != "" {
		return suffix
	}
	return ""
}
