package switcher

// In-app sign-in install: the daemon exchanges an authorization code (no
// locks held — network never happens under locks), then hands the minted
// credential + identity here. This path reuses swapTo's whole safety
// machinery — journal, current-account backup, rollback, verified writes —
// so a fresh login gets exactly the discipline a swap does (hazard #1).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// InstallLogin registers a freshly minted OAuth credential as a
// GLOBAL-SWAPPABLE account on this switcher's dir and installs it as the
// active credential, backing up the previous active account first. The
// account's ConfigDir is the switcher's dir, so Swap's pinned-guard accepts
// it later. oauthAccount must carry the account's identity (emailAddress at
// minimum) — the fleet label derives from it.
func (s *Switcher) InstallLogin(ctx context.Context, cred, oauthAccount json.RawMessage) (store.Account, error) {
	if s.Dir.Path() == "" {
		return store.Account{}, errors.New("switcher: no config dir")
	}
	// Same interlock as Swap, checked before anything is written.
	if err := assertSandboxConfigPath(s.Dir.ConfigJSONPath()); err != nil {
		return store.Account{}, err
	}
	// Boundary validation: a corrupt mint must never reach the Keychain.
	if _, err := anthropic.ParseOAuthCred(cred); err != nil {
		return store.Account{}, fmt.Errorf("sign-in credential: %w", err)
	}
	email := oauthEmail(oauthAccount)
	if email == "" {
		return store.Account{}, errors.New("sign-in identity carries no email address")
	}

	// A re-login must land on the account already registered for this email —
	// a fresh ID would fork the registry entry AND the backup key, letting a
	// concurrent keep-warm of the old key outlive the new lineage.
	id, label := "", labelFromEmail(email)
	if s.Registry != nil {
		accs, err := s.Registry.Accounts()
		if err != nil {
			return store.Account{}, err
		}
		for _, a := range accs {
			if a.Email == email {
				id = a.ID
				if a.Label != "" {
					label = a.Label
				}
				break
			}
		}
	}
	if id == "" {
		id = "acct-" + sanitizeID(strings.ToLower(email))
	}
	acct := store.Account{
		ID:              id,
		Label:           label,
		Email:           email,
		ConfigDir:       s.Dir.Path(),
		KeychainService: s.Dir.KeychainService(),
	}
	// Register BEFORE the install: swapTo's current-backup attribution then
	// resolves this email to the right ID on a re-login, and a crash between
	// registration and install leaves a visible account the user can retry —
	// never an installed credential the fleet doesn't know about.
	if err := s.registerAccount(acct); err != nil {
		return store.Account{}, err
	}
	if err := s.swapTo(ctx, acct, &loginInstall{cred: cred, oauthAccount: oauthAccount}); err != nil {
		return store.Account{}, err
	}
	// ONLY now, with the fresh grant durably persisted, is the old duplicate
	// irrelevant — clearing before this point disarmed the guard for a login
	// that then failed on a lock or a read, leaving the old backup and its
	// surviving source copy duplicated and unguarded (Codex review P1).
	s.ClearCloneSuspect(ctx, acct.ID)
	s.logf("signed in: %s registered as %s (global-swappable) and active", email, acct.ID)
	return acct, nil
}
