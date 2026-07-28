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
		// every account forever (re-review). Move it aside and start empty:
		// with no records, the clone guard excludes NO dir from its scan,
		// which is the conservative direction.
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
	// The mark is DERIVED from the dir records on every write: an account is
	// clone-suspect exactly while one of its retirements is unproven. So a
	// later move that does prove that dir empty clears the mark, while a mark
	// set by a DIFFERENT dir survives (it has its own unproven record).
	if rec.AccountID != "" {
		suspect := false
		for _, d := range r.Dirs {
			if d.AccountID == rec.AccountID && !d.Complete {
				suspect = true
				break
			}
		}
		if suspect {
			r.CloneSuspect = appendUnique(r.CloneSuspect, rec.AccountID)
		} else {
			r.CloneSuspect = without(r.CloneSuspect, rec.AccountID)
		}
	}
	return s.SaveRetirements(r)
}

// RetiredDirs returns the config dirs whose retirement completed. NOTE for
// callers: completion is a fact about the MOMENT of the move — a later
// sign-in can refill the dir — so the clone guard pairs this with a
// "nothing has written the dir since" check rather than trusting it forever.
func (s *Store) RetiredDirs() (map[string]bool, error) {
	r, err := s.Retirements()
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	for _, d := range r.Dirs {
		if d.Complete {
			out[strings.ToLower(filepath.Clean(d.ConfigDir))] = true
		}
	}
	return out, nil
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
