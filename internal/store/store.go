// Package store owns llmpilot's on-disk state: the account registry and
// per-account usage snapshots under $LLMPILOT_HOME (default ~/.llmpilot).
// The data TYPES are defined in pilotapi (the engine, a separate module,
// consumes them and cannot import internal packages) and aliased here so
// every surface keeps reading store.Account et al. Cache files carry
// percentages and timestamps only — never tokens.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alicicek/llmpilot/pilotapi"
)

// The on-disk data contracts, defined once in pilotapi.
type (
	// Account is one registered Claude Code account.
	Account = pilotapi.Account
	// Bucket is one rate-limit bucket as reported by the usage endpoint.
	Bucket = pilotapi.Bucket
	// UsageSnapshot is one account's buckets as of a moment.
	UsageSnapshot = pilotapi.UsageSnapshot
)

// Store reads and writes llmpilot state under one home directory.
type Store struct {
	home string
}

// Open resolves the store home from $LLMPILOT_HOME, defaulting to ~/.llmpilot.
func Open() (*Store, error) {
	if h := os.Getenv("LLMPILOT_HOME"); h != "" {
		return &Store{home: h}, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home dir: %w", err)
	}
	return &Store{home: filepath.Join(home, ".llmpilot")}, nil
}

// At returns a Store rooted at an explicit directory (tests, sandboxes).
func At(dir string) *Store { return &Store{home: dir} }

// Home is the directory this store reads and writes under.
func (s *Store) Home() string { return s.home }

func (s *Store) accountsPath() string { return filepath.Join(s.home, "accounts.json") }

// Accounts loads the account registry. A missing file is an empty registry.
func (s *Store) Accounts() ([]Account, error) {
	data, err := os.ReadFile(s.accountsPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var accs []Account
	if err := json.Unmarshal(data, &accs); err != nil {
		return nil, fmt.Errorf("parse %s: %w", s.accountsPath(), err)
	}
	return accs, nil
}

// SaveAccounts writes the account registry atomically.
func (s *Store) SaveAccounts(accs []Account) error {
	return WriteJSONAtomic(s.accountsPath(), accs)
}

func validateID(id string) error { return pilotapi.ValidateID(id) }

func (s *Store) snapshotPath(accountID string) (string, error) {
	if err := validateID(accountID); err != nil {
		return "", err
	}
	return filepath.Join(s.home, "cache", "usage-"+accountID+".json"), nil
}

// AnalyticsCachePath is where one account's analytics per-file cache lives.
func (s *Store) AnalyticsCachePath(accountID string) (string, error) {
	if err := validateID(accountID); err != nil {
		return "", err
	}
	return filepath.Join(s.home, "cache", "analytics-"+accountID+".json"), nil
}

// Snapshot loads the cached usage snapshot for an account, nil if none cached.
func (s *Store) Snapshot(accountID string) (*UsageSnapshot, error) {
	path, err := s.snapshotPath(accountID)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var snap UsageSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &snap, nil
}

// SaveSnapshot writes an account's usage snapshot atomically.
func (s *Store) SaveSnapshot(snap *UsageSnapshot) error {
	path, err := s.snapshotPath(snap.AccountID)
	if err != nil {
		return err
	}
	return WriteJSONAtomic(path, snap)
}

// WriteJSONAtomic is the one write discipline for everything under
// $LLMPILOT_HOME (tempfile+rename, 0600/0700); implementation in pilotapi.
func WriteJSONAtomic(path string, v any) error { return pilotapi.WriteJSONAtomic(path, v) }
