package switcher

// Filing a finished Claude Code sign-in into the fleet. The daemon runs
// `claude auth login` in a private staging dir (internal/signin); when it
// exits, the fresh grant sits in that dir's Keychain item and .claude.json,
// and nowhere else. ImportSignIn moves it to where it belongs:
//
//   - A WATCHED account (registered with its own config dir): the grant goes
//     into that dir's own slot, where its terminal and llmpilot read it. The
//     account stays watched — a sign-in never turns it switchable.
//   - Claude Code's own slot is EMPTY, or holds the SAME email: install it
//     there (InstallLogin — the swap path, with its backup, journal and
//     verify). Nothing else is signed in to lose, or it is the same account
//     with a fresh grant.
//   - Otherwise: store the grant as a switchable backup and register it,
//     without touching the slot. Adding an account never switches anyone's
//     sessions. This is also the fallback when the install cannot run (no
//     ~/.claude yet on a first run), so a finished sign-in is never thrown
//     away for a reason a later switch can fix.
//
// The staging copy is never left live: the caller forgets the dir
// (ForgetDir) on every path, success or not. A refresh token rotates on
// every use, so two live copies of one grant kill each other; the staging
// copy is never used, so the copy we keep is the only one that can rotate.
//
// Identity is the email, as everywhere else in this package.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// ImportOutcome names where a sign-in landed.
type ImportOutcome string

const (
	// ImportActive: installed as Claude Code's active sign-in.
	ImportActive ImportOutcome = "active"
	// ImportAdded: a new switchable account; Claude Code untouched.
	ImportAdded ImportOutcome = "added"
	// ImportUpdated: an account the fleet already had got a fresh sign-in;
	// Claude Code untouched.
	ImportUpdated ImportOutcome = "updated"
)

// ImportResult reports what ImportSignIn did.
type ImportResult struct {
	Account store.Account
	Outcome ImportOutcome
	// Existed: the fleet already had this account before the sign-in —
	// what a client needs to tell "added" from "the browser signed in to an
	// account you already have".
	Existed bool
	// Note is one more thing the user needs to know ("" when nothing).
	Note string
}

// ErrSignInIncomplete is a staging dir Claude Code exited from without
// leaving a usable sign-in behind.
var ErrSignInIncomplete = errors.New("no sign-in was saved when Claude Code finished — try again")

// ImportSignIn files the sign-in Claude Code left in staging into the fleet.
// staging must be a private dir no one else uses; the caller removes it.
func (s *Switcher) ImportSignIn(ctx context.Context, staging claudecfg.Dir) (ImportResult, error) {
	var res ImportResult
	if s.Dir.Path() == "" {
		return res, errors.New("switcher: no config dir")
	}
	if err := s.refuseFleetDir(staging); err != nil {
		return res, err
	}
	if err := assertSandboxConfigPath(s.Dir.ConfigJSONPath()); err != nil {
		return res, err
	}
	oauthRaw, err := oauthAccountRaw(staging.ConfigJSONPath())
	if err != nil {
		return res, err
	}
	email := oauthEmail(oauthRaw)
	if email == "" {
		return res, ErrSignInIncomplete
	}
	cred, _, err := s.readPinnedFrom(ctx, staging, staging.KeychainService(), false)
	if errors.Is(err, ErrNotFound) {
		return res, ErrSignInIncomplete
	}
	if err != nil {
		return res, err
	}
	if _, err := anthropic.ParseOAuthCred(cred); err != nil {
		return res, fmt.Errorf("%w (%v)", ErrSignInIncomplete, err)
	}

	id := s.matchAccountID(email)
	if id != "" {
		if row := s.lookupAccount(id); row != nil && s.isPinned(*row) {
			return s.signInPinned(ctx, *row, json.RawMessage(cred), oauthRaw, email)
		}
	}
	existed := id != ""
	takes := s.slotTakes(ctx, email)
	if takes && s.slotWritable() {
		acct, err := s.installSignIn(ctx, json.RawMessage(cred), oauthRaw)
		if err == nil {
			return ImportResult{Account: acct, Outcome: ImportActive, Existed: existed}, nil
		}
		if !s.installNeverLanded(ctx, err, cred) {
			return res, err
		}
		// The grant is good; only the install failed. Keep it as a
		// switchable account rather than discard a finished sign-in.
		s.logf("sign-in: not installed into Claude Code (%v) — storing it as switchable instead", err)
	}
	res, err = s.storeSignIn(ctx, json.RawMessage(cred), oauthRaw, email)
	if err != nil {
		return res, err
	}
	// Decided before any install attempt: a failed install registers the
	// row first, which must not make a brand-new account look old.
	res.Existed = existed
	if !existed {
		res.Outcome = ImportAdded
	}
	if takes && !s.slotWritable() {
		res.Note = NoteOpenClaudeCodeFirst
	}
	return res, nil
}

