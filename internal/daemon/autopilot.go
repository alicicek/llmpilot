package daemon

import (
	"context"
	"errors"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// ErrReviveNotProven marks a strict revive that could not PROVE a live
// credential: the forced refresh was skipped (budget exhausted, breaker
// open, no refresh token) or failed transiently. maybeRotate HOLDS on it —
// never a swap onto a token known to be expired, and never an
// autoswitch_failed alarm for a designed hold.
var ErrReviveNotProven = errors.New("live sign-in not proven")

// maybeRotate runs the rotation policy after a poll. All writes go through
// d.Switch / d.Revive (the switcher) — there is no second credential path.
// Every attempt, success or failure, lands in the event log and (re)starts
// the cooldown so a broken swap is never hammered once per poll. Stale
// accounts stay candidates but are FLAGGED: the policy routes them through
// the strict revive path regardless of snapshot age, and a hold (over
// threshold, nowhere to go) surfaces as one de-spammed event instead of
// silence.
func (d *Daemon) maybeRotate(ctx context.Context) {
	if d.Pilot == nil || d.Switch == nil || d.Active == nil {
		return
	}
	if d.EntitlementAllowed != nil && !d.EntitlementAllowed("autopilot", time.Now()) {
		return
	}
	accs, err := d.Store.Accounts()
	if err != nil {
		d.Log.Error("load accounts", "err", err)
		return
	}
	activeID := d.Active(ctx)
	d.mu.Lock()
	quarantined := make(map[string]bool, len(d.quarantine))
	for id := range d.quarantine {
		quarantined[id] = true
	}
	stale := make(map[string]bool, len(d.stale))
	for id := range d.stale {
		stale[id] = true
	}
	d.mu.Unlock()
	cands := make([]pilotapi.Candidate, 0, len(accs))
	for _, a := range accs {
		// Never nominate an unswitchable TARGET: a quarantined account's
		// credential provably cannot refresh (switching to it strands the
		// user on a dead session), and Swap refuses pinned accounts outright.
		// The ACTIVE account stays in the set either way — the policy needs
		// it to decide to rotate AWAY.
		if a.ID != activeID && (quarantined[a.ID] || (d.Pinned != nil && d.Pinned(a))) {
			continue
		}
		snap, err := d.Store.Snapshot(a.ID)
		if err != nil {
			d.Log.Warn("load snapshot", "account", a.ID, "err", err)
			continue
		}
		cands = append(cands, pilotapi.Candidate{Account: a, Snapshot: snap, Stale: stale[a.ID]})
	}
	d.mu.Lock()
	last := d.lastSwitch
	d.mu.Unlock()
	dec := d.Pilot.Decide(time.Now(), activeID, last, cands)
	if dec == nil {
		return
	}
	if dec.Hold {
		// Wanted to rotate, couldn't. No cooldown — the moment a candidate
		// becomes eligible the fleet should move, not wait out a timer.
		// De-spam keys on the hold CLASS, never the rendered Reason: the
		// Reason embeds the active's utilization, which changes every poll
		// and would defeat the single-slot memory (review P1-3).
		kind := dec.HoldKind
		if kind == "" {
			kind = dec.Reason
		}
		d.holdOnce(ctx, "hold|"+dec.From.ID+"|"+kind,
			store.Event{Kind: "autopilot_hold", AccountID: dec.From.ID, Message: dec.Reason})
		return
	}
	d.mu.Lock()
	d.lastSwitch = time.Now()
	d.mu.Unlock()

	// Reserve by CALLER INTENT (P3 residual 6): every autopilot-initiated
	// rotation rides the unattended closure, whose switch-time freshen leaves
	// the user's last refresh slot alone. Before P4 only the revive path did
	// that, so the autopilot's non-stale rotations could drain the 2/24h
	// budget the user's own switch needs.
	sw := d.Switch
	if d.AutoSwitch != nil {
		sw = d.AutoSwitch
	}
	if dec.Revive || stale[dec.To.ID] {
		// Structural, not conventional: the daemon owns the stale map, so
		// even a policy that mislabels a stale target cannot route it
		// through the best-effort switch (review P2-2).
		if d.Revive == nil {
			// Without a strict path a stale target must never ride the
			// best-effort switch — hold instead.
			d.holdOnce(ctx, "revive-unwired|"+dec.To.ID,
				store.Event{Kind: "autopilot_hold", AccountID: dec.To.ID,
					Message: dec.Reason + " — held: no revive path is wired"})
			return
		}
		sw = d.Revive
	}
	ev := store.Event{Kind: "autoswitch", AccountID: dec.To.ID, Message: dec.Reason}
	if err := sw(ctx, dec.To.ID); err != nil {
		if errors.Is(err, ErrReviveNotProven) {
			// A designed hold, not a failure: the target's credential could
			// not be proven live (budget/breaker skip or a transient refresh
			// error). The cooldown set above paces the next attempt. The key
			// excludes dec.Reason — its percentages change per poll.
			d.holdOnce(ctx, "revive|"+dec.To.ID+"|"+err.Error(),
				store.Event{Kind: "autopilot_hold", AccountID: dec.To.ID,
					Message: dec.Reason + " — held: " + err.Error()})
			return
		}
		d.Log.Error("auto-switch", "to", dec.To.ID, "err", err)
		ev.Kind = "autoswitch_failed"
		ev.Message = dec.Reason + " — FAILED: " + err.Error()
	}
	// A persistently broken swap retries every cooldown: the SAME failure
	// logs but doesn't re-spam the event log and notification center
	// (review P2-4). Any change — success or a new error — surfaces fully.
	// A real switch attempt also ends the current hold episode: if the
	// fleet holds again later, that is news worth one fresh event.
	d.mu.Lock()
	repeat := ev.Kind == "autoswitch_failed" && d.lastRotateFail == ev.Message
	if ev.Kind == "autoswitch_failed" {
		d.lastRotateFail = ev.Message
	} else {
		d.lastRotateFail = ""
	}
	d.lastHold = ""
	d.mu.Unlock()
	if repeat {
		d.Log.Warn("autopilot failure repeats", "msg", ev.Message)
		return
	}
	if err := d.Store.AppendEvent(ev); err != nil {
		d.Log.Error("append event", "err", err)
	}
	d.notify(ctx)
	if d.NotifyUser != nil {
		d.NotifyUser(ctx, "llmpilot", ev.Message)
	}
	d.Log.Info("autopilot", "event", ev.Kind, "msg", ev.Message)
}

// holdOnce surfaces one autopilot_hold event per distinct reason CLASS (key)
// — a fleet stuck overnight logs its situation once, not once per poll. The
// threshold notification already pinged the user, so hold adds fleet context
// to the feed without a second banner (no NotifyUser). The key is set in the
// same lock acquisition as the check (atomic test-and-set) and CLEARED if
// the append fails, so a failed write never swallows what may be the only
// record of an overnight stranding — the next poll retries (review P2-7).
// In-memory only — a daemon restart re-emits one event per live hold,
// accepted.
func (d *Daemon) holdOnce(ctx context.Context, key string, ev store.Event) {
	d.mu.Lock()
	if d.lastHold == key {
		d.mu.Unlock()
		return
	}
	d.lastHold = key // atomic test-and-set: concurrent callers can't double-append
	d.mu.Unlock()
	if err := d.Store.AppendEvent(ev); err != nil {
		// The event may be the only record of an overnight stranding: log
		// the message itself and clear the key so the next poll retries.
		d.Log.Error("append autopilot_hold event", "err", err, "msg", ev.Message)
		d.mu.Lock()
		if d.lastHold == key {
			d.lastHold = ""
		}
		d.mu.Unlock()
		return
	}
	d.notify(ctx)
	d.Log.Info("autopilot", "event", ev.Kind, "msg", ev.Message)
}
