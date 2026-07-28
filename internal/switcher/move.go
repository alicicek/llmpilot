package switcher

// Move into the fleet: take a Claude sign-in that lives in ITS OWN config
// dir (a pinned/watched account, or a dir llmpilot has never registered) and
// make it a swappable fleet account — then RETIRE the source copy, so
// exactly one live copy of the grant survives.
//
// Why the retirement is not optional: a refresh token rotates on every
// successful POST, so two live copies of one grant kill each other on the
// next rotation. That is precisely why Swap refuses pinned targets (owner
// decision 2026-07-16). Registering a second copy without retiring the first
// would manufacture the hazard this codebase spent two waves avoiding.
//
// Ordering is AdoptStash's, for the same reason (classify.go): backup first,
// register second, retire LAST. A crash anywhere leaves both copies readable
// — never neither. Everything runs under the SOURCE dir's Claude Code locks
// plus llmpilot's backups lock, and no network is touched anywhere on this
// path.

import (
	"bytes"
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

// MoveOutcome names what the migration did to the source copy — every
// partial state has a name, and none of them is reported as a clean success.
type MoveOutcome string

const (
	// MoveComplete: the account is registered and the source copy is
	// provably gone. Exactly one live copy exists.
	MoveComplete MoveOutcome = "complete"
	// MoveCloneSuspect: the account is registered but a readable copy
	// survived in the source dir. The registration is KEPT (the credential is
	// safe in our backups either way), the account is marked clone-suspect,
	// and the keep-warm guard refuses to rotate it until a human resolves it.
	MoveCloneSuspect MoveOutcome = "clone_suspect"
)

// ErrMoveRefused marks a migration the engine declined for a reason the USER
// can act on (the fleet's own folder, no sign-in there, the identity changed
// under us, a second live sign-in for the same account). The daemon maps it
// to a 409, never a 500 — these are decisions, not faults.
var ErrMoveRefused = errors.New("move refused")

// MoveResult reports the migration. Note is the honest one-line explanation
// for a non-complete outcome ("" when complete).
type MoveResult struct {
	Account store.Account
	Outcome MoveOutcome
	Note    string
}

// MoveIntoFleet migrates the sign-in in dir into llmpilot's swappable fleet
// and retires the source copy. It is the only destructive verb in the adopt
// family — plain adopt stays additive.
func (s *Switcher) MoveIntoFleet(ctx context.Context, dir claudecfg.Dir, label string) (MoveResult, error) {
	var res MoveResult
	if s.Registry == nil {
		return res, errors.New("move: no account registry")
	}
	if s.Dir.Path() == "" {
		return res, errors.New("move: no fleet config dir")
	}
	// Moving the fleet's own dir is meaningless (its sign-in IS the live
	// slot) and would delete the ACTIVE credential. Refuse on both path and
	// Keychain-service identity — two spellings of one dir must not slip
	// through a string compare.
	// samePath is inode identity (os.SameFile), not a string compare: a
	// symlinked sibling like ~/.claude-alt -> ~/.claude passes detect's
	// IsDir check and would otherwise look foreign — and "retiring" it would
	// strip the ACTIVE dir's credentials file through the link.
	if samePath(dir.Path(), s.Dir.Path()) || normDir(dir.Path()) == normDir(s.Dir.Path()) ||
		dir.KeychainService() == s.Dir.KeychainService() {
		return res, fmt.Errorf("%w: %s is llmpilot's own account folder — accounts signed in there are already switchable", ErrMoveRefused, dir.Path())
	}
	// Interlocks BEFORE any lock or write: under LLMPILOT_TEST this path may
	// only ever touch a sandbox dir. This path DELETES credentials, so a
	// sandbox escape would destroy a real sign-in.
	if err := assertSandboxConfigPath(dir.ConfigJSONPath()); err != nil {
		return res, err
	}
	if err := assertSandboxDir(dir.Path()); err != nil {
		return res, err
	}

	// Fail fast before taking anyone's locks.
	oa, err := dir.OAuthAccount()
	if err != nil {
		return res, err
	}
	if oa == nil || oa.EmailAddress == "" {
		return res, fmt.Errorf("%w: no Claude account is signed in at %s", ErrMoveRefused, dir.Path())
	}

	// Source dir locks first, then the backups lock — the fixed global order
	// every writer in this package uses, so two movers (or a mover and a
	// keep-warm) can never deadlock.
	release, err := s.lockDirAll(ctx, dir)
	if err != nil {
		return res, err
	}
	defer release()
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return res, err
	}
	defer releaseLock(bl)

	// Re-read identity UNDER the locks: a login could have landed between the
	// fast-fail read and here, and moving a credential while believing it
	// belongs to someone else is the misattribution class that kills accounts.
	oauthRaw, err := oauthAccountRaw(dir.ConfigJSONPath())
	if err != nil {
		return res, err
	}
	email := oauthEmail(oauthRaw)
	if email == "" {
		return res, fmt.Errorf("%w: no Claude account is signed in at %s", ErrMoveRefused, dir.Path())
	}
	if !strings.EqualFold(email, oa.EmailAddress) {
		return res, fmt.Errorf("%w: the account signed in at %s changed while starting the move — try again", ErrMoveRefused, dir.Path())
	}

	service := dir.KeychainService()
	cred, _, err := s.readPinnedFrom(ctx, dir, service, false)
	if err == nil {
		// A credentials FILE with no claudeAiOauth block is not a sign-in —
		// it is exactly what our own retirement leaves behind. Treat it like
		// "nothing here" rather than a corrupt payload, so the natural retry
		// after a partial retirement reaches the repair below.
		if _, perr := anthropic.ParseOAuthCred(cred); perr != nil {
			err = fmt.Errorf("%s: %w", dir.Path(), ErrNotFound)
		}
	}
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			// A RETRY after a partial retirement lands here: the leftover copy
			// the user removed by hand is gone, which is the very proof the
			// first attempt could not get. Upgrade the record to complete —
			// that clears the account's clone-suspect mark (retire.go derives
			// it), so the remedy the note prescribes actually works.
			if repaired, rerr := s.repairRetirement(dir, email); rerr != nil {
				return res, rerr
			} else if repaired {
				acct := s.accountForEmail(email)
				if acct.ID == "" {
					// Nothing was moved and nothing is switchable — do not
					// report a completed migration for an account that does
					// not exist (re-review: it rendered "Moved  into…").
					return res, fmt.Errorf("%w: %s no longer holds a sign-in — its earlier move is now recorded as finished", ErrMoveRefused, dir.Path())
				}
				return MoveResult{Account: acct, Outcome: MoveComplete}, nil
			}
			return res, fmt.Errorf("%w: %s has no stored sign-in to move — sign in there again first", ErrMoveRefused, dir.Path())
		}
		return res, err
	}
	// The fleet's LIVE identity, not just its dir (adversarial review P0):
	// registering this grant under an ID whose live copy in the global slot
	// is a DIFFERENT grant for the same email destroys one of them. The
	// daemon freshens the ACTIVE account's backup from the global slot after
	// every poll, so it would overwrite the grant we just moved — and the
	// source copy is gone by then. Refuse before anything is deleted.
	// Same email + SAME grant is the benign duplicate case: the source is a
	// clone of the live credential, and retiring it is exactly right.
	// Why this read is sound without the GLOBAL dir's own CC locks: we hold
	// the backups lock, and swapTo holds that same lock across its ENTIRE
	// mutation (install → splice → verify), so no swap can be mid-flight
	// here. A concurrent Claude Code refresh can still rotate the live grant
	// under us — that changes the fingerprint but never the email, so it can
	// only turn the benign duplicate case into a (safe, retryable) refusal,
	// never the hazardous case into a pass.
	// FAIL CLOSED (re-review): this is the one check between the user and a
	// destroyed grant, so "we could not look" must abort, never proceed.
	// Read the live slot the same way the rest of the package does — Keychain
	// first, then the credentials file — because a file-mode slot read through
	// the Keychain alone looks empty, which would skip this check entirely.
	//
	// The slot has THREE states and they must not be collapsed (re-review):
	//   ABSENT     — nothing usable there; no identity to clash with, proceed.
	//   UNKNOWN    — something is there we cannot read; refuse, saying so.
	//   IDENTIFIED — a real credential; compare identity, then lineage.
	// Folding UNKNOWN into IDENTIFIED made every unreadable slot fingerprint
	// as a mismatch and accuse the user of a second sign-in that does not
	// exist; folding it into ABSENT would delete on a guess.
	live, _, lerr := s.readPinnedFrom(ctx, s.Dir, s.Dir.KeychainService(), false)
	if lerr != nil && !errors.Is(lerr, ErrNotFound) {
		return res, fmt.Errorf("llmpilot could not read the sign-in currently in %s, so it cannot prove this move is safe — nothing was changed; try again: %w", s.Dir.Path(), lerr)
	}
	switch liveState(lerr, live) {
	case liveUnknown:
		return res, fmt.Errorf("%w: llmpilot could not make sense of what is stored in %s, so it cannot prove this move is safe — nothing was changed; sign in to %s from llmpilot, then try again",
			ErrMoveRefused, s.Dir.Path(), s.Dir.Path())
	case liveIdentified:
		liveRaw, rerr := oauthAccountRaw(s.Dir.ConfigJSONPath())
		if rerr != nil {
			return res, fmt.Errorf("llmpilot could not read who is signed in to %s, so it cannot prove this move is safe — nothing was changed; try again: %w", s.Dir.Path(), rerr)
		}
		liveEmail := oauthEmail(liveRaw)
		if liveEmail == "" {
			// A credential is live there but nothing says whose it is. "The
			// file parsed and named nobody" is the same epistemic state as
			// "we could not look" — refuse rather than delete on a guess.
			return res, fmt.Errorf("%w: %s holds a sign-in that llmpilot cannot identify, so it cannot prove this move is safe — sign in to %s from llmpilot first", ErrMoveRefused, s.Dir.Path(), s.Dir.Path())
		}
		if strings.EqualFold(liveEmail, email) &&
			anthropic.CredFingerprint(live) != anthropic.CredFingerprint(cred) {
			return res, fmt.Errorf("%w: %s is signed in both here and in %s, as two separate sign-ins — llmpilot can keep only one, so sign out of one of them (or sign in to %s again from llmpilot) instead of moving this copy",
				ErrMoveRefused, email, s.Dir.Path(), email)
		}
	}

	// Resolve to the ALREADY-registered account when we know this email — a
	// fresh "acct-"+sanitize(email) ID would fork both the registry row and
	// the backup key.
	id := s.matchAccountID(email)
	if id == "" {
		id = "acct-" + sanitizeID(strings.ToLower(email))
	}

	// CAS: never overwrite a backup that belongs to a DIFFERENT identity —
	// destroying another account's only copy is the P0 class AdoptStash
	// closed. Identity OUTRANKS fingerprint here for the same reason
	// classify.go states: the refresh token rotates, so a same-identity
	// backup with a different fingerprint is simply our older snapshot of
	// this very account (the adopt-as-watched → move flow always looks like
	// that), and the live copy we just read under the dir's locks is the
	// newer truth.
	priorCred, priorOAuth, loadErr := s.LoadBackup(ctx, id)
	hadBackup := loadErr == nil
	switch {
	case loadErr != nil && !errors.Is(loadErr, ErrNotFound):
		return res, loadErr
	case hadBackup:
		priorEmail := oauthEmail(priorOAuth)
		sameLineage := anthropic.CredFingerprint(priorCred) == anthropic.CredFingerprint(cred)
		if priorEmail != "" && !strings.EqualFold(priorEmail, email) {
			return res, fmt.Errorf("%w: account %q already stores a sign-in for %s — resolve that first so this move cannot overwrite it",
				ErrStashConflict, id, priorEmail)
		}
		if priorEmail == "" && !sameLineage {
			return res, fmt.Errorf("%w: account %q already stores a sign-in this move cannot prove it owns — sign in to the account again instead",
				ErrStashConflict, id)
		}
		if !sameLineage {
			// Same identity, DIFFERENT grant: usually our own older snapshot
			// of this account (adopt-as-watched, then the dir rotated), but it
			// can also be a genuinely separate live grant for the same email —
			// and that copy may be the only one llmpilot holds. Preserve it in
			// the append-only stash before the overwrite, exactly as the swap
			// path preserves an unattributable credential. A failed stash
			// ABORTS: losing a grant silently is the class this abort exists to
			// prevent.
			if err := s.stashForeign(ctx, priorCred, priorOAuth); err != nil {
				return res, fmt.Errorf("the stored sign-in for %q could not be preserved before this move — aborting before any overwrite: %w", id, err)
			}
		}
	}

	// Snapshot what a rollback must restore. Nothing has been deleted yet, so
	// every failure until the retirement phase unwinds completely.
	priorRaw, priorRawErr := s.Keychain.GetAccount(ctx, BackupService, id)
	priorAccount := s.lookupAccount(id)
	rollback := func(cause error) (MoveResult, error) {
		if priorRawErr == nil {
			if err := s.Keychain.Set(ctx, BackupService, id, priorRaw); err != nil {
				return res, fmt.Errorf("%w; restoring the previous stored sign-in also failed: %v", cause, err)
			}
		} else if errors.Is(priorRawErr, ErrNotFound) {
			if err := s.Keychain.Delete(ctx, BackupService, id); err != nil {
				return res, fmt.Errorf("%w; removing the half-written stored sign-in also failed: %v", cause, err)
			}
		}
		if err := s.restoreAccountRow(id, priorAccount); err != nil {
			return res, fmt.Errorf("%w; restoring the account list also failed: %v", cause, err)
		}
		s.logf("move rolled back: %s untouched, no registration left behind", dir.Path())
		return res, fmt.Errorf("%w (nothing was deleted — the sign-in is still in %s)", cause, dir.Path())
	}

	if label == "" {
		if priorAccount != nil && priorAccount.Label != "" {
			label = priorAccount.Label
		} else {
			label = labelFromEmail(email)
		}
	}
	acct := store.Account{
		ID:              id,
		Label:           label,
		Email:           email,
		ConfigDir:       s.Dir.Path(),
		KeychainService: s.Dir.KeychainService(),
	}

	// 1. Backup first — the copy that must survive everything below.
	if err := s.SaveBackup(ctx, id, json.RawMessage(cred), oauthRaw); err != nil {
		return rollback(fmt.Errorf("storing the sign-in in llmpilot's backups: %w", err))
	}
	// 2. Register second — global-swappable, so Swap accepts it.
	if err := s.registerAccount(acct); err != nil {
		return rollback(fmt.Errorf("registering the account: %w", err))
	}
	s.logf("move: %s stored as %s and registered global-swappable", orUnknown(email), id)

	// 3. Retire last. From here the credential is durable in our backups, so
	// a failure never loses the sign-in — it can only leave a SECOND copy,
	// which is named (clone-suspect), recorded, and guarded against.
	res.Account = acct
	res.Outcome, res.Note = s.retireSource(ctx, dir, service)
	if err := s.Registry.RecordRetirement(store.RetiredDir{
		ConfigDir: dir.Path(),
		Email:     email,
		AccountID: id,
		Complete:  res.Outcome == MoveComplete,
	}); err != nil {
		// The record is how /v1/detect tells the truth about this dir and how
		// the clone guard learns the mark. Failing to write it while a copy may
		// survive is exactly the state that must not be silent.
		return res, fmt.Errorf("the sign-in moved into the fleet but recording it failed: %w", err)
	}
	return res, nil
}

