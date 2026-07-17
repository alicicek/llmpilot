package pilotapi

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Store is the slice of llmpilot's state store the engine consumes.
// *store.Store satisfies it; the engine never learns about paths beyond
// Home() (its one state file, wake-armed.json, lives there).
type Store interface {
	Home() string
	Accounts() ([]Account, error)
	Snapshot(accountID string) (*UsageSnapshot, error)
	SaveSnapshot(snap *UsageSnapshot) error
	Schedules() ([]Schedule, error)
	AppendEvent(e Event) error
}

// WriteJSONAtomic writes via tempfile+rename in the target's directory so
// readers never observe a partial file. Files are 0600, directories 0700.
// It is the one write discipline for everything under $LLMPILOT_HOME.
func WriteJSONAtomic(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
