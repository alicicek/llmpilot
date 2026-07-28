package switcher

// Classify-outgoing: before a swap overwrites the live credential, decide
// whose it is — a registered account's (update that account's backup) or a
// stranger's (append-only stash, never a backup key it doesn't own). The
// pre-P2 fallback ("unmatched-<email>") clobbered: two no-email foreigners
// both landed on one key. Classification runs UNDER the same lock span as
// the mutation (a pre-lock read once cloned one grant into two copies).
//
// PRECEDENCE (the one rule that keeps a registered account alive): an
// oauthAccount identity/email match OUTRANKS a fingerprint miss. The
// fingerprint hashes the refresh token, which Claude Code rotates — the
// under-lock read routinely sees a rotated credential whose fingerprint is
// not yet in the index. Classifying it foreign would stash a registered
// account's live token instead of updating its backup.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// ErrStashConflict re-exports the shared sentinel (pilotapi) the daemon
// maps to a 409: adopt refused because the account already holds a backup
// of a DIFFERENT (newer) lineage.
var ErrStashConflict = pilotapi.ErrStashConflict

// StashKeyPrefix marks stash entries in the llmpilot-backups Keychain
// service: "stash-<sanitized fingerprint>". Registered accounts use acct-*
// keys, so the two namespaces cannot collide.
const StashKeyPrefix = "stash-"

// credIndexFile is the fingerprint index in $LLMPILOT_HOME: sha256
// fingerprints → backup/stash keys. It exists because the Keychain adapter
// enumerating items would cost N /usr/bin/security subprocesses inside a
// 10s-stale CC lock span. The Keychain holds payloads; the index locates
// them. It holds NO token material — fingerprints are hashes.
const credIndexFile = "credindex.json"

// indexEntry locates one known credential lineage.
type indexEntry struct {
	Kind      string    `json:"kind"` // "account" or "stash"
	Key       string    `json:"key"`  // account ID, or the stash Keychain account attr
	Label     string    `json:"label,omitempty"`
	StashedAt time.Time `json:"stashed_at,omitempty"`
}

// credIndex is the on-disk index document.
type credIndex struct {
	Version      int                   `json:"version"`
	Fingerprints map[string]indexEntry `json:"fingerprints"`
}

// StashEntry is one stashed foreign credential as surfaced to the API —
// metadata only, never the payload.
type StashEntry struct {
	Fingerprint string    `json:"fingerprint"`
	Key         string    `json:"key"`
	Label       string    `json:"label,omitempty"`
	StashedAt   time.Time `json:"stashed_at"`
}

func (s *Switcher) credIndexPath() (string, bool) {
	if s.Registry == nil {
		return "", false
	}
	return filepath.Join(s.Registry.Home(), credIndexFile), true
}

// loadCredIndex reads the index; a missing file is an empty index. Callers
// hold the backups lock — the index is part of the backups' state.
func (s *Switcher) loadCredIndex() (credIndex, error) {
	idx := credIndex{Version: 1, Fingerprints: map[string]indexEntry{}}
	path, ok := s.credIndexPath()
	if !ok {
		return idx, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return idx, nil
	}
	if err != nil {
		return idx, err
	}
	if err := json.Unmarshal(data, &idx); err != nil {
		return idx, fmt.Errorf("parse %s: %w", path, err)
	}
	if idx.Fingerprints == nil {
		idx.Fingerprints = map[string]indexEntry{}
	}
	return idx, nil
}

