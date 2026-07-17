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
