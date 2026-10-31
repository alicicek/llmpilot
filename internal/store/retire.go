package store

// Retirement records: llmpilot's own memory of the "Move into the fleet"
// migration. A move copies a sign-in out of a foreign config dir into
// llmpilot's backups, registers it as a swappable account, and DELETES the
// source copy. The source dir's .claude.json oauthAccount block is left
// alone on purpose (a splice bypass over a foreign dir's live identity is
// destructive surface for no gain), so that dir keeps LOOKING logged in.
// This file is how llmpilot tells the truth about it afterwards without
// reading a Keychain item outside the fleet — no ACL prompt, ever.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// RetiredDir is one config dir whose sign-in was moved into the fleet.
// Complete=false means the retirement could not prove the source copy was
// gone: the account is clone-suspect and the keep-warm guard refuses to
// rotate it until a human resolves it.
type RetiredDir struct {
	ConfigDir string    `json:"config_dir"`
	Email     string    `json:"email"`
	AccountID string    `json:"account_id"`
	RetiredAt time.Time `json:"retired_at"`
	Complete  bool      `json:"complete"`
}

// Retirements is the whole on-disk document. CloneSuspect is keyed by
// account ID (not dir): the mark travels with the account whose lineage may
// exist twice, which is what the rotation guard needs to check.
type Retirements struct {
	Version      int          `json:"version"`
	Dirs         []RetiredDir `json:"dirs"`
	CloneSuspect []string     `json:"clone_suspect"`
}

func (s *Store) retirementsPath() string { return filepath.Join(s.home, "retirements.json") }

// ErrRecordUnreadable marks a record that would not parse, returned by the
// READ-ONLY reader below. Retirements() turns this into a rebuild; callers
// that must not write (the doctor) get it as-is.
var ErrRecordUnreadable = errors.New("retirement record unreadable")

// RetirementsSnapshot reads the record WITHOUT the rebuild: no rename, no
// write, nothing touched. Retirements() quarantines an unreadable document so
// the engine can keep working, which is a write — and a diagnostic that
// mutates what it diagnoses is not a diagnostic. A corrupt
// document answers (empty record, ErrRecordUnreadable) so the caller can say
// so out loud instead of reporting an empty record as the truth.
func (s *Store) RetirementsSnapshot() (Retirements, error) {
	r := Retirements{Version: 1}
	data, err := os.ReadFile(s.retirementsPath())
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(data, &r); err != nil {
		return Retirements{Version: 1}, fmt.Errorf("%w: %v", ErrRecordUnreadable, err)
	}
	return r, nil
}

// Retirements loads the record; a missing file is an empty record.
func (s *Store) Retirements() (Retirements, error) {
	r := Retirements{Version: 1}
	data, err := os.ReadFile(s.retirementsPath())
	if errors.Is(err, os.ErrNotExist) {
		return r, nil
	}
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal(data, &r); err != nil {
		// This document holds no credentials — only paths, emails and flags —
		// so it is reconstructible, and an unreadable one must not freeze
		// every account forever (re-review). Move it aside and start empty.
		// Its clone-suspect marks go with it, so a leftover copy from an
		// unfinished move may then be refreshed and need a fresh sign-in —
		// the cost accepted for a fleet that never freezes (owner 2026-10-31).
		aside := fmt.Sprintf("%s.corrupt-%d", s.retirementsPath(), time.Now().UnixNano())
		if rerr := os.Rename(s.retirementsPath(), aside); rerr != nil {
			// Someone else quarantined it first (or it vanished): the document
			// is gone either way, so continue on the empty one — but do not
			// name a file this process never created.
			if !errors.Is(rerr, os.ErrNotExist) {
				return Retirements{Version: 1}, err
			}
			return Retirements{Version: 1}, fmt.Errorf("%w: the retirement record was unreadable and has been replaced — llmpilot rebuilt it empty", ErrRecordRebuilt)
		}
		return Retirements{Version: 1}, fmt.Errorf("%w: the retirement record was unreadable and was moved to %s — llmpilot rebuilt it empty", ErrRecordRebuilt, aside)
	}
	return r, nil
}

// ErrRecordRebuilt marks a Retirements() call that found the document corrupt
// and rebuilt it empty. Callers get an EMPTY record plus this error so they
// can log it honestly; it is not a reason to refuse work.
var ErrRecordRebuilt = errors.New("retirement record rebuilt")

// SaveRetirements writes the record atomically.
func (s *Store) SaveRetirements(r Retirements) error {
	r.Version = 1
	return WriteJSONAtomic(s.retirementsPath(), r)
}