// retireSource deletes the source dir's copy of the sign-in — its Keychain
// item(s) and the claudeAiOauth block in its .credentials.json — then
// VERIFIES nothing readable is left. The outcome is decided by what it can
// still read, never by whether the deletes returned nil (a delete of an item
// under an unexpected account attribute reports success and changes
// nothing).
func (s *Switcher) retireSource(ctx context.Context, dir claudecfg.Dir, service string) (MoveOutcome, string) {
	var problems []string
	// Delete every item in the dir's own service. The service name is derived
	// from the dir path (sha256), so it belongs to that dir alone; enumerating
	// is attribute-only (no secret read, no unlock prompt) and catches items
	// written under a different account attribute than ours.
	accounts, err := s.Keychain.List(ctx, service)
	if err != nil {
		s.logf("move: keychain enumeration failed (%v) — deleting the default account attribute only", err)
		accounts = nil
	}
	if len(accounts) == 0 {
		accounts = []string{s.account()}
	}
	for _, a := range accounts {
		if err := s.Keychain.Delete(ctx, service, a); err != nil {
			problems = append(problems, "the Keychain item could not be removed")
			s.logf("move: keychain delete failed for %s/%s: %v", service, a, err)
			break
		}
	}
	if _, _, err := s.removeCredentialsFileBlock(dir); err != nil {
		problems = append(problems, "the credentials file could not be updated")
		s.logf("move: credentials file removal failed for %s: %v", dir.Path(), err)
	}
	// An UNPARSEABLE credentials file is left untouched by design (it may hold
	// material we must not destroy) — and it means we cannot prove the source
	// is empty. "We could not tell" is not "there is nothing there"
	// (adversarial review P2), so it takes the clone-suspect path.
	if unreadable, err := credentialsFileUnparseable(dir); err != nil || unreadable {
		s.logf("move: credentials file at %s could not be parsed — retirement cannot be proven", dir.Path())
		return MoveCloneSuspect, "llmpilot could not read the credentials file in " + dir.Path() +
			", so it cannot confirm the sign-in was removed — it will not refresh this account until you sign in to it again."
	}

	// Verify: is a usable sign-in still readable there?
	leftover, _, err := s.readPinnedFrom(ctx, dir, service, false)
	switch {
	case errors.Is(err, ErrNotFound):
		s.logf("move: source retired — no readable sign-in remains in %s", dir.Path())
		return MoveComplete, ""
	case err != nil:
		return MoveCloneSuspect, "llmpilot could not confirm the sign-in was removed from " + dir.Path() +
			" — it will not refresh this account until you sign in to the account again."
	}
	if _, perr := anthropic.ParseOAuthCred(leftover); perr != nil {
		// Whatever is left is not a usable Claude sign-in (e.g. a credentials
		// file holding only MCP tokens). Nothing to clone.
		s.logf("move: source retired — remaining material in %s is not a sign-in", dir.Path())
		return MoveComplete, ""
	}
	note := "The sign-in is in the fleet, but a copy is still readable in " + dir.Path() +
		" — llmpilot will not refresh this account until you sign in to it again."
	if len(problems) > 0 {
		note = "The sign-in is in the fleet, but " + strings.Join(problems, " and ") + " in " + dir.Path() +
			" — llmpilot will not refresh this account until you sign in to it again."
	}
	return MoveCloneSuspect, note
}

