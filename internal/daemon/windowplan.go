package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// Window plans start an account's next 5-hour window at its reset: Rolling
// for every reset, NextAt for one (the board's one-tap). The daemon fires
// them itself — a launchd job per start would put up a "can run in the
// background" notice every five hours — through the engine's guarded
// trigger (identity check, cannot-shift rule).

const (
	// planRetryFirst is the wait before retrying a start that did not open
	// a window (the usage endpoint lagging the reset, a failed run); each
	// further miss doubles it, up to planRetryMax, so a stuck account writes
	// a handful of events an hour, not one a minute.
	planRetryFirst = 2 * time.Minute
	planRetryMax   = time.Hour
	// planHoldAhead is how early before a planned start the daemon keeps the
	// Mac awake: the wake fires pilotapi.Lead ahead, and an idle Mac could
	// fall back asleep before the reset.
	planHoldAhead = 3 * time.Minute
	// planFiredHold is how long a start that fired keeps the account from
	// starting again: the window it opened runs five hours, and a usage
	// check that lags (or is rate-limited) must not read as "still closed".
	planFiredHold = 5*time.Hour - 10*time.Minute
	// oneTapExpiry drops a one-tap that could not fire near its time (the
	// folder was signed in to another account): days later is not "the
	// next window" any more.
	oneTapExpiry = 2 * time.Hour
	// planLagGrace is how long polls after a fire may still see no window
	// before the hold lets go: a lagging usage check lasts minutes, not hours.
	planLagGrace = 30 * time.Minute
	// planLicenceTTL caches the licence answer for the start loop: reading
	// it is a Keychain lookup, and a refused licence would otherwise be asked
	// every second.
	planLicenceTTL = time.Minute
	// planRetryHold keeps the Mac awake through the first retries after a
	// start — right after a scheduled wake the network is often not up yet.
	planRetryHold = 4 * time.Minute
)

// planTry is the start bookkeeping for one account. It lives as long as
// the daemon: a plan change resets its waits in place and never drops a
// start still running.
//
// Every time here is a WALL-clock time (Round(0) strips Go's monotonic
// reading): the monotonic clock stops while the Mac sleeps, and a hold
// counted in awake time would block the next morning's start.
type planTry struct {
	inFlight   bool
	lastAt     time.Time
	wait       time.Duration
	firedAt    time.Time
	firedUntil time.Time
}

// planTryLocked returns the account's bookkeeping, creating it; d.mu held.
func (d *Daemon) planTryLocked(accountID string) *planTry {
	if d.planTries == nil {
		d.planTries = map[string]*planTry{}
	}
	try := d.planTries[accountID]
	if try == nil {
		try = &planTry{}
		d.planTries[accountID] = try
	}
	return try
}