// NoteOpenClaudeCodeFirst is said when Claude Code has not set itself up on
// this Mac yet: the sign-in is kept, but switching to it needs Claude Code's
// own config, which it writes the first time it runs.
const NoteOpenClaudeCodeFirst = "Open Claude Code once on this Mac, then you can switch to this account."

// ErrSlotChanged: Claude Code's slot no longer holds what a sign-in install
// may replace (another account switched in, or a swap is mid-recovery). The
// install wrote nothing.
var ErrSlotChanged = errors.New("the account in Claude Code changed while signing in")

// installNeverLanded decides whether a failed install may fall back to
// storing the sign-in: only with proof the fresh grant is not in Claude
// Code's slot. If it is there — or the slot cannot be read — the swap's
// journal owns the recovery, and reporting "nothing switched" would be
// false.
func (s *Switcher) installNeverLanded(ctx context.Context, installErr error, cred []byte) bool {
	if errors.Is(installErr, ErrSlotChanged) {
		return true
	}
	live, _, err := s.readPinnedFrom(ctx, s.Dir, s.Dir.KeychainService(), false)
	if errors.Is(err, ErrNotFound) {
		return true
	}
	return err == nil && anthropic.CredFingerprint(live) != anthropic.CredFingerprint(cred)
}

// slotWritable reports that an install into the fleet's dir can run at all:
// the dir (lock home) and its .claude.json (identity splice) exist. A Mac
// where Claude Code never ran has neither.
func (s *Switcher) slotWritable() bool {
	if fi, err := os.Stat(s.Dir.Path()); err != nil || !fi.IsDir() {
		return false
	}
	_, err := os.Stat(s.Dir.ConfigJSONPath())
	return err == nil
}

// slotTakes decides whether a fresh sign-in for email belongs in Claude
// Code's own slot: yes when the slot is empty or already this account. An
// unreadable or unidentifiable slot answers no — the sign-in is still kept,
// just not installed over something llmpilot cannot name.
func (s *Switcher) slotTakes(ctx context.Context, email string) bool {
	live, _, lerr := s.readPinnedFrom(ctx, s.Dir, s.Dir.KeychainService(), false)
	if lerr != nil && !errors.Is(lerr, ErrNotFound) {
		return false
	}
	switch liveState(lerr, live) {
	case liveAbsent:
		return true
	case liveIdentified:
		liveRaw, err := oauthAccountRaw(s.Dir.ConfigJSONPath())
		if err != nil {
			return false
		}
		return strings.EqualFold(oauthEmail(liveRaw), email)
	default:
		return false
	}
}

