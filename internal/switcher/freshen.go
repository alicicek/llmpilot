package switcher

import (
	"bytes"
	"context"
	"errors"
	"fmt"
)

// FreshenBackup re-captures acct's LIVE credential from the switcher's
// config dir into llmpilot's backups — but only when that dir is actually
// logged into acct (identity-checked) and the credential differs from the
// stored backup. Why: Claude Code rotates the refresh token on every
// refresh, and a bare /login clobbers the keychain slot without any backup
// — an account's stored credential silently dies unless someone re-captures
// it while it's still live (live failure, 2026-07-10). The daemon calls
// this after each poll of the active account, making the last-known-good
// backup at most one poll interval old.
func (s *Switcher) FreshenBackup(ctx context.Context, acct Identity) (bool, error) {
	// EVERYTHING runs under the backups lock — the identity read, the
	// credential read, and the save. Swap holds this same lock across its
	// entire mutation (keychain write THEN config splice), so reading the
	// credential and the identity while we hold it guarantees a SETTLED
	// snapshot: we never observe Swap's intermediate state (keychain already
	// the new account, config still the old one) and so can never capture the
	// new account's credential under acct.ID — the clone-into-two-copies
	// death the earlier read-then-lock ordering allowed (lock-race review,
	// 2026-07-16). Capturing the credential BEFORE the lock is the bug.
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return false, err
	}
	defer releaseLock(bl)

	// A leftover swap journal means the config identity may NOT describe the
	// live credential (a swap died mid-mutation) — and the config identity is
	// this function's ONLY attribution. Stand down entirely and let the next
	// swap run its hash-based recovery first; capturing here would destroy
	// the very state the journal exists to recover (adversarial review P1,
	// 2026-07-25: freshen ran every poll and clobbered the backup before any
	// swap could read the journal).
	if j, jerr := s.readJournal(ctx); jerr != nil {
		return false, jerr
	} else if j != nil {
		s.logf("freshen: swap journal pending (%s → %s) — standing down until the next swap recovers", j.FromID, j.ToID)
		return false, nil
	}

	oauthRaw, err := oauthAccountRaw(s.Dir.ConfigJSONPath())
	if err != nil {
		return false, err
	}
	if email := oauthEmail(oauthRaw); email == "" || email != acct.Email {
		return false, nil // dir belongs to someone else right now — not ours to capture
	}
	cred, err := s.Keychain.Get(ctx, s.Dir.KeychainService())
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	// Anti-poisoning (review P1): if the live credential verifiably belongs
	// to a DIFFERENT registered account (its fingerprint matches that
	// account's current backup), a stale Claude Code session of the previous
	// account has written its credential into the slot after a swap —
	// capturing it under acct.ID would destroy acct's good backup. RESIDUAL,
	// stated honestly: if that stale session ROTATED first, the fingerprint
	// matches no backup and is indistinguishable from acct's own rotation —
	// no local signal exists; the classify-on-next-swap path preserves the
	// credential either way (stash, never overwrite).
	if other := s.resolveByFingerprint(ctx, cred); other != "" && other != acct.ID {
		s.logf("freshen: live credential belongs to %s, not %s — not captured", other, acct.ID)
		return false, nil
	}
	old, _, err := s.LoadBackup(ctx, acct.ID)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return false, err
	}
	if bytes.Equal(old, cred) {
		return false, nil
	}
	if err := s.SaveBackup(ctx, acct.ID, cred, oauthRaw); err != nil {
		return false, fmt.Errorf("freshen backup for %s: %w", acct.ID, err)
	}
	s.logf("backup freshened: %s → %s/%s (%s)", acct.Email, BackupService, acct.ID, redact(cred))
	return true, nil
}

// Identity is the minimal account identity FreshenBackup needs.
type Identity struct {
	ID    string
	Email string
}
