package daemon

import (
	"context"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// maybeRotate runs the rotation policy after a poll. All writes go through
// d.Switch (the switcher) — there is no second credential path.
// Every attempt, success or failure, lands in the event log and (re)starts
// the cooldown so a broken swap is never hammered once per poll.
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
		cands = append(cands, pilotapi.Candidate{Account: a, Snapshot: snap})
	}
	d.mu.Lock()
	last := d.lastSwitch
	d.mu.Unlock()
	dec := d.Pilot.Decide(time.Now(), activeID, last, cands)
	if dec == nil {
		return
	}
	d.mu.Lock()
	d.lastSwitch = time.Now()
	d.mu.Unlock()

	ev := store.Event{Kind: "autoswitch", AccountID: dec.To.ID, Message: dec.Reason}
	if err := d.Switch(ctx, dec.To.ID); err != nil {
		d.Log.Error("auto-switch", "to", dec.To.ID, "err", err)
		ev.Kind = "autoswitch_failed"
		ev.Message = dec.Reason + " — FAILED: " + err.Error()
	}
	// A persistently broken swap retries every cooldown: the SAME failure
	// logs but doesn't re-spam the event log and notification center
	// (review P2-4). Any change — success or a new error — surfaces fully.
	d.mu.Lock()
	repeat := ev.Kind == "autoswitch_failed" && d.lastRotateFail == ev.Message
	if ev.Kind == "autoswitch_failed" {
		d.lastRotateFail = ev.Message
	} else {
		d.lastRotateFail = ""
	}
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
