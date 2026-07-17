package switcher

// Keep-warm: proactively refresh an IDLE account's OAuth token in place so the
// dashboard keeps polling its usage and the autopilot can fail over to it —
// without ever making a model call (no 5h-window advance) and without racing
// Claude Code's own refresh. It is the credential-write half of Wave 8.3;
// docs/research/TOKEN-KEEP-WARM.md is the ground truth for the endpoint and
// the rotation/clobber hazard.
//
// The refresh token ROTATES on every successful POST — the old one dies
// server-side. So rotation + persist must be atomic against every other
// writer of the same credential copy:
//
//   - Mode B (global-dir account, currently idle): its only copy is the
//     llmpilot backup. We hold the backups lock across the POST. No Claude
//     Code lock is taken — CC never touches backups.
//   - Mode A (pinned per-dir account): its live copy is that dir's own
//     Keychain entry, which a CLAUDE_CONFIG_DIR-pinned `claude` session can
//     refresh. We hold THAT dir's Claude Code lock set across the POST, the
//     way CC itself refreshes under it, so the two can't interleave.
//
// The ACTIVE global account is never kept warm here — Claude Code owns it and
// caches it in memory; the daemon filters it out and the fingerprint-vs-live
// guard is the backstop.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// BackupTokenSource reads an account's access token / expiry from its
// llmpilot backup — the canonical copy for a GLOBAL-dir account that is
// currently idle. Without it the daemon would poll such an account's usage
// (and read its expiry) through the GLOBAL Keychain slot, which holds the
// ACTIVE account's credential — reporting the wrong account's numbers and
// leading the keep-warm loop on the wrong expiry. It has NO file fallback:
// falling back to the global .credentials.json would reintroduce exactly that
// misattribution.
type BackupTokenSource struct {
	Switcher  *Switcher
	AccountID string
}

// Token returns the backed-up access token.
func (b BackupTokenSource) Token(ctx context.Context) (string, error) {
	c, err := b.parse(ctx)
	if err != nil {
		return "", err
	}
	if c.AccessToken == "" {
		return "", errors.New("credential payload: no claudeAiOauth.accessToken")
	}
	return c.AccessToken, nil
}

// Expiry returns the backed-up token's expiry (zero when the payload has none).
func (b BackupTokenSource) Expiry(ctx context.Context) (time.Time, error) {
	c, err := b.parse(ctx)
	if err != nil {
		return time.Time{}, err
	}
	return c.ExpiresAt, nil
}

func (b BackupTokenSource) parse(ctx context.Context) (anthropic.OAuthCred, error) {
	cred, _, err := b.Switcher.LoadBackup(ctx, b.AccountID)
	if err != nil {
		return anthropic.OAuthCred{}, err
	}
	return anthropic.ParseOAuthCred(cred)
}

// ErrLineageDead marks a refresh the token endpoint permanently rejected
// (invalid_grant/invalid_client): the refresh-token lineage is dead and only
// a re-login recovers it. The daemon quarantines on this; everything else is
// transient. The wrapped error carries only the HTTP status + OAuth code.
var ErrLineageDead = errors.New("refresh token lineage is dead (re-login required)")

// TokenRefresher performs one OAuth refresh grant. Injected so tests never hit
// the network and so the endpoint knowledge stays in internal/anthropic.
type TokenRefresher func(ctx context.Context, refreshToken string) (anthropic.RefreshResult, error)

// KeepWarmOpts configures one keep-warm attempt.
type KeepWarmOpts struct {
	Refresh     TokenRefresher
	RefreshLead time.Duration    // refresh only when the token expires within this
	Now         func() time.Time // nil = time.Now
}

func (o KeepWarmOpts) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

// KeepWarmResult reports what one attempt did. Fingerprint is the lineage
// identity of the credential acted on — the daemon keys its quarantine on it
// so a re-login (new lineage) auto-clears the quarantine.
type KeepWarmResult struct {
	Rotated     bool
	Skipped     string // reason nothing was done (empty when Rotated)
	Expiry      time.Time
	Fingerprint string
}

func skipResult(reason, fp string, exp time.Time) KeepWarmResult {
	return KeepWarmResult{Skipped: reason, Fingerprint: fp, Expiry: exp}
}