// startPlanned fires every window plan whose start is due. Called from the
// one-second loop; the trigger itself runs off the loop. The licence is read
// only when a start is actually due — it costs a Keychain read — so a fleet
// with no plans, or none due, does no work at all.
func (d *Daemon) startPlanned(ctx context.Context, now time.Time) {
	if d.StartWindow == nil {
		return
	}
	plans, err := d.Store.WindowPlans()
	if err != nil || len(plans) == 0 {
		return
	}
	accs, err := d.Store.Accounts()
	if err != nil {
		return
	}
	byID := map[string]store.Account{}
	for _, a := range accs {
		byID[a.ID] = a
	}
	var holdUntil time.Time
	type due struct {
		acct store.Account
		plan pilotapi.WindowPlan
	}
	var dues []due
	for _, p := range plans {
		acct, ok := byID[p.AccountID]
		if !ok {
			continue
		}
		if !p.Rolling && p.NextAt != nil && now.Sub(*p.NextAt) > oneTapExpiry {
			if d.dropOneTap(p.AccountID, *p.NextAt) {
				// Say why the start never came, where the user looks.
				msg := fmt.Sprintf("the %s start for %s did not happen — Claude Code wasn't signed in to it then", p.NextAt.Local().Format("15:04"), acct.Label)
				if err := d.Store.AppendEvent(store.Event{Kind: "trigger_skipped", AccountID: acct.ID, Message: msg}); err != nil {
					d.Log.Warn("append event", "err", err)
				}
				d.notify(ctx)
			}
			continue
		}
		snap, _ := d.Store.Snapshot(p.AccountID)
		at, ok := pilotapi.PlannedStart(now, p, snap)
		if !ok {
			continue
		}
		if now.Before(at) {
			if at.Sub(now) <= planHoldAhead && at.After(holdUntil) {
				holdUntil = at
			}
			continue
		}
		// A shared folder signed in to another account cannot start this
		// one's window: wait quietly until it is the one signed in.
		if d.CanStart != nil && !d.CanStart(acct) {
			continue
		}
		d.mu.Lock()
		try := d.planTryLocked(p.AccountID)
		blocked := try.inFlight || d.firedHoldLocked(try, snap, now) ||
			(!try.lastAt.IsZero() && now.Sub(try.lastAt) < try.wait)
		// Retries soon after a start keep the Mac awake for them too.
		if blocked && !try.inFlight && try.wait > 0 && try.wait <= planRetryHold {
			if until := try.lastAt.Add(try.wait); until.After(holdUntil) {
				holdUntil = until
			}
		}
		d.mu.Unlock()
		if !blocked {
			dues = append(dues, due{acct, p})
		}
	}
	if !holdUntil.IsZero() && d.HoldAwake != nil {
		d.holdAwakeUntil(holdUntil.Add(time.Minute))
	}
	if len(dues) == 0 || !d.planLicensed(now) {
		return
	}
	for _, s := range dues {
		d.mu.Lock()
		try := d.planTryLocked(s.acct.ID)
		if try.inFlight {
			d.mu.Unlock()
			continue
		}
		try.inFlight = true
		try.lastAt = now.Round(0)
		d.mu.Unlock()
		go d.runPlannedStart(ctx, s.acct, s.plan)
	}
}

// firedHoldLocked reports whether a start that fired still holds the
// account. It holds until its time runs out — unless a poll since the fire
// says otherwise: a window that has reset since (the next one is due), or
// still no window after planLagGrace (the start did not open one). d.mu held.
func (d *Daemon) firedHoldLocked(try *planTry, snap *store.UsageSnapshot, now time.Time) bool {
	if !now.Before(try.firedUntil) {
		return false
	}
	if snap == nil || !snap.AsOf.After(try.firedAt) {
		return true // nothing heard since the fire
	}
	for _, b := range snap.Buckets {
		if (b.Kind == "session" || b.Kind == "five_hour") && b.ResetsAt != nil && b.ResetsAt.After(try.firedAt) {
			return false // the window the fire opened has reset
		}
	}
	return now.Sub(try.firedAt) < planLagGrace
}

// planLicensed is the start loop's licence answer, cached for a minute.
func (d *Daemon) planLicensed(now time.Time) bool {
	if d.EntitlementAllowed == nil {
		return true
	}
	d.mu.Lock()
	if !d.planLicenceAt.IsZero() && now.Sub(d.planLicenceAt) < planLicenceTTL {
		ok := d.planLicenceOK
		d.mu.Unlock()
		return ok
	}
	d.mu.Unlock()
	ok := d.EntitlementAllowed("scheduling", now)
	d.mu.Lock()
	d.planLicenceAt, d.planLicenceOK = now.Round(0), ok
	d.mu.Unlock()
	return ok
}