// storeSignIn saves a fresh grant as a switchable account's backup without
// touching Claude Code's slot.
func (s *Switcher) storeSignIn(ctx context.Context, cred, oauthRaw json.RawMessage, email string) (ImportResult, error) {
	var res ImportResult
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return res, err
	}
	// Resolve to the account the fleet already has for this email — a fresh
	// ID would fork both the registry row and the backup key.
	id := s.matchAccountID(email)
	if id == "" {
		id = "acct-" + sanitizeID(strings.ToLower(email))
		// Two emails can sanitize to one ID ("c+1@" and "c_1@"): never take
		// over another account's row.
		if row := s.lookupAccount(id); row != nil && !strings.EqualFold(row.Email, email) {
			releaseLock(bl)
			return res, fmt.Errorf("%w: account %q already belongs to %s", ErrStashConflict, id, row.Email)
		}
	}
	// CAS: never overwrite a backup that belongs to someone else.
	priorCred, priorOAuth, lerr := s.LoadBackup(ctx, id)
	switch {
	case lerr == nil:
		if pe := oauthEmail(priorOAuth); pe != "" && !strings.EqualFold(pe, email) {
			releaseLock(bl)
			return res, fmt.Errorf("%w: account %q already stores a sign-in for %s", ErrStashConflict, id, pe)
		}
		// Keep what else the stored sign-in carried (MCP server sign-ins):
		// they come back with the account when it is switched to.
		if merged, err := anthropic.ReplaceOAuthBlock(priorCred, cred); err == nil {
			cred = merged
		}
	case !errors.Is(lerr, ErrNotFound):
		releaseLock(bl)
		return res, lerr
	}
	prior := s.lookupAccount(id)
	label := labelFromEmail(email)
	if prior != nil && prior.Label != "" {
		label = prior.Label
	}
	acct := store.Account{
		ID:              id,
		Label:           label,
		Email:           email,
		ConfigDir:       s.Dir.Path(),
		KeychainService: s.Dir.KeychainService(),
	}
	if err := s.SaveBackup(ctx, id, cred, oauthRaw); err != nil {
		releaseLock(bl)
		return res, fmt.Errorf("storing the sign-in: %w", err)
	}
	if err := s.registerAccount(acct); err != nil {
		releaseLock(bl)
		return res, fmt.Errorf("adding the account: %w", err)
	}
	releaseLock(bl)
	// A fresh grant is a new lineage: any old copy elsewhere can no longer
	// collide with it. ClearCloneSuspect takes the backups lock itself.
	s.ClearCloneSuspect(ctx, id)
	res = ImportResult{Account: acct, Outcome: ImportAdded}
	if prior != nil {
		res.Outcome, res.Existed = ImportUpdated, true
	}
	s.logf("signed in: %s stored as %s (switchable, not active)", email, id)
	return res, nil
}

// signInPinned puts a fresh grant into a watched account's own config dir —
// the same write keep-warm makes there — so the account stays watched and
// its terminal picks the new sign-in up. The slot is written under that
// dir's Claude Code locks; they are released before the backups lock, as in
// keep-warm, so a live `claude` there never waits on a best-effort save.
func (s *Switcher) signInPinned(ctx context.Context, acct store.Account, cred, oauthRaw json.RawMessage, email string) (ImportResult, error) {
	var res ImportResult
	dir := claudecfg.DirAt(acct.ConfigDir)
	if err := s.refuseFleetDir(dir); err != nil {
		return res, err
	}
	if err := assertSandboxConfigPath(dir.ConfigJSONPath()); err != nil {
		return res, err
	}
	if err := assertSandboxDir(dir.Path()); err != nil {
		return res, err
	}
	release, err := s.lockDirAll(ctx, dir)
	if err != nil {
		return res, err
	}
	written, err := s.writePinnedSignIn(ctx, dir, acct, cred, oauthRaw, email)
	if err != nil {
		release()
		return res, err
	}
	release()

	// The backup mirrors what adopt-as-watched stores; best effort.
	if bl, err := s.acquireBackupsLock(ctx); err != nil {
		s.logf("sign-in: backup for %s not refreshed: %v", acct.ID, err)
	} else {
		if err := s.SaveBackup(ctx, acct.ID, written, oauthRaw); err != nil {
			s.logf("sign-in: backup for %s not refreshed: %v", acct.ID, err)
		}
		releaseLock(bl)
	}
	s.ClearCloneSuspect(ctx, acct.ID)
	s.logf("signed in: %s written into its own folder %s (still watched)", email, dir.Path())
	return ImportResult{Account: acct, Outcome: ImportUpdated, Existed: true}, nil
}