// credentialsFileUnparseable reports whether dir's .credentials.json exists
// but does not parse as a JSON object — the one state in which the
// retirement cannot be proven either way.
func credentialsFileUnparseable(dir claudecfg.Dir) (bool, error) {
	data, err := os.ReadFile(dir.CredentialsFilePath())
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return true, nil // unreadable is not provably empty either
	}
	var doc map[string]json.RawMessage
	return json.Unmarshal(data, &doc) != nil, nil
}

// lookupAccount returns a copy of the registered account with this ID, or
// nil. Used to snapshot the row a rollback must put back.
func (s *Switcher) lookupAccount(id string) *store.Account {
	if s.Registry == nil {
		return nil
	}
	accs, err := s.Registry.Accounts()
	if err != nil {
		return nil
	}
	for _, a := range accs {
		if a.ID == id {
			cp := a
			return &cp
		}
	}
	return nil
}

// restoreAccountRow puts the registry back the way it was: the prior row, or
// no row at all when this move was the one that created it.
func (s *Switcher) restoreAccountRow(id string, prior *store.Account) error {
	if s.Registry == nil {
		return nil
	}
	if prior != nil {
		return s.registerAccount(*prior)
	}
	accs, err := s.Registry.Accounts()
	if err != nil {
		return err
	}
	kept := make([]store.Account, 0, len(accs))
	for _, a := range accs {
		if a.ID != id {
			kept = append(kept, a)
		}
	}
	if len(kept) == len(accs) {
		return nil
	}
	return s.Registry.SaveAccounts(kept)
}