// runPlannedStart fires one plan's start and settles its bookkeeping from
// what the engine says it did — never from a usage snapshot that may lag.
func (d *Daemon) runPlannedStart(ctx context.Context, acct store.Account, p pilotapi.WindowPlan) {
	why := "one-tap"
	if p.Rolling {
		why = "rolling"
	}
	startedAt := time.Now().Round(0)
	outcome, err := d.StartWindow(ctx, acct.ID, why)
	fired := err == nil && outcome == pilotapi.StartFired

	d.mu.Lock()
	try := d.planTryLocked(acct.ID)
	try.inFlight = false
	if fired {
		try.wait = 0
		try.lastAt = time.Time{}
		// From the moment it started: the engine's own poll right after the
		// fire then counts as news since it.
		try.firedAt = startedAt
		try.firedUntil = startedAt.Add(planFiredHold)
	} else if try.wait == 0 {
		try.wait = planRetryFirst
	} else if try.wait *= 2; try.wait > planRetryMax {
		try.wait = planRetryMax
	}
	d.mu.Unlock()

	if err != nil {
		d.Log.Warn("planned window start", "account", acct.ID, "why", why, "err", err)
	}
	if fired && !p.Rolling && p.NextAt != nil {
		d.dropOneTap(acct.ID, *p.NextAt)
	}
	d.afterScheduleMutation(ctx)
}

// dropOneTap clears an account's one-tap — only if it is still the one at
// `at`: the user may have set another meanwhile. Reports whether it did.
func (d *Daemon) dropOneTap(accountID string, at time.Time) bool {
	d.planMu.Lock()
	defer d.planMu.Unlock()
	cur, err := d.Store.WindowPlanFor(accountID)
	if err != nil || cur.Rolling || cur.NextAt == nil || !cur.NextAt.Equal(at) {
		return false
	}
	cur.NextAt = nil
	if err := d.Store.SetWindowPlan(cur); err != nil {
		d.Log.Warn("clear one-tap start", "account", accountID, "err", err)
		return false
	}
	return true
}

// holdAwakeUntil keeps the Mac awake until t, extending (never repeating)
// an earlier hold.
func (d *Daemon) holdAwakeUntil(t time.Time) {
	d.mu.Lock()
	if !t.After(d.heldUntil) {
		d.mu.Unlock()
		return
	}
	d.heldUntil = t
	d.mu.Unlock()
	d.HoldAwake(time.Until(t))
}

// handleWindowPlanSet stores one account's window plan:
// {"account_id", "rolling": bool, "next_at": RFC3339 | null}. Rolling pauses
// the account's fixed daily times (launchd jobs removed, schedules kept);
// switching it off brings them back.
func (d *Daemon) handleWindowPlanSet(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		AccountID string     `json:"account_id"`
		Rolling   bool       `json:"rolling"`
		NextAt    *time.Time `json:"next_at"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"account_id","rolling","next_at?"}`))
		return
	}
	// Switching a plan OFF needs no licence: after a trial ends, the user
	// must still be able to stop what they set up.
	if (req.Rolling || req.NextAt != nil) && d.schedulingBlocked(w) {
		return
	}
	accs, err := d.Store.Accounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	found := false
	for _, a := range accs {
		if a.ID == req.AccountID {
			found = true
			break
		}
	}
	if !found {
		httpError(w, http.StatusNotFound, fmt.Errorf("no account %q", req.AccountID))
		return
	}
	plan := pilotapi.WindowPlan{AccountID: req.AccountID, Rolling: req.Rolling, NextAt: req.NextAt}
	if plan.Rolling {
		plan.NextAt = nil // every reset already starts one
	}
	if plan.NextAt != nil && !plan.NextAt.After(time.Now().Add(-time.Minute)) {
		httpError(w, http.StatusBadRequest, errors.New("next_at is in the past"))
		return
	}

	d.schedMu.Lock()
	defer d.schedMu.Unlock()
	d.planMu.Lock()
	prev, err := d.Store.WindowPlanFor(plan.AccountID)
	plans, perr := d.Store.WindowPlans()
	d.planMu.Unlock()
	if err == nil {
		err = perr
	}
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// Not the request's context: a client that disconnects must not stop
	// launchd halfway through the account's jobs.
	syncCtx := context.WithoutCancel(r.Context())
	// restoreLaunchd puts launchd back to the stored plans after a change
	// that did not go through.
	restoreLaunchd := func() {
		if scheds, err := d.Store.Schedules(); err == nil {
			if err := d.syncTriggers(syncCtx, scheds); err != nil {
				d.Log.Warn("re-sync launchd after a failed plan change", "err", err)
			}
		}
	}
	if prev.Rolling != plan.Rolling && d.TriggerSync != nil {
		// launchd first, with the plans as they will be; the plan is saved
		// only once launchd agrees. The start loop reads the stored plans,
		// so a plan saved first could start a window that the request then
		// reports as not enabled.
		scheds, err := d.Store.Schedules()
		if err == nil {
			err = d.TriggerSync(syncCtx, pilotapi.LiveSchedules(scheds, withPlan(plans, plan)))
		}
		unlicensed := errors.Is(err, pilot.ErrNotLicensed) || errors.Is(err, pilot.ErrNotAvailable)
		switch {
		case err == nil:
		case unlicensed && !plan.Rolling:
			// Switching off with the licence gone: nothing fires without it,
			// and the sync runs again when it comes back (onLicensed).
			d.Log.Info("rolling off without a licence — launchd re-syncs when it returns", "account", plan.AccountID)
		default:
			restoreLaunchd()
			httpError(w, http.StatusInternalServerError, fmt.Errorf("updating the daily times: %w", err))
			return
		}
	}
	d.planMu.Lock()
	err = d.Store.SetWindowPlan(plan)
	d.planMu.Unlock()
	if err != nil {
		if prev.Rolling != plan.Rolling {
			restoreLaunchd() // launchd already took the change the store refused
		}
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// A new plan retries at once — but a start still running keeps its
	// bookkeeping, and a window it just opened still holds.
	d.mu.Lock()
	if try := d.planTries[plan.AccountID]; try != nil {
		try.wait = 0
		try.lastAt = time.Time{}
	}
	d.mu.Unlock()
	d.afterScheduleMutation(r.Context())
	writeJSON(w, http.StatusOK, plan)
}

