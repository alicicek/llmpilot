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
		// Never pass an unusable TARGET: a quarantined account's credential
		// provably cannot refresh — switching to it strands the user on a
		// dead session, and naming it as headroom would be a false claim.
		// The ACTIVE account stays in the set either way — the policy needs
		// it to decide to rotate AWAY. PINNED lanes stay in too, FLAGGED:
		// the policy never nominates one (and the guard below refuses if it
		// did), but its hold branch must see their usage to name a
		// watch-only lane that holds the fleet's only headroom (LAYER 2).
		if a.ID != activeID && quarantined[a.ID] {
			continue
		}
		// Derived, same as State — the registry never stores Pinned for
		// real accounts; `a` is a loop copy, nothing writes back. NEVER
		// flagged on the ACTIVE lane: the policy reads a pinned active as
		// "don't touch" and goes silent at 100% (no rotation, no hold, no
		// nudge — reviewer P1), while rotating AWAY only writes the global
		// slot, which is safe. Production hits this when the watch-only
		// account's email is also signed into the default dir.
		if a.ID != activeID && d.Pinned != nil && d.Pinned(a) {
			a.Pinned = true
		}
		snap, err := d.Store.Snapshot(a.ID)
		if err != nil {
			d.Log.Warn("load snapshot", "account", a.ID, "err", err)
			continue
		}
		cand := pilotapi.Candidate{Account: a, Snapshot: snap, Stale: stale[a.ID]}
		// Adaptive time-to-wall inputs (owner 2026-08-13): smoothed burn
		// per bucket from the history ring — absent when the evidence bars
		// aren't met, and the policy then falls back to the fixed
		// threshold. Tier only for the ACTIVE lane (see the field's doc).
		if snap != nil {
			burn := map[string]float64{}
			for _, b := range snap.Buckets {
				if rate, ok := d.burnRate(a.ID, b.Kind, b.Scope, time.Now()); ok {
					burn[pilotapi.BucketKey(b.Kind, b.Scope)] = rate
				}
			}
			if len(burn) > 0 {
				cand.Burn = burn
			}
		}
		if a.ID == activeID && d.TierMultiplier != nil {
			cand.TierMultiplier = d.TierMultiplier(ctx, a)
		}
		cands = append(cands, cand)
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
		d.noticeWatchOnlyHeadroom(ctx, dec)
		return
	}
	if dec.To.Pinned || (d.Pinned != nil && d.Pinned(dec.To)) {
		// Structural, not conventional (the same closure as the stale
		// routing below): Swap refuses pinned accounts, so a policy that
		// nominates one anyway must hold here — never burn the cooldown on
		// a switch that can only fail.
		d.holdOnce(ctx, "pinned-target|"+dec.To.ID,
			store.Event{Kind: "autopilot_hold", AccountID: dec.To.ID,
				Message: dec.Reason + " — held: " + dec.To.Label + " is watch-only"})
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

// noticeWatchOnlyHeadroom is LAYER 2 of the watch-only safety net (owner
// 2026-08-12): when a hold reports that the fleet's only headroom sits on a
// watch-only (pinned) lane, nudge the user — moving the lane into the fleet
// is a consented two-click action the autopilot must never take itself.
// Deduped per account, 24h-class: in-memory for the common path, the event
// log as the durable memory across restarts (checkUnregistered's
// discipline). The nudge ends on its own once the lane is moved — a
// switchable lane with headroom means the fleet switches instead of holding.
func (d *Daemon) noticeWatchOnlyHeadroom(ctx context.Context, dec *pilotapi.Decision) {
	lane := dec.PinnedHeadroom
	if lane.ID == "" {
		return
	}
	// The banner is a user-facing CLAIM, so verify it against daemon-owned
	// state at banner time, never on the policy's word alone (the same
	// structural discipline as the pinned-target guard): the lane must
	// still exist in the registry and still be pinned — a "Move into the
	// fleet" landing mid-poll makes the in-flight decision's claim false —
	// and a stale or quarantined credential is not headroom. Verified
	// BEFORE the dedupe stamp: a refused banner must never spend the 24h
	// window.
	// A nil d.Pinned skips the pin re-check but is unreachable through
	// production wiring: without the rule, line ~70 never flags a candidate,
	// the policy's pinned scan can never select one, and PinnedHeadroom
	// stays zero — only a scripted test policy gets here. Do not "harden"
	// it into a refusal; nil means unverifiable, not false.
	fresh, ok := d.accountByID(lane.ID)
	if !ok || (d.Pinned != nil && !d.Pinned(fresh)) {
		return
	}
	d.mu.Lock()
	_, laneStale := d.stale[lane.ID]
	_, laneQuarantined := d.quarantine[lane.ID]
	d.mu.Unlock()
	if laneStale || laneQuarantined {
		return
	}
	now := time.Now()
	d.mu.Lock()
	if last, seen := d.lastWatchOnly[lane.ID]; seen && now.Sub(last) < 24*time.Hour {
		d.mu.Unlock()
		return
	}
	d.lastWatchOnly[lane.ID] = now // test-and-set: concurrent polls can't double-notify
	d.mu.Unlock()
	// 500, not the unregistered-notice's 50: this fleet also generates most
	// of the log volume (thresholds, holds, switches), and a nudge evicted
	// from the tail inside its own 24h window would re-banner after a
	// restart. Events reads the whole file either way — the tail size is
	// free.
	if evs, err := d.Store.Events(500); err == nil {
		for _, e := range evs {
			if e.Kind == "watch_only_headroom" && e.AccountID == lane.ID && now.Sub(e.At) < 24*time.Hour {
				// Notified before a restart: remember the REAL time so the
				// next nudge lands 24h after that one, not 24h after boot.
				d.mu.Lock()
				d.lastWatchOnly[lane.ID] = e.At
				d.mu.Unlock()
				return
			}
		}
	}
	// Named from the resolved registry row, not the in-flight decision —
	// the row is the daemon's own truth (reviewer N2).
	msg := fresh.Label + " has headroom, but it's watch-only — move it into the fleet and the autopilot can use it"
	if err := d.Store.AppendEvent(store.Event{Kind: "watch_only_headroom", AccountID: lane.ID, Message: msg}); err != nil {
		// The event is the durable dedupe memory — losing it risks a repeat
		// nudge after a restart, never silence. Notify anyway.
		d.Log.Error("append event", "err", err)
	}
	d.notify(ctx)
	if d.NotifyUser != nil {
		d.NotifyUser(ctx, "llmpilot", msg)
	}
	d.Log.Info("watch-only headroom notice", "account", lane.ID)
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