// saveCredIndex writes the index atomically (tempfile+rename — the same
// discipline every config write uses).
func (s *Switcher) saveCredIndex(idx credIndex) error {
	path, ok := s.credIndexPath()
	if !ok {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(path, append(data, '\n'), 0o600)
}

// indexBackup records fingerprint→account in the index. Called from
// SaveBackup, so it runs in the same lock span as every backup write.
func (s *Switcher) indexBackup(fp, accountID string) error {
	if fp == "" {
		return nil
	}
	if _, ok := s.credIndexPath(); !ok {
		return nil
	}
	idx, err := s.loadCredIndex()
	if err != nil {
		return err
	}
	if e, ok := idx.Fingerprints[fp]; ok && e.Kind == "account" && e.Key == accountID {
		return nil
	}
	idx.Fingerprints[fp] = indexEntry{Kind: "account", Key: accountID}
	return s.saveCredIndex(idx)
}

// resolveByFingerprint maps a credential to a registered account via the
// index — but only when that account's CURRENT backup carries the same
// fingerprint. A stale index entry (the backup rotated since) must never
// route a possibly-dead lineage over an account's good backup.
func (s *Switcher) resolveByFingerprint(ctx context.Context, cred []byte) string {
	fp := anthropic.CredFingerprint(cred)
	if fp == "" {
		return ""
	}
	idx, err := s.loadCredIndex()
	if err != nil {
		s.logf("classify: index unreadable (%v) — treating fingerprint as unknown", err)
		return ""
	}
	e, ok := idx.Fingerprints[fp]
	if !ok || e.Kind != "account" {
		return ""
	}
	backup, _, err := s.LoadBackup(ctx, e.Key)
	if err != nil || anthropic.CredFingerprint(backup) != fp {
		return ""
	}
	return e.Key
}

// stashPayload is what a stash entry stores in the Keychain — the same shape
// as a backup so adopt can promote it verbatim.
type stashPayload struct {
	Credential   json.RawMessage `json:"credential"`
	OAuthAccount json.RawMessage `json:"oauthAccount,omitempty"`
	StashedAt    time.Time       `json:"stashed_at"`
}

// stashForeign appends an unknown credential to the stash, keyed by its
// fingerprint. APPEND-ONLY: an existing entry for the fingerprint is never
// overwritten (a second stash of the same lineage appends nothing). Any
// failure here must abort the caller's swap — losing a stranger's only
// credential copy is the poisoning class this leg exists to close.
func (s *Switcher) stashForeign(ctx context.Context, cred, oauthRaw json.RawMessage) error {
	fp := anthropic.CredFingerprint(cred)
	if fp == "" {
		return errors.New("stash: credential has no fingerprint")
	}
	idx, err := s.loadCredIndex()
	if err != nil {
		return fmt.Errorf("stash: index unreadable: %w", err)
	}
	// Append-only applies to STASH entries. A stale kind=account entry (the
	// caller already found it unverifiable, or a legacy unmatched-* item is
	// being migrated) must not block preservation — it is replaced by the
	// stash entry; the payload write below is an upsert to the same key.
	if e, ok := idx.Fingerprints[fp]; ok && e.Kind == "stash" {
		s.logf("classify: foreign credential already stashed (fingerprint known) — nothing appended")
		return nil
	}
	key := StashKeyPrefix + sanitizeID(fp)
	payload, err := json.Marshal(stashPayload{
		Credential:   cred,
		OAuthAccount: oauthRaw,
		StashedAt:    time.Now().UTC(),
	})
	if err != nil {
		return err
	}
	if err := s.Keychain.Set(ctx, BackupService, key, payload); err != nil {
		return fmt.Errorf("stash write: %w", err)
	}
	label := oauthEmail(oauthRaw)
	idx.Fingerprints[fp] = indexEntry{Kind: "stash", Key: key, Label: label, StashedAt: time.Now().UTC()}
	if err := s.saveCredIndex(idx); err != nil {
		return fmt.Errorf("stash index write: %w", err)
	}
	s.logf("foreign credential stashed: %s → %s/%s", orUnknown(label), BackupService, key)
	return nil
}

// StashEntries lists the stashed credentials (metadata only) from the index.
func (s *Switcher) StashEntries() ([]StashEntry, error) {
	idx, err := s.loadCredIndex()
	if err != nil {
		return nil, err
	}
	out := []StashEntry{}
	for fp, e := range idx.Fingerprints {
		if e.Kind != "stash" {
			continue
		}
		out = append(out, StashEntry{Fingerprint: fp, Key: e.Key, Label: e.Label, StashedAt: e.StashedAt})
	}
	return out, nil
}

// LoadStash reads one stash entry's payload by fingerprint.
func (s *Switcher) LoadStash(ctx context.Context, fingerprint string) (stashPayload, error) {
	var p stashPayload
	idx, err := s.loadCredIndex()
	if err != nil {
		return p, err
	}
	e, ok := idx.Fingerprints[fingerprint]
	if !ok || e.Kind != "stash" {
		return p, fmt.Errorf("stash entry %q: %w", fingerprint, ErrNotFound)
	}
	raw, err := s.Keychain.GetAccount(ctx, BackupService, e.Key)
	if err != nil {
		return p, err
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return p, fmt.Errorf("stash entry %q: corrupt payload", fingerprint)
	}
	return p, nil
}

// DiscardStash removes a stash entry — payload and index entry — under the
// backups lock. Discard is the user-visible way out of append-only retention.
func (s *Switcher) DiscardStash(ctx context.Context, fingerprint string) error {
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return err
	}
	defer releaseLock(bl)
	idx, err := s.loadCredIndex()
	if err != nil {
		return err
	}
	e, ok := idx.Fingerprints[fingerprint]
	if !ok || e.Kind != "stash" {
		return fmt.Errorf("stash entry %q: %w", fingerprint, ErrNotFound)
	}
	if err := s.Keychain.Delete(ctx, BackupService, e.Key); err != nil {
		return err
	}
	delete(idx.Fingerprints, fingerprint)
	return s.saveCredIndex(idx)
}

