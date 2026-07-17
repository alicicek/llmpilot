package switcher

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// BackupService is llmpilot's own Keychain service for per-account credential
// backups — never Claude Code's service, so nothing else reads or clobbers it.
const BackupService = "llmpilot-backups"

// DefaultLockTimeout bounds how long a swap waits for Claude Code's locks.
// CC's own refresh holds them for one network round-trip; 15s outlasts that
// without hanging a surface forever.
const DefaultLockTimeout = 15 * time.Second

// backupPayload is what we store per account: the full credential item value
// plus the oauthAccount identity block. It lives ONLY in the Keychain.
type backupPayload struct {
	Credential   json.RawMessage `json:"credential"`
	OAuthAccount json.RawMessage `json:"oauthAccount,omitempty"`
	SavedAt      time.Time       `json:"saved_at"`
}

// journalAccount is the keychain account attribute holding the swap journal.
const journalAccount = "swap-journal"

// swapJournal is written (to the Keychain, never disk) just before the
// mutation phase and cleared after the verified finish. A leftover journal
// means a previous swap died mid-flight; FromCredHash lets the next swap
// attribute the live credential deterministically instead of trusting the
// possibly-stale .claude.json identity — misattribution there is what
// permanently kills an account (adversarial review P0, 2026-07-09).
type swapJournal struct {
	FromID       string    `json:"from_id"`
	ToID         string    `json:"to_id"`
	FromCredHash string    `json:"from_cred_hash"` // sha256 hex of the pre-swap credential
	StartedAt    time.Time `json:"started_at"`
}

func credHash(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func (s *Switcher) writeJournal(ctx context.Context, j swapJournal) error {
	data, err := json.Marshal(j)
	if err != nil {
		return err
	}
	return s.Keychain.Set(ctx, BackupService, journalAccount, data)
}

func (s *Switcher) readJournal(ctx context.Context) (*swapJournal, error) {
	raw, err := s.Keychain.GetAccount(ctx, BackupService, journalAccount)
	if errors.Is(err, ErrNotFound) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var j swapJournal
	if err := json.Unmarshal(raw, &j); err != nil {
		return nil, fmt.Errorf("swap journal: corrupt payload")
	}
	return &j, nil
}

func (s *Switcher) clearJournal(ctx context.Context) error {
	return s.Keychain.Delete(ctx, BackupService, journalAccount)
}

// Switcher performs account swaps on one Claude Code config dir (the global
// default dir in normal use; a sandbox dir in tests).
type Switcher struct {
	Dir      claudecfg.Dir
	Keychain *Keychain // carries the throwaway-keychain interlock
	Registry *store.Store
	Out      io.Writer // swap transcript (locks, identities); never secrets

	// KeychainAccount overrides the -a attribute (default:
	// claudecfg.KeychainAccount()).
	KeychainAccount string
	LockTimeout     time.Duration
}

func (s *Switcher) logf(format string, args ...any) {
	if s.Out != nil {
		fmt.Fprintf(s.Out, format+"\n", args...)
	}
}

func (s *Switcher) account() string {
	if s.KeychainAccount != "" {
		return s.KeychainAccount
	}
	return claudecfg.KeychainAccount()
}

func (s *Switcher) lockTimeout() time.Duration {
	if s.LockTimeout != 0 {
		return s.LockTimeout
	}
	return DefaultLockTimeout
}

// backupsLockTimeout is more generous than the CC-lock timeout: a keep-warm
// mode-B holder keeps the backups lock across an ~8s refresh POST, and the
// daemon and a CLI `account refresh` can each hold it back-to-back. A 15s
// budget could then fail a user's swap; ~3× the POST budget tolerates a
// realistic pileup without hanging a surface forever.
func (s *Switcher) backupsLockTimeout() time.Duration {
	t := s.lockTimeout()
	if min := 30 * time.Second; t < min {
		return min
	}
	return t
}

// SaveBackup captures an account's current credential + identity into
// llmpilot's own Keychain service.
func (s *Switcher) SaveBackup(ctx context.Context, accountID string, cred, oauthAccount json.RawMessage) error {
	payload, err := json.Marshal(backupPayload{
		Credential:   cred,
		OAuthAccount: oauthAccount,
		SavedAt:      time.Now().UTC(),
	})
	if err != nil {
		return err
	}
	return s.Keychain.Set(ctx, BackupService, accountID, payload)
}

// LoadBackup reads an account's stored credential + identity.
func (s *Switcher) LoadBackup(ctx context.Context, accountID string) (cred, oauthAccount json.RawMessage, err error) {
	raw, err := s.Keychain.GetAccount(ctx, BackupService, accountID)
	if err != nil {
		return nil, nil, err
	}
	var p backupPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return nil, nil, fmt.Errorf("backup for %q: corrupt payload", accountID)
	}
	return p.Credential, p.OAuthAccount, nil
}