// Fingerprint returns the lineage fingerprint of an account's canonical
// credential copy, no network and no locks (advisory: used by the daemon to
// notice a quarantined account was re-logged-in). "" when no copy exists.
func (s *Switcher) Fingerprint(ctx context.Context, acct store.Account) (string, error) {
	blob, _, err := s.canonicalBlob(ctx, acct)
	if errors.Is(err, ErrNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return anthropic.CredFingerprint(blob), nil
}

// canonicalBlob reads an account's authoritative credential copy WITHOUT
// locks. Mode B (global-dir account): the llmpilot backup. Mode A (pinned
// dir): that dir's Keychain entry, falling back to its credentials file.
// Returns the identity block too (mode B carries it in the backup payload).
func (s *Switcher) canonicalBlob(ctx context.Context, acct store.Account) ([]byte, json.RawMessage, error) {
	if s.isPinned(acct) {
		blob, _, err := s.readPinned(ctx, acct)
		return blob, nil, err
	}
	return s.LoadBackup(ctx, acct.ID)
}

// isPinned reports whether the account lives in its own config dir (mode A)
// rather than the global swap-managed slot (mode B).
func (s *Switcher) isPinned(acct store.Account) bool {
	return acct.ConfigDir != "" && claudecfg.DirAt(acct.ConfigDir).Path() != s.Dir.Path()
}

// KeepWarm refreshes one idle account's token if it is near expiry, choosing
// the mode from the account's config dir. It is safe to call on any account:
// the active account, an account not near expiry, or one whose lineage is
// already live elsewhere all return a Skipped result with no write.
func (s *Switcher) KeepWarm(ctx context.Context, acct store.Account, opts KeepWarmOpts) (KeepWarmResult, error) {
	if opts.Refresh == nil {
		return KeepWarmResult{}, errors.New("keep-warm: no refresher configured")
	}
	// Detach from a caller's cancellation like Swap: a client hangup must not
	// interrupt a rotation between the POST and the write-back.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancel()
	if s.isPinned(acct) {
		return s.keepWarmPinned(ctx, acct, opts)
	}
	return s.keepWarmBackup(ctx, acct, opts)
}

// keepWarmBackup is mode B: refresh a global-dir idle account whose only copy
// is the llmpilot backup, serialized by the backups lock alone.
func (s *Switcher) keepWarmBackup(ctx context.Context, acct store.Account, opts KeepWarmOpts) (KeepWarmResult, error) {
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return KeepWarmResult{}, err
	}
	defer releaseLock(bl)

	// A swap journal implicates ONLY its two accounts (their backup state may
	// be mid-flight). Stand down for those; every other account's backup is
	// independent, so a single interrupted swap must not freeze keep-warm for
	// the whole fleet (lock-race review, 2026-07-16).
	if j, jerr := s.readJournal(ctx); jerr != nil {
		return KeepWarmResult{}, jerr
	} else if j != nil && (j.FromID == acct.ID || j.ToID == acct.ID) {
		return skipResult("swap in progress for this account", "", time.Time{}), nil
	}

	cred, oauthRaw, err := s.LoadBackup(ctx, acct.ID)
	if errors.Is(err, ErrNotFound) {
		return skipResult("no backup", "", time.Time{}), nil
	}
	if err != nil {
		return KeepWarmResult{}, err
	}
	fp := anthropic.CredFingerprint(cred)

	if email := oauthEmail(oauthRaw); email != "" && acct.Email != "" && email != acct.Email {
		return skipResult("backup identity mismatch", fp, time.Time{}), nil
	}
	// If the backup IS the live global credential, Claude Code owns it (this
	// is the active account, or a swap died mid-flight leaving the backup as
	// the live copy). Refreshing it would race CC — never do it.
	live, err := s.globalLiveCred(ctx)
	if err != nil {
		return KeepWarmResult{}, err
	}
	if live != nil && anthropic.CredFingerprint(live) == fp {
		return skipResult("backup is the live credential", fp, time.Time{}), nil
	}

	res, _, err := s.rotate(ctx, cred, fp, opts,
		func(ctx context.Context, spliced []byte) error {
			return s.SaveBackup(ctx, acct.ID, spliced, oauthRaw)
		},
		func(ctx context.Context) ([]byte, error) {
			got, _, err := s.LoadBackup(ctx, acct.ID)
			return got, err
		},
	)
	return res, err
}

