package switcher

// Clone guard: never rotate a refresh-token lineage that may be live in two
// places. The refresh token rotates on every successful POST, so refreshing
// a copy kills every other copy of the same grant — the hazard that made
// pinned accounts unswappable in the first place (owner decision 2026-07-16).
//
// The guard never reads a SECRET outside the fleet. It decides from
// `.claude.json`'s oauthAccount email; the one extra question it asks about a
// dir a move retired ("does it hold a credential again?") is answered by
// `security dump-keychain` WITHOUT -d — item attributes only, so no ACL
// prompt can fire — plus a key-presence check on that dir's
// `.credentials.json`. A fingerprint-accurate guard would have to read
// foreign secrets, and an authorization dialog at 02:00 is a product
// failure, so it stays attribute-level.
//
// Accepted false positive, deliberately: a genuinely SEPARATE grant for the
// same email signed into another dir looks identical to a clone here, so it
// is skipped too. That is the conservative direction (a skipped refresh
// costs freshness; a wrong refresh costs the account), and it is precisely
// the same-subscription collision the doctor will surface later.

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

// ReasonLineageElsewhere / ReasonCloneSuspect are the STABLE skip-reason
// prefixes the clone guard emits. Callers match on these constants, never on
// a rendered string, and rewrite them into caller-neutral user copy — a
// silently skipped refresh is how a fleet goes quietly cold.
const (
	ReasonLineageElsewhere = "this sign-in is also live in"
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
// dir. Dirs a move retired are NOT filtered here — that question costs a
// keychain enumeration, so lineageLiveElsewhere asks it only for a dir whose
// email actually matches the account being checked. A caller that wants
// "dirs outside the fleet, minus proven-empty ones" must pair this with
// retiredAndStillEmpty.
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

// lineageLiveElsewhere reports why an account's backup must not be rotated
// right now: either a partial retirement left a second copy possible
// (clone-suspect), or its email is signed into a config dir outside the
// fleet. Returns ("", false) when rotation is safe. The per-account mark
// fails CLOSED; the machine-wide dir scan fails open (see inline).
func (s *Switcher) lineageLiveElsewhere(ctx context.Context, acct store.Account) (string, bool) {
	if s.Registry != nil {
		// The clone-suspect mark fails CLOSED (adversarial review P1): it is a
		// per-account fact whose whole purpose is to stop a rotation, so an
		// unreadable record must not silently disarm it. (The dir SCAN below
		// still fails open — freezing the whole fleet on an unrelated
		// filesystem error would be worse than the risk it guards.)
		suspect, err := s.Registry.IsCloneSuspect(acct.ID)
		if err != nil {
			return ReasonRecordUnreadable + " right now — sign in to the account again if this persists", true
		}
		if suspect {
			return ReasonCloneSuspect + " — sign in to the account again to clear it", true
		}
	}
	if acct.Email == "" {
		return "", false
	}
	foreign, err := s.ForeignSignIns(ctx)
	if err != nil {
		s.logf("clone guard: config dir scan failed (%v) — proceeding", err)
		return "", false
	}
	for _, f := range foreign {
		if !strings.EqualFold(f.Email, acct.Email) {
			continue
		}
		// This dir carries the account's email — the only case worth paying
		// for a retirement re-check. A dir a move emptied keeps its identity
		// block forever (llmpilot never blanks a foreign dir's), so without
		// this the account could never be refreshed again.
		if s.retiredAndStillEmpty(ctx, f.Dir) {
			continue
		}
		return ReasonLineageElsewhere + " " + f.Dir, true
	}
	return "", false
}

// retiredAndStillEmpty reports whether a move retired this dir AND it still
// holds no credential. A retirement is a fact about a MOMENT — the product
// itself tells the user a terminal using that folder must sign in again — so
// the exclusion is re-verified from current state every time, never trusted
// from the record alone.
func (s *Switcher) retiredAndStillEmpty(ctx context.Context, dir string) bool {
	if s.Registry == nil {
		return false
	}
	rec, err := s.Registry.Retirements()
	if err != nil && !errors.Is(err, store.ErrRecordRebuilt) {
		return false // unknown never means "safe to rotate"
	}
	for _, d := range rec.Dirs {
		if d.Complete && normDir(d.ConfigDir) == normDir(dir) {
			return s.retirementStillHolds(ctx, claudecfg.DirAt(dir))
		}
	}
	return false
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
// holds": the dir is then scanned like any other, and if it carries this
// account's email the rotation is skipped. Unknown must never mean "safe to
// rotate".
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
