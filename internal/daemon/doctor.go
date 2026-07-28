package daemon

// GET /v1/doctor — the read-only health sweep. The daemon owns the facts only
// it can know (its in-memory stale map, its token notes, its quarantine, the
// stash it serves) and injects everything that touches the filesystem or the
// Keychain, exactly like Detect/Adopt/Move. The CHECKS themselves live in
// internal/doctor and are shared with the CLI: two lists would drift, and then
// the terminal and the cockpit would disagree about whether the fleet is
// healthy.

import (
	"context"
	"net/http"
	"time"

	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// DoctorLocal carries the health-sweep readers the daemon cannot build
// itself — llmpilot's own credential store, the other Claude folders on this
// Mac, the refresh budget and the install. Every field is a READ: the sweep
// writes nothing, locks nothing and refreshes nothing. A nil field is not an
// excuse to guess; the checks that need it report NOT CHECKED.
type DoctorLocal struct {
	Backups doctor.Keychain
	Foreign func(ctx context.Context) ([]switcher.ForeignSignIn, error)
	Budget  func() (switcher.BudgetSnapshot, error)
	Install func() (doctor.InstallFacts, error)
	// SetupTokens reads the stored headless-token records — metadata only,
	// never the token Keychain service.
	SetupTokens func() ([]setuptoken.Meta, error)
}

// DoctorInputs assembles the sweep's readers. ONE assembler for both callers:
// the daemon's own endpoint adds its live facts on top, and the CLI's
// daemon-down fallback leaves Daemon nil so every daemon-only check reports
// NOT CHECKED instead of quietly claiming an empty map means "nothing wrong".
func DoctorInputs(
	st *store.Store,
	pinned func(store.Account) bool,
	movedDirs func(ctx context.Context) (map[string]bool, error),
	local DoctorLocal,
	now func() time.Time,
) doctor.Inputs {
	return doctor.Inputs{
		Now:         now,
		Accounts:    st.Accounts,
		Snapshot:    st.Snapshot,
		Retirements: st.RetirementsSnapshot,
		Pinned:      pinned,
		MovedDirs:   movedDirs,
		Backups:     local.Backups,
		Foreign:     local.Foreign,
		Budget:      local.Budget,
		Install:     local.Install,
		SetupTokens: local.SetupTokens,
	}
}

// Doctor runs the sweep against this daemon's live view.
func (d *Daemon) Doctor(ctx context.Context) doctor.Report {
	d.init()
	in := DoctorInputs(d.Store, d.Pinned, d.MovedDirs, d.DoctorReaders, d.clock)
	in.Daemon = d.doctorFacts(ctx)
	return doctor.Run(ctx, in)
}

func (d *Daemon) clock() time.Time {
	if d.NowFn != nil {
		return d.NowFn()
	}
	return time.Now()
}

// doctorFacts snapshots what only a live daemon holds. Fingerprints ride the
// stash entries so dead lineages can be counted; nothing in this struct
// reaches a finding except as a count and a label.
func (d *Daemon) doctorFacts(ctx context.Context) *doctor.DaemonFacts {
	f := &doctor.DaemonFacts{
		Stale:       map[string]bool{},
		TokenNote:   map[string]string{},
		Quarantined: map[string]bool{},
		Stash:       []pilotapi.StashEntry{},
	}
	d.mu.Lock()
	for id := range d.stale {
		f.Stale[id] = true
	}
	for id, note := range d.tokenNotes {
		f.TokenNote[id] = note
	}
	for id := range d.quarantine {
		f.Quarantined[id] = true
	}
	d.mu.Unlock()
	if d.StashList == nil {
		// An empty list would read as "nothing was kept" — and a kept sign-in
		// the token endpoint has rejected would vanish into an all-clear.
		f.StashErr = "llmpilot's store of kept sign-ins is not wired in this build, so it could not be checked"
		return f
	}
	entries, err := d.StashList(ctx)
	if err != nil {
		d.Log.Warn("doctor: read stash", "err", err)
		f.StashErr = "llmpilot could not read the sign-ins it kept from switching"
		return f
	}
	for _, e := range entries {
		// IsLineageDead takes d.mu itself — call it outside the span above.
		e.Dead = d.IsLineageDead(e.Fingerprint)
		f.Stash = append(f.Stash, e)
	}
	return f
}

// handleDoctor serves the sweep. Unguarded like GET /v1/state: the same class
// of data (account labels and folder paths, never a secret), and the doctor
// adds no mutation to guard.
func (d *Daemon) handleDoctor(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, d.Doctor(r.Context()))
}