// keepWarmPinned is mode A: refresh a per-dir account in place under that
// dir's Claude Code lock set (network under the lock, exactly as CC refreshes).
func (s *Switcher) keepWarmPinned(ctx context.Context, acct store.Account, opts KeepWarmOpts) (KeepWarmResult, error) {
	dir := claudecfg.DirAt(acct.ConfigDir)
	// Interlock: under test never touch a real config dir. Sandboxes live in
	// temp dirs (never under the real home); real pinned dirs are refused.
	if err := assertSandboxDir(dir.Path()); err != nil {
		return KeepWarmResult{}, err
	}
	service := acct.KeychainService
	if service == "" {
		service = dir.KeychainService()
	}

	// The dir locks are released EXPLICITLY (not deferred) before the trailing
	// backup save, so we never hold the pinned dir's Claude Code lock while
	// blocking on the backups lock — that would stall a live `claude` session
	// in that dir for a best-effort save (lock-race review, 2026-07-16).
	release, err := s.lockDirAll(ctx, dir)
	if err != nil {
		return KeepWarmResult{}, err
	}
	released := false
	releaseDir := func() {
		if !released {
			release()
			released = true
		}
	}
	defer releaseDir()

	// Read the live credential fresh UNDER the lock (a CC refresh finishing
	// just before we locked rotated it; this read sees the rotated one).
	blob, fromFile, err := s.readPinned(ctx, acct)
	if errors.Is(err, ErrNotFound) {
		return skipResult("no live credential", "", time.Time{}), nil
	}
	if err != nil {
		return KeepWarmResult{}, err
	}
	fp := anthropic.CredFingerprint(blob)

	// Identity guard: the dir must still be logged into this account.
	if email := oauthEmail(mustOAuthRaw(dir.ConfigJSONPath())); email != "" && acct.Email != "" && email != acct.Email {
		return skipResult("dir identity mismatch", fp, time.Time{}), nil
	}
	// Clone guard: if this pinned credential is the SAME lineage as the live
	// global slot (a pre-existing swap clone), refreshing it kills the active
	// account's token. Never rotate a lineage that lives in two places.
	live, err := s.globalLiveCred(ctx)
	if err != nil {
		return KeepWarmResult{}, err
	}
	if live != nil && anthropic.CredFingerprint(live) == fp {
		return skipResult("lineage also live in the global slot", fp, time.Time{}), nil
	}

	write := func(ctx context.Context, spliced []byte) error {
		return s.writePinned(ctx, dir, service, fromFile, spliced)
	}
	verify := func(ctx context.Context) ([]byte, error) {
		got, _, err := s.readPinnedFrom(ctx, dir, service, fromFile)
		return got, err
	}
	res, spliced, err := s.rotate(ctx, blob, fp, opts, write, verify)
	if err != nil || !res.Rotated {
		return res, err
	}
	oauthRaw := mustOAuthRaw(dir.ConfigJSONPath())
	// Release the dir's Claude Code locks BEFORE touching the backups lock:
	// the in-place rotation is already persisted and verified above.
	releaseDir()
	// Keep the backup in step so an un-pinning of this account later doesn't
	// resurrect a dead token. Best-effort: save the exact spliced blob we just
	// wrote (no re-read — the dir is unlocked now). A failure here does not
	// undo the successful in-place rotation.
	if bl, blErr := s.acquireBackupsLock(ctx); blErr == nil {
		if err := s.SaveBackup(ctx, acct.ID, spliced, oauthRaw); err != nil {
			s.logf("keep-warm: pinned rotation persisted, backup mirror failed: %v", err)
		}
		releaseLock(bl)
	}
	return res, nil
}

