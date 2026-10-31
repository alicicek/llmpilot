package switcher

// Clone guard: never rotate a refresh-token lineage that may be live in two
// places. The refresh token rotates on every successful POST, so refreshing
// a copy kills every other copy of the same grant — the hazard that made
// pinned accounts unswappable in the first place (owner decision 2026-07-16).
//
// The guard acts only on copies llmpilot itself may have made: a move into
// the fleet that could not prove the old folder empty marks the account
// clone-suspect, and that mark stops every rotation until a fresh sign-in.
//
// A folder outside the fleet signed in to the same email is NOT treated as a
// copy (owner 2026-10-31). Signing in there mints its own grant, so rotating
// ours cannot end it; the email-only guard that used to skip such accounts
// was nearly always that false alarm, and it left the account to go stale
// behind a warning nobody needed. In the rare case the folder really holds a
// hand-made copy, one of the two copies asks for a sign-in again — the same
// thing the warning asked of everyone.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// ReasonCloneSuspect / ReasonRecordUnreadable are the STABLE skip-reason
// prefixes the clone guard emits. Callers match on these constants, never on
// a rendered string, and rewrite them into caller-neutral user copy — a
// silently skipped refresh is how a fleet goes quietly cold.
const (
	ReasonCloneSuspect     = "a second copy of this sign-in may still exist"
	ReasonRecordUnreadable = "llmpilot cannot read its own record of this account"
)

// ForeignSignIn is one config dir OUTSIDE the fleet that holds a sign-in.
// Email comes from that dir's .claude.json; no credential is ever read.
type ForeignSignIn struct {
	Dir   string
	Email string
}

// homeConfigDirs is the default enumeration: the machine-global dir plus
// every ~/.claude-* sibling — the layout multi-account setups actually use
// (the same shape internal/detect scans). It is env-BLIND by design: an
// autonomous daemon must never adopt an inherited CLAUDE_CONFIG_DIR as
// truth.
func homeConfigDirs() ([]string, error) {
	var out []string
	if d, err := claudecfg.GlobalDir(); err == nil {
		out = append(out, d.Path())
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return out, err
	}
	matches, _ := filepath.Glob(filepath.Join(home, ".claude-*"))
	for _, m := range matches {
		if fi, err := os.Stat(m); err == nil && fi.IsDir() {
			out = append(out, m)
		}
	}
	return out, nil
}

func (s *Switcher) scanDirs() ([]string, error) {
	if s.ScanDirs != nil {
		return s.ScanDirs()
	}
	return homeConfigDirs()
}

// ForeignSignIns lists config dirs outside the fleet that hold a sign-in.
// Excluded: the fleet's own global dir and every registered account's config
// dir. Dirs a move retired are NOT filtered here (that question costs a
// keychain enumeration), so a folder whose credential is gone may still be
// listed by the email its .claude.json keeps.
func (s *Switcher) ForeignSignIns(ctx context.Context) ([]ForeignSignIn, error) {
	dirs, err := s.scanDirs()
	if err != nil {
		return nil, err
	}
	inFleet := map[string]bool{normDir(s.Dir.Path()): true}
	if s.Registry != nil {
		accs, err := s.Registry.Accounts()
		if err != nil {
			return nil, err
		}
		for _, a := range accs {
			if a.ConfigDir != "" {
				inFleet[normDir(a.ConfigDir)] = true
			}
		}
	}
	var out []ForeignSignIn
	for _, p := range dirs {
		if p == "" || inFleet[normDir(p)] {
			continue
		}
		oa, err := claudecfg.DirAt(p).OAuthAccount()
		if err != nil || oa == nil || oa.EmailAddress == "" {
			continue
		}
		out = append(out, ForeignSignIn{Dir: p, Email: oa.EmailAddress})
	}
	return out, nil
}

