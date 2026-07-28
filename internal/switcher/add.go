package switcher

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// LoginRunner runs an interactive command with inherited stdio. `claude auth
// login` prints an OAuth URL, opens a browser, and reads an optional pasted
// code from stdin (plain readline, verified against the 2.1.205 binary) — so
// it needs the parent's terminal, not a captured pipe. Injectable: CI and
// tests use a stub standing in for `claude`.
type LoginRunner func(ctx context.Context, env []string, name string, args ...string) error

// ExecLoginRunner runs the command for real with inherited stdio.
func ExecLoginRunner(ctx context.Context, env []string, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), env...)
	return cmd.Run()
}

// AddResult reports what AddAccount registered.
type AddResult struct {
	Account   store.Account
	LoggedVia string // "existing session" or "claude auth login"
}

// AddAccount registers the account currently logged into dir — running
// `claude auth login` first if dir has no identity — and captures its
// credential into llmpilot's backups. The captured credential is what Swap
// later installs; without this step an account cannot be swapped to.
func (s *Switcher) AddAccount(ctx context.Context, dir claudecfg.Dir, label string, login LoginRunner, claudeBin string) (*AddResult, error) {
	if claudeBin == "" {
		claudeBin = "claude"
	}
	// Same filesystem interlock as Swap: under LLMPILOT_TEST this flow may
	// only ever operate on a sandbox config dir (it can invoke a login that
	// writes the dir, and it registers credentials from it).
	if err := assertSandboxConfigPath(dir.ConfigJSONPath()); err != nil {
		return nil, err
	}
	res := &AddResult{LoggedVia: "existing session"}

	acct, err := dir.OAuthAccount()
	if err != nil {
		return nil, err
	}
	if acct == nil || acct.EmailAddress == "" {
		if login == nil {
			return nil, errors.New("config dir has no logged-in account and no login runner provided")
		}
		// Inherited-TTY login under the target dir. CLAUDE_CONFIG_DIR steers
		// both the config file and the Keychain service name (verified in
		// the 2.1.205 binary: sha256 suffix derives from this env var).
		env := []string{"CLAUDE_CONFIG_DIR=" + dir.Path()}
		if err := login(ctx, env, claudeBin, "auth", "login"); err != nil {
			return nil, fmt.Errorf("claude auth login: %w", err)
		}
		res.LoggedVia = "claude auth login"
		acct, err = dir.OAuthAccount()
		if err != nil {
			return nil, err
		}
		if acct == nil || acct.EmailAddress == "" {
			return nil, errors.New("login finished but the config dir still has no oauthAccount")
		}
	}

	if label == "" {
		label = labelFromEmail(acct.EmailAddress)
	}
	id := "acct-" + sanitizeID(strings.ToLower(acct.EmailAddress))

	// Capture the live credential into our backups UNDER the dir's locks +
	// the backups lock. Without them a keep-warm rotation (or a CC refresh)
	// landing between the read and the SaveBackup would persist a stale,
	// already-dead refresh token as the backup. The interactive login above
	// stays OUTSIDE the locks (it can take minutes).
	dirRelease, err := s.lockDirAll(ctx, dir)
	if err != nil {
		return nil, err
	}
	defer dirRelease()
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return nil, err
	}
	defer releaseLock(bl)

	cred, err := s.Keychain.Get(ctx, dir.KeychainService())
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return nil, fmt.Errorf("no credential in Keychain service %q — did the login complete?", dir.KeychainService())
		}
		return nil, err
	}
	oauthRaw, err := oauthAccountRaw(dir.ConfigJSONPath())
	if err != nil {
		return nil, err
	}
	if err := s.SaveBackup(ctx, id, json.RawMessage(cred), oauthRaw); err != nil {
		return nil, err
	}
	s.logf("credential captured: %s → %s/%s (%s)", acct.EmailAddress, BackupService, id, redact(cred))

	res.Account = store.Account{
		ID:              id,
		Label:           label,
		Email:           acct.EmailAddress,
		ConfigDir:       dir.Path(),
		KeychainService: dir.KeychainService(),
	}
	if err := s.registerAccount(res.Account); err != nil {
		return nil, err
	}
	return res, nil
}

// registerAccount upserts one account into the registry by ID. A nil
// registry (throwaway test switchers) is a no-op.
func (s *Switcher) registerAccount(acct store.Account) error {
	if s.Registry == nil {
		return nil
	}
	accs, err := s.Registry.Accounts()
	if err != nil {
		return err
	}
	replaced := false
	for i, a := range accs {
		if a.ID == acct.ID {
			accs[i] = acct
			replaced = true
			break
		}
	}
	if !replaced {
		accs = append(accs, acct)
	}
	return s.Registry.SaveAccounts(accs)
}

func labelFromEmail(email string) string {
	if i := strings.IndexByte(email, '@'); i > 0 {
		return email[:i]
	}
	return email
}