// rotate is the refresh core shared by both modes: re-check expiry under the
// caller's lock, POST, splice preserving unknown fields, persist via write,
// verify the read-back. write/verify target the mode's canonical copy.
func (s *Switcher) rotate(
	ctx context.Context,
	blob []byte,
	fp string,
	opts KeepWarmOpts,
	write func(ctx context.Context, spliced []byte) error,
	verify func(ctx context.Context) ([]byte, error),
) (KeepWarmResult, []byte, error) {
	cur, err := anthropic.ParseOAuthCred(blob)
	if err != nil {
		return KeepWarmResult{Fingerprint: fp}, nil, err
	}
	if cur.ExpiresAt.IsZero() {
		return skipResult("no stored expiry", fp, time.Time{}), nil, nil
	}
	if cur.ExpiresAt.Sub(opts.now()) > opts.RefreshLead {
		return skipResult("not near expiry", fp, cur.ExpiresAt), nil, nil
	}
	if cur.RefreshToken == "" {
		return skipResult("no refresh token", fp, cur.ExpiresAt), nil, nil
	}

	res, err := opts.Refresh(ctx, cur.RefreshToken)
	if err != nil {
		var re *anthropic.RefreshError
		if errors.As(err, &re) && re.Permanent() {
			return KeepWarmResult{Fingerprint: fp, Expiry: cur.ExpiresAt}, nil,
				fmt.Errorf("%w: %v", ErrLineageDead, err)
		}
		return KeepWarmResult{Fingerprint: fp, Expiry: cur.ExpiresAt}, nil, err
	}

	spliced, err := anthropic.SpliceOAuthCred(blob, res)
	if err != nil {
		return KeepWarmResult{Fingerprint: fp}, nil, err
	}
	if err := write(ctx, spliced); err != nil {
		// The server already rotated; if the write failed the stored token is
		// now stale and the next pass will surface invalid_grant honestly.
		return KeepWarmResult{Fingerprint: fp}, nil, fmt.Errorf("keep-warm persist: %w", err)
	}
	got, err := verify(ctx)
	if err != nil {
		return KeepWarmResult{Fingerprint: fp}, nil, fmt.Errorf("keep-warm verify read-back: %w", err)
	}
	gotCred, err := anthropic.ParseOAuthCred(got)
	if err != nil || gotCred.AccessToken != res.AccessToken {
		return KeepWarmResult{Fingerprint: fp}, nil, errors.New("keep-warm verify: read-back does not match the rotated credential")
	}
	return KeepWarmResult{
		Rotated:     true,
		Expiry:      gotCred.ExpiresAt,
		Fingerprint: anthropic.CredFingerprint(spliced),
	}, spliced, nil
}

// globalLiveCred reads the credential currently installed in the global slot
// (nil when none). Used as the active/clone guard in both modes.
func (s *Switcher) globalLiveCred(ctx context.Context) ([]byte, error) {
	cred, err := s.Keychain.Get(ctx, s.Dir.KeychainService())
	if errors.Is(err, ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return cred, nil
}

// readPinned reads a pinned account's live credential, Keychain first then the
// credentials file. fromFile reports which source answered so the write-back
// targets the same one.
func (s *Switcher) readPinned(ctx context.Context, acct store.Account) (blob []byte, fromFile bool, err error) {
	dir := claudecfg.DirAt(acct.ConfigDir)
	service := acct.KeychainService
	if service == "" {
		service = dir.KeychainService()
	}
	return s.readPinnedFrom(ctx, dir, service, false)
}

// readPinnedFrom reads from the Keychain, falling back to the credentials
// file. preferFile forces the file (used by verify after a file write).
func (s *Switcher) readPinnedFrom(ctx context.Context, dir claudecfg.Dir, service string, preferFile bool) (blob []byte, fromFile bool, err error) {
	if !preferFile {
		cred, kerr := s.Keychain.Get(ctx, service)
		if kerr == nil {
			return cred, false, nil
		}
		if !errors.Is(kerr, ErrNotFound) {
			return nil, false, kerr
		}
	}
	data, ferr := os.ReadFile(dir.CredentialsFilePath())
	if ferr != nil {
		if os.IsNotExist(ferr) {
			return nil, false, fmt.Errorf("service %q: %w", service, ErrNotFound)
		}
		return nil, false, ferr
	}
	return data, true, nil
}

// writePinned installs the rotated credential back into the same source it was
// read from: the Keychain (upsert) or the credentials file (atomic replace).
func (s *Switcher) writePinned(ctx context.Context, dir claudecfg.Dir, service string, toFile bool, blob []byte) error {
	if toFile {
		if err := assertSandboxDir(dir.Path()); err != nil {
			return err
		}
		return atomicWriteFile(dir.CredentialsFilePath(), blob, 0o600)
	}
	return s.Keychain.Set(ctx, service, s.account(), blob)
}

// mustOAuthRaw reads the oauthAccount block, returning nil on any error (the
// identity guards treat "" as "unknown, don't block"; a re-save preserves
// whatever was there).
func mustOAuthRaw(path string) json.RawMessage {
	raw, err := oauthAccountRaw(path)
	if err != nil {
		return nil
	}
	return raw
}

// atomicWriteFile writes data to path via tempfile+rename with the given
// perms — the same discipline the config splice uses.
func atomicWriteFile(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(perm); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