// repairRetirement closes out an earlier PARTIAL retirement of dir once the
// leftover copy is provably gone (the source now holds no credential at
// all). It is the path a user's natural retry takes after doing what the
// clone-suspect note asked, and recording the retirement complete is what
// clears the account's clone-suspect mark — without it the mark, and the
// rotation freeze it arms, would be permanent (adversarial review P1).
func (s *Switcher) repairRetirement(dir claudecfg.Dir, email string) (bool, error) {
	if s.Registry == nil {
		return false, nil
	}
	rec, err := s.Registry.Retirements()
	if err != nil {
		return false, err
	}
	for _, d := range rec.Dirs {
		if d.Complete || !strings.EqualFold(d.ConfigDir, dir.Path()) {
			continue
		}
		if d.Email != "" && !strings.EqualFold(d.Email, email) {
			continue
		}
		d.Complete = true
		if err := s.Registry.RecordRetirement(d); err != nil {
			return false, err
		}
		s.logf("move: earlier partial retirement of %s is now provably complete — clone-suspect cleared", dir.Path())
		return true, nil
	}
	return false, nil
}

// accountForEmail returns the registered account for an email (zero value if
// none) — used to report the account a repaired retirement belongs to.
func (s *Switcher) accountForEmail(email string) store.Account {
	if id := s.matchAccountID(email); id != "" {
		if a := s.lookupAccount(id); a != nil {
			return *a
		}
	}
	return store.Account{}
}