// resyncTriggers mirrors the registry into launchd once: jobs written by an
// older build launched caffeinate (macOS named them after it), and an
// account switched to rolling outside this daemon must have its fixed times
// paused. Unchanged jobs are left alone by the sync itself. It holds the
// schedule lock like the schedule routes, and is retried from the minute
// tick until it succeeds (the sync is licence-gated, and a licence still
// being re-checked at start would otherwise put the migration off until the
// next restart). Reports whether it is done.
func (d *Daemon) resyncTriggers(ctx context.Context) bool {
	if d.TriggerSync == nil {
		return true
	}
	d.schedMu.Lock()
	defer d.schedMu.Unlock()
	scheds, err := d.Store.Schedules()
	if err != nil {
		d.Log.Warn("read schedules for the launchd sync", "err", err)
		return false
	}
	if len(scheds) == 0 {
		return true
	}
	if err := d.syncTriggers(ctx, scheds); err != nil {
		if errors.Is(err, pilot.ErrNotLicensed) || errors.Is(err, pilot.ErrNotAvailable) {
			// Nothing to retry until the licence is back (onLicensed).
			return true
		}
		d.Log.Warn("launchd sync", "err", err)
		return false
	}
	return true
}

// onLicensed re-runs the launchd sync once the licence turns (back) on: a
// sync refused while it was off left the jobs as they were.
func (d *Daemon) onLicensed(ctx context.Context) {
	go d.resyncTriggers(context.WithoutCancel(ctx))
}

// withPlan is plans with account p's entry replaced by p (dropped when p is
// empty) — the plans as they will be once p is saved.
func withPlan(plans []pilotapi.WindowPlan, p pilotapi.WindowPlan) []pilotapi.WindowPlan {
	out := make([]pilotapi.WindowPlan, 0, len(plans)+1)
	for _, q := range plans {
		if q.AccountID != p.AccountID {
			out = append(out, q)
		}
	}
	if !p.Empty() {
		out = append(out, p)
	}
	return out
}