// cloneGuard reports why an account's backup must not be rotated right now:
// a partial retirement left a second copy possible. Returns ("", false) when
// rotation is safe. A record that cannot be read stops the rotation; one
// whose contents are damaged is set aside and rebuilt empty (store
// Retirements), and its marks go with it.
func (s *Switcher) cloneGuard(acct store.Account) (string, bool) {
	if s.Registry == nil {
		return "", false
	}
	suspect, err := s.Registry.IsCloneSuspect(acct.ID)
	if err != nil {
		return ReasonRecordUnreadable + " right now — sign in to the account again if this persists", true
	}
	if suspect {
		return ReasonCloneSuspect + " — sign in to the account again to clear it", true
	}
	return "", false
}

func normDir(p string) string {
	return strings.ToLower(filepath.Clean(p))
}

// retirementStillHolds re-verifies, from CURRENT state, that a dir a move
// retired is still empty — the exclusion is only as good as this check.
//
// It asks the direct question ("is there a credential there now?") instead of
// inferring from a config-file mtime: that heuristic rested on an unverified
// belief about when Claude Code rewrites .claude.json, and it froze an
// account for good the first time anyone ran `claude` in that folder
// (re-review). Both reads are ATTRIBUTE-ONLY — `security dump-keychain`
// without -d lists item attributes and never a secret, so no ACL prompt can
// fire — and the file read touches no Keychain at all.
//
// Any doubt (an enumeration error, an unreadable file) answers "no longer
// holds", so the folder stops claiming it was moved.
func (s *Switcher) retirementStillHolds(ctx context.Context, dir claudecfg.Dir) bool {
	return s.dirIsSignedOut(ctx, dir)
}

// CredentialPresent reports whether a config dir still holds a sign-in that
// adopt or move could actually USE.
//
// A dir keeps its `oauthAccount` block in .claude.json after its credential
// is gone (moved into the fleet, cleared, expired out of the Keychain), so
// identity alone says "signed in" long after the sign-in stopped existing —
// which is how the cockpit came to offer Add/Move on folders where both verbs
// can only refuse ("no credential in Keychain service …", "has no stored
// sign-in to move"). This is the direct question those screens owe the user.
//
// Any doubt answers YES: an unreadable file or an enumeration error must not
// hide a real account, and the engine still refuses safely if we guess wrong.
func (s *Switcher) CredentialPresent(ctx context.Context, dir claudecfg.Dir) bool {
	return !s.dirIsSignedOut(ctx, dir)
}

// SignedInDirs answers CredentialPresent for many dirs with ONE keychain
// enumeration. /v1/detect asks about every folder on the machine and is
// polled by both surfaces, so the per-dir form would re-dump the whole
// keychain once per folder on every refresh.
//
// An enumeration failure reports every dir as present, for the same reason
// the single-dir probe does: doubt must never hide an account.
func (s *Switcher) SignedInDirs(ctx context.Context, dirs []claudecfg.Dir) map[string]bool {
	out := make(map[string]bool, len(dirs))
	services, err := s.Keychain.Services(ctx)
	if err != nil {
		for _, d := range dirs {
			out[d.Path()] = true
		}
		return out
	}
	for _, d := range dirs {
		out[d.Path()] = services[d.KeychainService()] || !s.credentialsFileEmpty(d)
	}
	return out
}

// dirIsSignedOut answers "is this dir empty of credentials right now?" —
// confidently true only; see the callers above for how doubt is read.
func (s *Switcher) dirIsSignedOut(ctx context.Context, dir claudecfg.Dir) bool {
	if accounts, err := s.Keychain.List(ctx, dir.KeychainService()); err != nil || len(accounts) > 0 {
		return false
	}
	return s.credentialsFileEmpty(dir)
}

// credentialsFileEmpty reports that the dir's on-disk credential file holds
// no OAuth payload. Doubt (an unreadable or unparseable file) answers false:
// it may well hold one.
func (s *Switcher) credentialsFileEmpty(dir claudecfg.Dir) bool {
	data, err := os.ReadFile(dir.CredentialsFilePath())
	if errors.Is(err, os.ErrNotExist) {
		return true
	}
	if err != nil {
		return false
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return false
	}
	_, hasCred := doc["claudeAiOauth"]
	return !hasCred
}
