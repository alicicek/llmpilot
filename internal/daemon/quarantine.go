package daemon

// Persisted quarantine: a provably dead refresh-token lineage must stay
// quarantined across daemon restarts — a launchd bounce that forgot the
// quarantine would let autopilot re-nominate the dead account and a stash
// adopt silently resurrect a dead lineage. Fingerprint-keyed on disk (the
// stash is fingerprint-keyed too, so adopt can ask "is THIS lineage dead"
// before any account ID exists). The in-memory account-ID map keeps its
// pre-P2 shape and clear-on-active behavior; this file is its durable twin.
// No token material — fingerprints are hashes (the cache rule).

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

const quarantineFile = "quarantine.json"

type quarantineEntry struct {
	AccountID string    `json:"account_id"`
	At        time.Time `json:"at"`
}

type quarantineDoc struct {
	Version int                        `json:"version"`
	Dead    map[string]quarantineEntry `json:"dead"` // fingerprint → entry
}

func (d *Daemon) quarantinePath() string {
	if d.Store == nil {
		return ""
	}
	return filepath.Join(d.Store.Home(), quarantineFile)
}

// loadQuarantine restores the in-memory map at init. Errors are logged, not
// fatal — an unreadable file degrades to the pre-P2 in-memory behavior.
func (d *Daemon) loadQuarantine() {
	path := d.quarantinePath()
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err != nil {
		d.Log.Warn("quarantine file unreadable", "err", err)
		return
	}
	var doc quarantineDoc
	if err := json.Unmarshal(data, &doc); err != nil {
		d.Log.Warn("quarantine file corrupt — starting empty", "err", err)
		return
	}
	d.mu.Lock()
	for fp, e := range doc.Dead {
		if e.AccountID != "" {
			d.quarantine[e.AccountID] = fp
			d.tokenNotes[e.AccountID] = deadLineageNote
		}
	}
	d.mu.Unlock()
}

// persistQuarantine writes the current map. Caller must NOT hold d.mu.
// Best-effort: a write failure keeps the in-memory truth and logs.
//
// Serialized through quarantinePersistMu across the WHOLE snapshot+rename
// (Codex review P2, 2026-07-25): two concurrent discoveries — or a discovery
// racing a lift — each snapshot d.quarantine under d.mu but write after
// releasing it, so without this an older snapshot could rename AFTER a newer
// one and silently drop a quarantine, re-enabling polling/nomination of a
// dead account after restart.
func (d *Daemon) persistQuarantine() {
	path := d.quarantinePath()
	if path == "" {
		return
	}
	d.quarantinePersistMu.Lock()
	defer d.quarantinePersistMu.Unlock()
	doc := quarantineDoc{Version: 1, Dead: map[string]quarantineEntry{}}
	// Preserve prior entries' timestamps where the lineage is unchanged.
	if data, err := os.ReadFile(path); err == nil {
		var old quarantineDoc
		if json.Unmarshal(data, &old) == nil {
			for fp, e := range old.Dead {
				doc.Dead[fp] = e
			}
		}
	}
	d.mu.Lock()
	live := map[string]quarantineEntry{}
	for id, fp := range d.quarantine {
		if prev, ok := doc.Dead[fp]; ok {
			live[fp] = prev
			continue
		}
		live[fp] = quarantineEntry{AccountID: id, At: time.Now().UTC()}
	}
	d.mu.Unlock()
	doc.Dead = live
	data, err := json.Marshal(doc)
	if err != nil {
		d.Log.Warn("quarantine marshal", "err", err)
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), quarantineFile+".tmp-*")
	if err != nil {
		d.Log.Warn("quarantine persist", "err", err)
		return
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(data); err == nil {
		if err := tmp.Chmod(0o600); err == nil {
			if err := tmp.Close(); err == nil {
				if err := os.Rename(tmp.Name(), path); err != nil {
					d.Log.Warn("quarantine persist", "err", err)
				}
				return
			}
		}
	}
	_ = tmp.Close()
	d.Log.Warn("quarantine persist failed")
}

// IsLineageDead reports whether a credential fingerprint belongs to a
// quarantined (provably dead) lineage — the adopt path's guard against
// silently resurrecting one.
func (d *Daemon) IsLineageDead(fingerprint string) bool {
	if fingerprint == "" {
		return false
	}
	d.init()
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, fp := range d.quarantine {
		if fp == fingerprint {
			return true
		}
	}
	return false
}