// writePinnedSignIn is signInPinned's slot write; the caller holds dir's
// locks. Nothing is overwritten that cannot be shown to be this account's:
// the folder must name this email (or nobody), and a credential in a folder
// that names nobody must be this account's own lineage — otherwise refuse,
// the same "unknown is never overwritten on a guess" rule swapTo keeps.
// Only the Claude sign-in is replaced; anything else the item holds stays.
// Returns the payload it wrote.
func (s *Switcher) writePinnedSignIn(ctx context.Context, dir claudecfg.Dir, acct store.Account, cred, oauthRaw json.RawMessage, email string) (json.RawMessage, error) {
	curRaw, err := oauthAccountRaw(dir.ConfigJSONPath())
	if err != nil {
		return nil, err
	}
	curEmail := oauthEmail(curRaw)
	if curEmail != "" && !strings.EqualFold(curEmail, email) {
		return nil, fmt.Errorf("%w: %s is signed in as %s now, not %s — sign in to %s there instead", ErrMoveRefused, dir.Path(), curEmail, email, email)
	}
	service := dir.KeychainService()
	live, _, lerr := s.readPinnedFrom(ctx, dir, service, false)
	if lerr != nil && !errors.Is(lerr, ErrNotFound) {
		return nil, fmt.Errorf("llmpilot could not read the sign-in in %s, so it cannot prove replacing it is safe — nothing was changed: %w", dir.Path(), lerr)
	}
	switch liveState(lerr, live) {
	case liveUnknown:
		return nil, fmt.Errorf("%w: llmpilot can't tell what is stored in %s — sign in there with Claude Code instead", ErrMoveRefused, dir.Path())
	case liveIdentified:
		if curEmail == "" && s.resolveByFingerprint(ctx, live) != acct.ID {
			return nil, fmt.Errorf("%w: %s holds a sign-in llmpilot can't identify as %s — sign in there with Claude Code instead", ErrMoveRefused, dir.Path(), email)
		}
	}
	attrs, err := s.Keychain.List(ctx, service)
	if err != nil {
		return nil, err
	}
	if len(attrs) == 0 {
		attrs = []string{s.account()}
	}
	// Every item in the dir's service gets the fresh grant, so no read can
	// find the dead one — each keeping whatever else it held.
	var written json.RawMessage
	for _, a := range attrs {
		blob := json.RawMessage(cred)
		if cur, err := s.Keychain.GetAccount(ctx, service, a); err == nil {
			merged, merr := anthropic.ReplaceOAuthBlock(cur, cred)
			if merr != nil {
				return nil, fmt.Errorf("%w: llmpilot can't tell what is stored in %s — sign in there with Claude Code instead", ErrMoveRefused, dir.Path())
			}
			blob = merged
		} else if !errors.Is(err, ErrNotFound) {
			return nil, err
		}
		if err := s.Keychain.Set(ctx, service, a, blob); err != nil {
			return nil, fmt.Errorf("writing the sign-in into %s: %w", dir.Path(), err)
		}
		if written == nil {
			written = blob
		}
	}
	if _, _, err := s.spliceCredentialsFile(dir, cred); err != nil {
		s.logf("sign-in: credentials file in %s not updated: %v", dir.Path(), err)
	}
	if _, err := os.Stat(dir.ConfigJSONPath()); err == nil {
		if err := spliceOAuthAccount(dir.ConfigJSONPath(), oauthRaw); err != nil {
			s.logf("sign-in: identity in %s not refreshed: %v", dir.Path(), err)
		}
	}
	return written, nil
}

// ForgetDir deletes every Keychain item Claude Code keeps for dir — the
// staging sign-in's copy. It never touches the fleet's own dir. The caller
// removes the files.
func (s *Switcher) ForgetDir(ctx context.Context, dir claudecfg.Dir) error {
	if err := s.refuseFleetDir(dir); err != nil {
		return err
	}
	if err := assertSandboxDir(dir.Path()); err != nil {
		return err
	}
	service := dir.KeychainService()
	accounts, err := s.Keychain.List(ctx, service)
	if err != nil {
		return err
	}
	if len(accounts) == 0 {
		accounts = []string{s.account()}
	}
	for _, a := range accounts {
		if err := s.Keychain.Delete(ctx, service, a); err != nil {
			return err
		}
	}
	if left, err := s.Keychain.List(ctx, service); err != nil {
		return err
	} else if len(left) > 0 {
		return fmt.Errorf("the sign-in copy in %s could not be removed from the Keychain", dir.Path())
	}
	return nil
}

// refuseFleetDir stops a staging operation from ever aiming at the fleet's
// own dir — by path, by inode, or by Keychain service.
func (s *Switcher) refuseFleetDir(dir claudecfg.Dir) error {
	if dir.Path() == "" || samePath(dir.Path(), s.Dir.Path()) || normDir(dir.Path()) == normDir(s.Dir.Path()) ||
		dir.KeychainService() == s.Dir.KeychainService() {
		return fmt.Errorf("refusing to treat %s as a sign-in staging folder: it is Claude Code's own", dir.Path())
	}
	return nil
}