// AdoptStash promotes a stashed credential into a registered,
// GLOBAL-SWAPPABLE account: the stash payload becomes the account's backup
// (SaveBackup re-indexes the fingerprint as an account in the same lock
// span) and the stash entry is retired. The caller (the daemon) refuses
// dead-lineage fingerprints BEFORE calling — adopt must never silently
// resurrect a quarantined lineage.
func (s *Switcher) AdoptStash(ctx context.Context, fingerprint, label string) (store.Account, error) {
	if s.Registry == nil {
		return store.Account{}, errors.New("adopt: no account registry")
	}
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return store.Account{}, err
	}
	defer releaseLock(bl)
	idx, err := s.loadCredIndex()
	if err != nil {
		return store.Account{}, err
	}
	e, ok := idx.Fingerprints[fingerprint]
	if !ok || e.Kind != "stash" {
		return store.Account{}, fmt.Errorf("stash entry %q: %w", fingerprint, ErrNotFound)
	}
	raw, err := s.Keychain.GetAccount(ctx, BackupService, e.Key)
	if err != nil {
		return store.Account{}, err
	}
	var p stashPayload
	if err := json.Unmarshal(raw, &p); err != nil {
		return store.Account{}, fmt.Errorf("stash entry %q: corrupt payload", fingerprint)
	}
	email := oauthEmail(p.OAuthAccount)
	id := ""
	if email != "" {
		id = s.matchAccountID(email) // a re-adopt lands on the registered account, never a fork
	}
	if id == "" {
		if email != "" {
			id = "acct-" + sanitizeID(strings.ToLower(email))
		} else {
			id = "acct-" + sanitizeID(fingerprint)
		}
	}
	// CAS (adversarial review P0): the target ID may already hold a backup of
	// a DIFFERENT lineage. Overwriting it would destroy the account's only
	// copy of that credential. Refuse — but the CAS proves only "different",
	// NOT which is newer (fix-delta review P2): usually the account was
	// re-logged-in after the stash was taken (backup newer, stash dead), but
	// the reverse is possible (this stash was misclassified from a registered
	// account). So the message must NOT prescribe discard — that would delete
	// the live credential in the reverse case. State the ambiguity; the safe
	// recovery in BOTH directions is to sign in to the account again.
	if existing, _, lerr := s.LoadBackup(ctx, id); lerr == nil {
		if anthropic.CredFingerprint(existing) != fingerprint {
			return store.Account{}, fmt.Errorf("%w: account %q already has a different sign-in stored — sign in to it again to keep whichever is current; discard this entry only if you know it is the stale one", ErrStashConflict, id)
		}
	} else if !errors.Is(lerr, ErrNotFound) {
		return store.Account{}, lerr
	}
	if label == "" {
		if email != "" {
			label = labelFromEmail(email)
		} else {
			label = "adopted"
		}
	}
	acct := store.Account{
		ID:              id,
		Label:           label,
		Email:           email,
		ConfigDir:       s.Dir.Path(),
		KeychainService: s.Dir.KeychainService(),
	}
	// Backup first (it also re-indexes the fingerprint), then register, then
	// retire the stash item — a crash mid-way leaves both copies readable,
	// never neither.
	if err := s.SaveBackup(ctx, id, p.Credential, p.OAuthAccount); err != nil {
		return store.Account{}, fmt.Errorf("adopting stash entry: %w", err)
	}
	if err := s.registerAccount(acct); err != nil {
		return store.Account{}, err
	}
	if err := s.Keychain.Delete(ctx, BackupService, e.Key); err != nil {
		s.logf("adopt: stash item cleanup failed (harmless duplicate remains): %v", err)
	}
	s.logf("stash entry adopted: %s registered as %s (global-swappable)", orUnknown(email), id)
	return acct, nil
}

// SweepLegacyUnmatched migrates pre-P2 "unmatched-<email>" backup items into
// the stash, one-time at daemon start. Nothing is silently dropped: every
// item is either stashed (and the legacy key removed) or reported. The real
// enumeration path (`security dump-keychain`, attribute-only) is exercised
// by the e2e against a throwaway keychain.
func (s *Switcher) SweepLegacyUnmatched(ctx context.Context) error {
	keys, err := s.Keychain.List(ctx, BackupService)
	if err != nil {
		return fmt.Errorf("legacy sweep: %w", err)
	}
	bl, err := s.acquireBackupsLock(ctx)
	if err != nil {
		return err
	}
	defer releaseLock(bl)
	for _, key := range keys {
		if len(key) <= len("unmatched-") || key[:len("unmatched-")] != "unmatched-" {
			continue
		}
		cred, oauthRaw, err := s.LoadBackup(ctx, key)
		if err != nil {
			s.logf("legacy sweep: %s unreadable (%v) — left in place", key, err)
			continue
		}
		if err := s.stashForeign(ctx, cred, oauthRaw); err != nil {
			return fmt.Errorf("legacy sweep: stashing %s: %w", key, err)
		}
		if err := s.Keychain.Delete(ctx, BackupService, key); err != nil {
			return fmt.Errorf("legacy sweep: removing migrated %s: %w", key, err)
		}
		s.logf("legacy sweep: %s migrated to the stash", key)
	}
	return nil
}