// RecordRetirement upserts one dir's retirement (keyed by config dir) and,
// when the retirement could not be proven complete, marks the account
// clone-suspect. Both facts land in ONE write so a crash can never leave a
// retired dir without its mark.
func (s *Store) RecordRetirement(rec RetiredDir) error {
	r, err := s.Retirements()
	if errors.Is(err, ErrRecordRebuilt) {
		err = nil // rebuilt empty and authoritative — record onto the fresh document
	}
	if err != nil {
		return err
	}
	if rec.RetiredAt.IsZero() {
		rec.RetiredAt = time.Now().UTC()
	}
	replaced := false
	for i, d := range r.Dirs {
		if sameDirPath(d.ConfigDir, rec.ConfigDir) {
			r.Dirs[i] = rec
			replaced = true
			break
		}
	}
	if !replaced {
		r.Dirs = append(r.Dirs, rec)
	}
	rederiveMark(&r, rec.AccountID)
	return s.SaveRetirements(r)
}

// rederiveMark recomputes one account's clone-suspect mark from the dir
// records. The mark is DERIVED on every write: an account is clone-suspect
// exactly while one of its retirements is unproven. So a later move that
// does prove that dir empty clears the mark, while a mark set by a
// DIFFERENT dir survives (it has its own unproven record).
func rederiveMark(r *Retirements, accountID string) {
	if accountID == "" {
		return
	}
	for _, d := range r.Dirs {
		if d.AccountID == accountID && !d.Complete {
			r.CloneSuspect = appendUnique(r.CloneSuspect, accountID)
			return
		}
	}
	r.CloneSuspect = without(r.CloneSuspect, accountID)
}

// BeginRetirement records a move of rec's dir as UNFINISHED — marking its
// account clone-suspect — before the move registers the account and makes
// it refreshable: until the source is proven empty two copies of the
// lineage exist, and a mark saved only afterwards could be lost to a failed
// write while both copies live. Returns how to put the dir's previous
// record back if the move rolls back.
func (s *Store) BeginRetirement(rec RetiredDir) (undo func() error, err error) {
	r, err := s.Retirements()
	if errors.Is(err, ErrRecordRebuilt) {
		err = nil
	}
	if err != nil {
		return nil, err
	}
	var prior *RetiredDir
	for _, d := range r.Dirs {
		if sameDirPath(d.ConfigDir, rec.ConfigDir) {
			d := d
			prior = &d
			break
		}
	}
	rec.Complete = false
	if err := s.RecordRetirement(rec); err != nil {
		return nil, err
	}
	return func() error { return s.restoreRetirement(rec, prior) }, nil
}

// restoreRetirement puts a dir's record back to what it was before
// BeginRetirement (none, or prior) and re-derives the marks it touched.
func (s *Store) restoreRetirement(rec RetiredDir, prior *RetiredDir) error {
	r, err := s.Retirements()
	if errors.Is(err, ErrRecordRebuilt) {
		err = nil
	}
	if err != nil {
		return err
	}
	kept := r.Dirs[:0]
	for _, d := range r.Dirs {
		if !sameDirPath(d.ConfigDir, rec.ConfigDir) {
			kept = append(kept, d)
		}
	}
	r.Dirs = kept
	rederiveMark(&r, rec.AccountID)
	if prior != nil {
		r.Dirs = append(r.Dirs, *prior)
		rederiveMark(&r, prior.AccountID)
	}
	return s.SaveRetirements(r)
}

// IsCloneSuspect reports whether an account's lineage may exist in a second
// live copy (a partial retirement). Such an account is never rotated.
func (s *Store) IsCloneSuspect(accountID string) (bool, error) {
	r, err := s.Retirements()
	if errors.Is(err, ErrRecordRebuilt) {
		err = nil // the record is empty and authoritative again
	}
	if err != nil {
		return false, err
	}
	for _, id := range r.CloneSuspect {
		if id == accountID {
			return true, nil
		}
	}
	return false, nil
}

func without(list []string, v string) []string {
	out := list[:0]
	for _, s := range list {
		if s != v {
			out = append(out, s)
		}
	}
	return out
}

func appendUnique(list []string, v string) []string {
	for _, s := range list {
		if s == v {
			return list
		}
	}
	return append(list, v)
}

// sameDirPath compares config dir paths the way the rest of llmpilot does:
// cleaned and case-folded (the default APFS volume is case-insensitive).
func sameDirPath(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}