// lockAll acquires every lock a swap of THIS switcher's dir needs.
func (s *Switcher) lockAll(ctx context.Context) (func(), error) {
	return s.lockDirAll(ctx, s.Dir)
}

// lockDirAll acquires Claude Code's four locks for an arbitrary config dir,
// in a fixed order (real CC locks first, then legacy claude-swap paths), and
// returns a release func that unlocks in reverse. Fixed order = no deadlock
// against another llmpilot. Keep-warm of a pinned account locks that
// account's OWN dir, not the global one — hence the dir parameter.
func (s *Switcher) lockDirAll(ctx context.Context, dir claudecfg.Dir) (func(), error) {
	specs := []struct {
		path  string
		stale time.Duration
		label string
	}{
		{dir.OAuthRefreshLockPath(), 10 * time.Second, "cc oauth-refresh"},
		{dir.StorageWriteLockPath(), 15 * time.Second, "cc storage-write"},
		{dir.LegacyCredentialsLockPath(), 10 * time.Second, "legacy credentials"},
		{dir.LegacyConfigLockPath(), 10 * time.Second, "legacy config"},
	}
	var held []*mutexLock
	release := func() {
		for i := len(held) - 1; i >= 0; i-- {
			held[i].release()
		}
		s.logf("locks released (%d)", len(held))
	}
	for _, sp := range specs {
		l, err := acquireLock(ctx, sp.path, sp.stale, s.lockTimeout())
		if err != nil {
			release()
			return nil, err
		}
		held = append(held, l)
		s.logf("lock acquired: %s (%s)", sp.label, sp.path)
	}
	return release, nil
}

// backupsLockPath is llmpilot's OWN mutex serializing every writer of the
// llmpilot-backups Keychain service (Swap's backup span, Freshen, AddAccount's
// capture, both keep-warm modes). Nothing Claude Code does touches it. It
// lives in $LLMPILOT_HOME so it is shared across the daemon and CLI processes.
func (s *Switcher) backupsLockPath() (string, bool) {
	if s.Registry == nil {
		return "", false
	}
	return filepath.Join(s.Registry.Home(), ".backups.lock"), true
}

// acquireBackupsLock takes the backups mutex. It is ALWAYS acquired AFTER any
// config-dir locks (fixed global order) so two writers holding different dir
// locks can never deadlock on it. A switcher with no registry (throwaway test
// paths) has no shared home to serialize on and gets a no-op lock.
func (s *Switcher) acquireBackupsLock(ctx context.Context) (*mutexLock, error) {
	path, ok := s.backupsLockPath()
	if !ok {
		return nil, nil
	}
	// The store home may not exist yet (first write of a fresh install); the
	// mkdir-mutex needs its parent present.
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("backups lock dir: %w", err)
	}
	l, err := acquireLock(ctx, path, 10*time.Second, s.backupsLockTimeout())
	if err != nil {
		return nil, fmt.Errorf("backups lock: %w", err)
	}
	s.logf("lock acquired: llmpilot backups (%s)", path)
	return l, nil
}

// releaseLock releases a possibly-nil lock (the no-op backups lock above).
func releaseLock(l *mutexLock) {
	if l != nil {
		l.release()
	}
}

