package store

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

// Event is one line in the append-only event log at $LLMPILOT_HOME/
// events.jsonl; defined in pilotapi (the engine appends them), aliased here.
type Event = pilotapi.Event

func (s *Store) eventsPath() string { return filepath.Join(s.home, "events.jsonl") }

// AppendEvent appends one event line. A single O_APPEND write keeps
// concurrent writers (daemon + a schedule-fire process) line-atomic.
func (s *Store) AppendEvent(e Event) error {
	if e.At.IsZero() {
		e.At = time.Now().UTC()
	}
	data, err := json.Marshal(e)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(s.home, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(s.eventsPath(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(append(data, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// Events returns the last n events, oldest first. A missing file is an empty
// log; corrupt lines are skipped, never fatal.
func (s *Store) Events(n int) ([]Event, error) {
	f, err := os.Open(s.eventsPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	var evs []Event
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var e Event
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.Kind != "" {
			evs = append(evs, e)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if n > 0 && len(evs) > n {
		evs = evs[len(evs)-n:]
	}
	return evs, nil
}
