package pilot

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

// AnchorTolerance absorbs legitimate clock corrections (NTP steps are seconds
// to minutes; comparisons are UTC so DST never applies) and the coarse write
// cadence below. It bounds how far a single backward jump reaches before the
// hold latches — too small to reclaim a meaningful slice of the 30-day grace
// or an 8-day trial in one step. It does NOT defend against sustained clock
// control (freezing or oscillating time below the high-water mark): a clock
// cannot be forced forward offline, so that case is the accepted offline
// floor, alongside patching a signed binary.
const AnchorTolerance = time.Hour

// anchorWriteEvery keeps the high-water mark from churning the disk on every
// license check; staleness up to this interval is inside AnchorTolerance.
const anchorWriteEvery = 10 * time.Minute

type anchorState struct {
	HWM time.Time `json:"hwm"`
	// Hold latches a detected rollback: once set, offline access stays off —
	// even after the clock recovers — until an online revalidate resets it.
	Hold bool `json:"hold"`
}

// TimeAnchor is the forward-only time high-water mark that makes clock
// rollback fail closed offline. The file carries timestamps only — never
// tokens or license identifiers.
type TimeAnchor struct {
	// Dir is $LLMPILOT_HOME; the anchor persists at Dir/time-anchor.json.
	Dir string

	mu     sync.Mutex
	loaded bool
	state  anchorState
}

func (a *TimeAnchor) path() string { return filepath.Join(a.Dir, "time-anchor.json") }

// load reads the persisted state once per process; a missing or unreadable
// file leaves the zero state, which Regressed treats as fail-closed.
func (a *TimeAnchor) load() {
	if a.loaded {
		return
	}
	a.loaded = true
	raw, err := os.ReadFile(a.path())
	if err != nil {
		return
	}
	var st anchorState
	if json.Unmarshal(raw, &st) != nil || st.HWM.IsZero() {
		return
	}
	a.state = st
}

func (a *TimeAnchor) persist() {
	// Best-effort: a failed write leaves the previous (older) mark, which can
	// only make Regressed stricter, never looser.
	_ = pilotapi.WriteJSONAtomic(a.path(), a.state)
}

// Observe advances the high-water mark. It never moves backwards, never
// creates a missing anchor (only Reset, on online proof, may — otherwise
// deleting the file and reopening the app would clear a rollback offline),
// and latches Hold the moment now falls more than AnchorTolerance behind.
func (a *TimeAnchor) Observe(now time.Time) {
	now = now.UTC()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.load()
	switch {
	case a.state.HWM.IsZero():
	case now.Before(a.state.HWM.Add(-AnchorTolerance)):
		if !a.state.Hold {
			a.state.Hold = true
			a.persist()
		}
	case now.After(a.state.HWM.Add(anchorWriteEvery)):
		a.state.HWM = now
		a.persist()
	}
}

// Regressed reports whether offline access must fail closed: a missing or
// unreadable anchor, a latched rollback, or now behind HWM − tolerance.
func (a *TimeAnchor) Regressed(now time.Time) bool {
	now = now.UTC()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.load()
	if a.state.HWM.IsZero() || a.state.Hold {
		return true
	}
	return now.Before(a.state.HWM.Add(-AnchorTolerance))
}

// Reset re-arms the anchor at now and clears any rollback latch. Callers
// invoke it ONLY after a successful online revalidation — the server answer
// is the one authority that can forgive a rollback.
func (a *TimeAnchor) Reset(now time.Time) {
	now = now.UTC()
	a.mu.Lock()
	defer a.mu.Unlock()
	a.load()
	a.state = anchorState{HWM: now}
	a.persist()
}