// Swap switches the config dir to the target account:
//
//	locks → backup current → write target credential → splice oauthAccount →
//	verify → unlock.
//
// The target's credential must already be in llmpilot's backups (captured at
// add time or by a previous swap-away). No network happens under the locks.
func (s *Switcher) Swap(ctx context.Context, target store.Account) (err error) {
	if s.Dir.Path() == "" {
		return errors.New("switcher: no config dir")
	}
	// A pinned (per-dir) account keeps its own live credential in its own
	// Keychain service; installing it into the GLOBAL slot would clone one
	// refresh-token lineage into two live copies, and the next rotation of
	// either kills the other (owner decision 2026-07-16). Such accounts are
	// used via a CLAUDE_CONFIG_DIR-pinned terminal and kept fresh in place —
	// never swapped into the global dir.
	if target.ConfigDir != "" && claudecfg.DirAt(target.ConfigDir).Path() != s.Dir.Path() {
		return fmt.Errorf("account %q is pinned to its own config dir (%s) — it is used via that dir, not swapped into the global account", target.Label, target.ConfigDir)
	}
	ccService := s.Dir.KeychainService()
	cfgPath := s.Dir.ConfigJSONPath()
	// The interlock runs BEFORE any lock or write: a test pointed at the
	// real config dir dies here.
	if err := assertSandboxConfigPath(cfgPath); err != nil {
		return err
	}

	// Load the target's stored credential BEFORE locking — fail fast on a
	// missing backup. This copy is an existence check ONLY: it is re-loaded
	// under the locks below, because keep-warm may rotate the backup between
	// here and the install (the pre-lock copy would be a dead lineage).
	if _, _, err := s.LoadBackup(ctx, target.ID); err != nil {
		if errors.Is(err, ErrNotFound) {
			return fmt.Errorf("account %q has no stored credential — run `llmpilot account add` while logged into it first", target.Label)
		}
		return err
	}

	// From here on the swap must not be killable by a disconnecting caller
	// (the daemon passes the HTTP request context — a client hangup must
	// never cancel a subprocess between the two credential writes). A fresh
	// deadline still bounds a wedged /usr/bin/security under the locks.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancel()

	release, err := s.lockAll(ctx)
	if err != nil {
		return err
	}
	defer release()

	// The backups lock (held across the whole mutation) serializes this swap
	// against keep-warm's backup rotation: keep-warm either finishes first
	// (we re-load the rotated backup below) or waits for us (its
	// fingerprint-vs-live guard then sees the target is now active and skips).
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return err
	}
	defer releaseLock(bl)

	// Under the locks: capture the CURRENT credential + identity. Reading
	// under the lock matters: a CC refresh finishing just before we locked
	// rotated the refresh token, and this read sees the rotated one.
	curCred, err := s.Keychain.Get(ctx, ccService)
	if err != nil && !errors.Is(err, ErrNotFound) {
		return err
	}
	curOAuth, err := oauthAccountRaw(cfgPath)
	if err != nil {
		return err
	}
	curEmail := oauthEmail(curOAuth)
	s.logf("current identity: %s, credential %s", orUnknown(curEmail), redact(curCred))

	// Recovery: a leftover journal means a previous swap died mid-mutation,
	// so the config identity may not describe the live credential. Attribute
	// by credential hash instead — misattributing the backup upsert is how
	// an account's last good refresh token dies.
	curID := ""
	skipBackup := false
	if j, jerr := s.readJournal(ctx); jerr != nil {
		return jerr
	} else if j != nil {
		s.logf("incomplete swap found (started %s, %s → %s) — recovering",
			j.StartedAt.UTC().Format(time.RFC3339), j.FromID, j.ToID)
		if curCred != nil && credHash(curCred) != j.FromCredHash {
			// The keychain write of the dead swap landed: the live credential
			// is the TARGET's (possibly rotated since). Store it under its
			// true owner, preserving that owner's identity block.
			_, toOAuth, lerr := s.LoadBackup(ctx, j.ToID)
			if lerr != nil {
				toOAuth = nil
			}
			if err := s.SaveBackup(ctx, j.ToID, curCred, toOAuth); err != nil {
				return fmt.Errorf("recovery: backing up live credential under %q: %w", j.ToID, err)
			}
			s.logf("recovery: live credential attributed to %s by hash — backup updated", j.ToID)
			curID = j.ToID
			skipBackup = true
		} else {
			// Hash unchanged → the dead swap never wrote the keychain. Trust
			// the journal's attribution over the (editable) config identity.
			curID = j.FromID
			s.logf("recovery: live credential still belongs to %s (hash unchanged)", j.FromID)
		}
		if err := s.clearJournal(ctx); err != nil {
			return err
		}
	}

	if curID == "" {
		curID = s.matchAccountID(curEmail)
		if curID == "" {
			curID = "unmatched-" + sanitizeID(curEmail)
			if curCred != nil {
				s.logf("current account not in registry — backing up as %q", curID)
			}
		}
	}
	if curCred != nil && !skipBackup {
		if err := s.SaveBackup(ctx, curID, curCred, curOAuth); err != nil {
			return fmt.Errorf("backing up current account before swap: %w", err)
		}
		s.logf("backup saved: %s → %s/%s", orUnknown(curEmail), BackupService, curID)
	}

	// Re-load the target's backup UNDER the locks, AFTER journal recovery
	// (which may itself have rewritten backups[target] when the dead swap's
	// target was this one). Between the pre-lock existence check and here,
	// keep-warm — serialized by the backups lock we now hold — may have
	// rotated this backup; installing the pre-lock copy would install a dead
	// refresh-token lineage.
	targetCred, targetOAuth, err := s.LoadBackup(ctx, target.ID)
	if err != nil {
		if errors.Is(err, ErrNotFound) {
			return fmt.Errorf("account %q has no stored credential — run `llmpilot account add` while logged into it first", target.Label)
		}
		return err
	}

	// Journal BEFORE the mutation: if we die between the two writes, the
	// next swap recovers attribution from this record.
	if err := s.writeJournal(ctx, swapJournal{
		FromID:       curID,
		ToID:         target.ID,
		FromCredHash: credHash(curCred),
		StartedAt:    time.Now().UTC(),
	}); err != nil {
		return fmt.Errorf("writing swap journal: %w", err)
	}

	// Install the target credential, then splice the identity.
	if err := s.Keychain.Set(ctx, ccService, s.account(), targetCred); err != nil {
		_ = s.clearJournal(ctx) // nothing was written; pre-swap state intact
		return err
	}
	s.logf("credential installed: service %q, %s", ccService, redact(targetCred))
	if err := spliceOAuthAccount(cfgPath, targetOAuth); err != nil {
		return s.rollback(ctx, ccService, curCred, fmt.Errorf("oauthAccount splice failed: %w", err))
	}
	s.logf("oauthAccount spliced: %s → %s", orUnknown(curEmail), orUnknown(oauthEmail(targetOAuth)))

	// Verify both writes landed before declaring success.
	gotCred, err := s.Keychain.Get(ctx, ccService)
	if err != nil {
		return fmt.Errorf("verify: keychain read-back failed (swap journal kept for recovery): %w", err)
	}
	if !jsonEqual(gotCred, targetCred) {
		return errors.New("verify: keychain read-back does not match the installed credential (swap journal kept for recovery)")
	}
	gotOAuth, err := oauthAccountRaw(cfgPath)
	if err != nil {
		return fmt.Errorf("verify: config read-back failed (swap journal kept for recovery): %w", err)
	}
	if oauthEmail(gotOAuth) != oauthEmail(targetOAuth) {
		return errors.New("verify: config oauthAccount does not match the target identity (swap journal kept for recovery)")
	}
	if err := s.clearJournal(ctx); err != nil {
		return fmt.Errorf("swap landed but journal cleanup failed (next swap will self-recover): %w", err)
	}
	s.logf("verified: active identity is now %s", orUnknown(oauthEmail(gotOAuth)))
	return nil
}