// MovedDirs reports the config dirs a move retired that STILL hold no
// sign-in. It is what /v1/detect's `moved` flag must be derived from: a
// completed retirement is a fact about a moment, and a folder someone signed
// back into must stop claiming it was moved — otherwise the cockpit says
// "already moved into the fleet" and offers no way to resolve the new
// sign-in, while the clone guard has quietly paused that account's
// refreshes. Same attribute-only checks as the guard.
func (s *Switcher) MovedDirs(ctx context.Context) (map[string]bool, error) {
	out := map[string]bool{}
	if s.Registry == nil {
		return out, nil
	}
	rec, err := s.Registry.Retirements()
	if err != nil && !errors.Is(err, store.ErrRecordRebuilt) {
		return out, err
	}
	for _, d := range rec.Dirs {
		if d.Complete && s.retirementStillHolds(ctx, claudecfg.DirAt(d.ConfigDir)) {
			out[d.ConfigDir] = true
		}
	}
	return out, nil
}

// ClearCloneSuspect retires llmpilot's clone bookkeeping for an account
// after a genuinely FRESH sign-in. A new sign-in mints a NEW refresh-token
// lineage, so any copy left behind in another dir is a different lineage
// now: rotating ours can no longer kill it, and the records that described
// that risk are moot. They are DELETED rather than marked complete — this
// path never proved any dir empty, and a record that lies is worse than no
// record (re-review). Call it only from a path that mints a credential.
func (s *Switcher) ClearCloneSuspect(ctx context.Context, accountID string) {
	if s.Registry == nil || accountID == "" {
		return
	}
	// The record arms the clone guard, so serialize with the mover that
	// writes it (MoveIntoFleet holds this lock across its whole span).
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		s.logf("clearing the clone-suspect mark for %s: %v", accountID, err)
		return
	}
	defer releaseLock(bl)
	rec, err := s.Registry.Retirements()
	if err != nil {
		s.logf("clearing the clone-suspect mark for %s: %v", accountID, err)
		return
	}
	kept := rec.Dirs[:0]
	dropped := 0
	for _, d := range rec.Dirs {
		// Drop only the UNPROVEN records — those are the ones describing a
		// possible duplicate, which a fresh lineage makes moot. A proven-empty
		// record must stay: it is the only thing excluding that dir from the
		// clone scan, and the dir keeps its identity block forever, so
		// deleting it would freeze this account for good (re-review).
		if d.AccountID == accountID && !d.Complete {
			dropped++
			continue
		}
		kept = append(kept, d)
	}
	rec.Dirs = kept
	suspects := rec.CloneSuspect[:0]
	for _, id := range rec.CloneSuspect {
		if id != accountID {
			suspects = append(suspects, id)
		}
	}
	if dropped == 0 && len(suspects) == len(rec.CloneSuspect) {
		return
	}
	rec.CloneSuspect = suspects
	if err := s.Registry.SaveRetirements(rec); err != nil {
		s.logf("clearing the clone-suspect mark for %s failed: %v", accountID, err)
		return
	}
	s.logf("fresh sign-in for %s — %d retirement record(s) retired, clone-suspect cleared", accountID, dropped)
}

// liveSlotState names what the fleet's credential slot holds. UNKNOWN is a
// first-class answer here: a migration deletes a sign-in, so "we could not
// tell" must never be rounded to either "nothing there" (delete on a guess)
// or "someone else's grant" (accuse the user of a sign-in that isn't there).
type liveSlotState int

const (
	liveAbsent liveSlotState = iota
	liveUnknown
	liveIdentified
)

// liveState classifies a read of the fleet's slot. A well-formed document
// with no usable claudeAiOauth block is ABSENT — the same call
// anthropic.ParseOAuthCred makes for the SOURCE read, so the two agree on
// every JSON-object payload. Anything else non-empty is UNKNOWN.
func liveState(readErr error, blob []byte) liveSlotState {
	if errors.Is(readErr, ErrNotFound) {
		return liveAbsent
	}
	if readErr != nil {
		// The caller aborts on these before ever getting here; kept so
		// liveState is correct on its own terms if it gains a second caller.
		return liveUnknown
	}
	if len(bytes.TrimSpace(blob)) == 0 {
		// A zero-length item or a torn write: something exists but says
		// nothing. Unknown, not absent.
		return liveUnknown
	}
	if _, err := anthropic.ParseOAuthCred(blob); err == nil {
		return liveIdentified
	}
	var doc map[string]json.RawMessage
	if json.Unmarshal(blob, &doc) == nil {
		return liveAbsent // parses, carries no usable sign-in
	}
	return liveUnknown
}