// rollback restores the pre-swap credential after a mid-mutation failure.
// On success the pre-swap state is intact and the journal is cleared; on
// failure the journal stays so the next swap recovers attribution by hash.
func (s *Switcher) rollback(ctx context.Context, ccService string, curCred []byte, cause error) error {
	var restoreErr error
	if curCred != nil {
		restoreErr = s.Keychain.Set(ctx, ccService, s.account(), curCred)
	} else {
		restoreErr = s.Keychain.Delete(ctx, ccService, s.account())
	}
	if restoreErr != nil {
		return fmt.Errorf("%w; keychain rollback ALSO failed (%v) — swap journal kept, next swap self-recovers", cause, restoreErr)
	}
	_ = s.clearJournal(ctx)
	s.logf("rolled back: pre-swap credential restored")
	return fmt.Errorf("%w (config unchanged, keychain rolled back to the pre-swap credential)", cause)
}

// matchAccountID maps an email to a registered account ID ("" if none).
func (s *Switcher) matchAccountID(email string) string {
	if s.Registry == nil || email == "" {
		return ""
	}
	accs, err := s.Registry.Accounts()
	if err != nil {
		return ""
	}
	for _, a := range accs {
		if a.Email == email {
			return a.ID
		}
	}
	return ""
}

func oauthEmail(raw json.RawMessage) string {
	if raw == nil {
		return ""
	}
	var doc struct {
		EmailAddress string `json:"emailAddress"`
	}
	if json.Unmarshal(raw, &doc) != nil {
		return ""
	}
	return doc.EmailAddress
}

func orUnknown(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}

func sanitizeID(s string) string {
	out := make([]rune, 0, len(s))
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '.':
			out = append(out, r)
		default:
			out = append(out, '_')
		}
	}
	if len(out) == 0 {
		return "unknown"
	}
	return string(out)
}

// jsonEqual compares two payloads structurally when both parse as JSON,
// byte-wise otherwise.
func jsonEqual(a, b []byte) bool {
	var va, vb any
	if json.Unmarshal(a, &va) == nil && json.Unmarshal(b, &vb) == nil {
		ja, _ := json.Marshal(va)
		jb, _ := json.Marshal(vb)
		return string(ja) == string(jb)
	}
	return string(a) == string(b)
}
