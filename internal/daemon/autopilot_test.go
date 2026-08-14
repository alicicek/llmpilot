package daemon

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// fakePolicy stands in for the pro engine: rotate the active account to the
// fleet-mate with the most headroom past the default threshold, honoring the
// cooldown contract — enough to exercise the daemon's wiring (events,
// cooldown restart, notify). The real rule set is tested in the engine.
type fakePolicy struct{ params pilotapi.Params }

func (f fakePolicy) Decide(now time.Time, activeID string, lastSwitch time.Time, cands []pilotapi.Candidate) *pilotapi.Decision {
	if !lastSwitch.IsZero() && now.Sub(lastSwitch) < f.params.Cooldown {
		return nil
	}
	var active, best *pilotapi.Candidate
	for i := range cands {
		if cands[i].Account.ID == activeID {
			active = &cands[i]
			continue
		}
		u, _ := pilotapi.Utilization(cands[i].Snapshot)
		if u < f.params.Threshold && best == nil {
			best = &cands[i]
		}
	}
	if active == nil || best == nil {
		return nil
	}
	if u, _ := pilotapi.Utilization(active.Snapshot); u < f.params.Threshold {
		return nil
	}
	return &pilotapi.Decision{From: active.Account, To: best.Account, Reason: "test rotation"}
}

func pilotDaemon(t *testing.T, switchErr error) (*Daemon, *[]string, *[]string) {
	t.Helper()
	st := testStore(t)
	saveSnap(t, st, "a", 95)
	saveSnap(t, st, "b", 10)
	var switched, notes []string
	d := &Daemon{
		Store: st,
		Pilot: fakePolicy{params: pilotapi.ParamsFrom(pilotapi.AutopilotConfig{})},
		Switch: func(_ context.Context, id string) error {
			switched = append(switched, id)
			return switchErr
		},
		Active: func(context.Context) string { return "a" },
		NotifyUser: func(_ context.Context, _, body string) {
			notes = append(notes, body)
		},
	}
	d.init()
	return d, &switched, &notes
}

func saveSnap(t *testing.T, st *store.Store, id string, pct float64) {
	t.Helper()
	err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: id,
		AsOf:      time.Now().UTC(),
		Buckets:   []store.Bucket{{Kind: "five_hour", Percent: pct, Active: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestMaybeRotateSwitchesAtThreshold(t *testing.T) {
	d, switched, notes := pilotDaemon(t, nil)
	d.maybeRotate(context.Background())
	if len(*switched) != 1 || (*switched)[0] != "b" {
		t.Fatalf("want switch to b, got %v", *switched)
	}
	if len(*notes) != 1 {
		t.Fatalf("auto-switch must notify, got %v", *notes)
	}
	evs, err := d.Store.Events(0)
	if err != nil || len(evs) != 1 || evs[0].Kind != "autoswitch" || evs[0].AccountID != "b" {
		t.Fatalf("want one autoswitch event, got %v (err %v)", evs, err)
	}
	st, err := d.State(context.Background())
	if err != nil || len(st.Events) != 1 {
		t.Fatalf("state must carry events, got %+v (err %v)", st.Events, err)
	}
	// cooldown: an immediate re-evaluation must not switch again.
	d.maybeRotate(context.Background())
	if len(*switched) != 1 {
		t.Fatalf("cooldown ignored, switches: %v", *switched)
	}
}

func TestMaybeRotateFailureIsLoggedAndCoolsDown(t *testing.T) {
	d, switched, notes := pilotDaemon(t, errors.New("locks held"))
	d.maybeRotate(context.Background())
	d.maybeRotate(context.Background())
	if len(*switched) != 1 {
		t.Fatalf("failed switch must still cool down, got %v", *switched)
	}
	evs, _ := d.Store.Events(0)
	if len(evs) != 1 || evs[0].Kind != "autoswitch_failed" {
		t.Fatalf("want autoswitch_failed event, got %v", evs)
	}
	if len(*notes) != 1 {
		t.Fatal("failure must still notify the user")
	}
}

func TestMaybeRotateNilPilotIsOff(t *testing.T) {
	d, switched, _ := pilotDaemon(t, nil)
	d.Pilot = nil
	d.maybeRotate(context.Background())
	if len(*switched) != 0 {
		t.Fatalf("nil pilot rotated: %v", *switched)
	}
}

// TestMaybeRotateSkipsQuarantinedTarget: a quarantined account's credential
// provably cannot refresh — nominating it would strand the user on a dead
// session (Codex P2, 2026-07-16). The active account must stay a candidate
// even when quarantined, so the policy can still rotate AWAY from it.
func TestMaybeRotateSkipsQuarantinedTarget(t *testing.T) {
	d, switched, _ := pilotDaemon(t, nil)
	d.mu.Lock()
	d.quarantine["b"] = "sha256:dead"
	d.mu.Unlock()
	d.maybeRotate(context.Background())
	if len(*switched) != 0 {
		t.Fatalf("rotated to a quarantined target: %v", *switched)
	}

	// Quarantined ACTIVE account: still a candidate, so rotation away works.
	d2, switched2, _ := pilotDaemon(t, nil)
	d2.mu.Lock()
	d2.quarantine["a"] = "sha256:dead" // a is active at 95%
	d2.mu.Unlock()
	d2.maybeRotate(context.Background())
	if len(*switched2) != 1 || (*switched2)[0] != "b" {
		t.Fatalf("quarantined active must still rotate away, got %v", *switched2)
	}
}

// TestMaybeRotateSkipsPinnedTarget: Swap refuses pinned accounts, so a
// policy that nominates one must be refused STRUCTURALLY. Pinned lanes now
// reach the policy as flagged candidates (the hold branch needs their usage
// to name watch-only headroom — LAYER 2), so the daemon's guard is what
// keeps a bad nomination from burning the cooldown on a switch that can
// only fail. The fake policy here ignores Pinned on purpose: it plays the
// misbehaving policy the guard exists for.
func TestMaybeRotateSkipsPinnedTarget(t *testing.T) {
	d, switched, notes := pilotDaemon(t, nil)
	d.Pinned = func(a store.Account) bool { return a.ID == "b" }
	d.maybeRotate(context.Background())
	d.maybeRotate(context.Background())
	if len(*switched) != 0 {
		t.Fatalf("rotated to a pinned target: %v", *switched)
	}
	if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
		t.Fatalf("want one de-spammed guard hold, got %v", kinds)
	}
	if len(*notes) != 0 {
		t.Fatalf("the guard hold must not banner: %v", *notes)
	}
	d.mu.Lock()
	armed := !d.lastSwitch.IsZero()
	d.mu.Unlock()
	if armed {
		t.Fatal("pinned-target guard must not arm the cooldown")
	}

	// Each arm of the guard must hold ALONE (reviewer P2: mutation testing
	// proved neither was independently pinned).
	t.Run("daemon rule catches an unflagged nomination", func(t *testing.T) {
		// A policy that constructs its own Account rows never sets Pinned —
		// the daemon's own rule is what refuses it.
		d, switched, _ := pilotDaemon(t, nil)
		d.Pinned = func(a store.Account) bool { return a.ID == "b" }
		d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
			From: store.Account{ID: "a"}, To: store.Account{ID: "b"}, Reason: "rotate",
		}}
		d.maybeRotate(context.Background())
		if len(*switched) != 0 {
			t.Fatalf("unflagged pinned nomination rode the switch: %v", *switched)
		}
	})
	t.Run("self-reported pinned nomination refused without a rule", func(t *testing.T) {
		// No pinned rule wired (d.Pinned nil): a target the policy itself
		// marks Pinned must still be refused — Swap would only fail on it.
		d, switched, _ := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
			From: store.Account{ID: "a"}, To: store.Account{ID: "b", Pinned: true}, Reason: "rotate",
		}}
		d.maybeRotate(context.Background())
		if len(*switched) != 0 {
			t.Fatalf("self-reported pinned nomination rode the switch: %v", *switched)
		}
	})
}

// TestAutopilotPinnedCandidatesFlagged: the policy must SEE pinned lanes —
// flagged, never filtered — so its hold branch can name a watch-only lane
// that holds the fleet's only headroom. Quarantine still filters outright:
// a provably dead credential is not headroom.
func TestAutopilotPinnedCandidatesFlagged(t *testing.T) {
	d, _, _ := pilotDaemon(t, nil)
	d.Pinned = func(a store.Account) bool { return a.ID == "b" }
	var seen []pilotapi.Candidate
	d.Pilot = scriptedPolicy{seen: &seen}
	d.maybeRotate(context.Background())
	if len(seen) != 2 {
		t.Fatalf("want both candidates, got %+v", seen)
	}
	for _, c := range seen {
		if want := c.Account.ID == "b"; c.Account.Pinned != want {
			t.Fatalf("pinned flag wrong for %s: %+v", c.Account.ID, c)
		}
	}
	d.mu.Lock()
	d.quarantine["b"] = "sha256:dead"
	d.mu.Unlock()
	d.maybeRotate(context.Background())
	if len(seen) != 1 || seen[0].Account.ID != "a" {
		t.Fatalf("quarantined pinned lane not filtered: %+v", seen)
	}

	// The ACTIVE lane is NEVER flagged, even when the rule says pinned
	// (reviewer P1): the policy reads a pinned active as "don't touch" and
	// would go silent at 100% — no rotation, no hold, no nudge — while
	// rotating AWAY only writes the global slot. Reached in production when
	// the watch-only account's email is also signed into the default dir.
	d2, _, _ := pilotDaemon(t, nil)
	d2.Pinned = func(store.Account) bool { return true } // everything, active included
	var seen2 []pilotapi.Candidate
	d2.Pilot = scriptedPolicy{seen: &seen2}
	d2.maybeRotate(context.Background())
	if len(seen2) != 2 {
		t.Fatalf("want both candidates, got %+v", seen2)
	}
	for _, c := range seen2 {
		if want := c.Account.ID != "a"; c.Account.Pinned != want {
			t.Fatalf("active lane must never be flagged pinned: %+v", seen2)
		}
	}
}

// TestBurnRate: adaptive's evidence bars (owner 2026-08-13). Below either
// bar the bucket must report NO data — the policy then falls back to the
// fixed threshold — and a reset inside the window invalidates every
// sample before it. Idle is DATA (0), not absence.
func TestBurnRate(t *testing.T) {
	seed := func(d *Daemon, minsAgo, pct float64) {
		d.appendHistory(historyKey("a", "five_hour", ""),
			HistorySample{At: time.Now().Add(-time.Duration(minsAgo * float64(time.Minute))), Percent: pct})
	}

	t.Run("too few samples is no data", func(t *testing.T) {
		// Span 12 min — PASSES the span bar, so the sample bar alone must
		// refuse (review P2: with a short span both bars fired and the
		// sample bar was deletable with the suite green). 3 samples over
		// 11+ min is exactly the shape a 429 cooldown leaves behind.
		d, _, _ := pilotDaemon(t, nil)
		for i, pct := range []float64{60, 65, 70} {
			seed(d, float64(12-6*i), pct)
		}
		if _, ok := d.burnRate("a", "five_hour", "", time.Now()); ok {
			t.Fatal("3 samples must not support a projection, whatever they span")
		}
	})

	t.Run("too short a span is no data", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		for i, pct := range []float64{60, 62, 64, 66} {
			seed(d, 6-1.5*float64(i), pct)
		}
		if _, ok := d.burnRate("a", "five_hour", "", time.Now()); ok {
			t.Fatal("a 4.5-minute span must not support a projection")
		}
	})

	t.Run("a clean climb projects its slope", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		for i, pct := range []float64{60, 63, 66, 69, 72} {
			seed(d, 12-3*float64(i), pct)
		}
		rate, ok := d.burnRate("a", "five_hour", "", time.Now())
		if !ok || rate < 0.9 || rate > 1.1 {
			t.Fatalf("12%% over 12 min must read ≈1%%/min, got %v %v", rate, ok)
		}
	})

	t.Run("a reset invalidates the slope before it", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		// 88→94 then RESET to 2, then a short post-reset climb: the
		// pre-reset climb must not leak into the slope, and the short
		// post-reset segment fails the span bar → no data.
		for i, pct := range []float64{88, 91, 94, 2, 4} {
			seed(d, 14-3*float64(i), pct)
		}
		if _, ok := d.burnRate("a", "five_hour", "", time.Now()); ok {
			t.Fatal("a slope spanning a reset must never be trusted")
		}
	})

	t.Run("two resets in one window: the LAST segment carries the slope", func(t *testing.T) {
		// Review P2: a forward cut (first drop wins) keeps a segment
		// spanning the SECOND reset — negative slope, clamped to 0,
		// reported as evidence of idle. The backward cut must isolate the
		// post-last-reset climb (≈1%/min here).
		d, _, _ := pilotDaemon(t, nil)
		for _, s := range []struct{ minsAgo, pct float64 }{
			{14.5, 60}, {13.5, 70}, {12.5, 10}, {12, 20}, // first reset at 12.5
			{11, 5}, {7.5, 8}, {4, 12}, {0.5, 16}, // second reset at 11; clean climb after
		} {
			seed(d, s.minsAgo, s.pct)
		}
		rate, ok := d.burnRate("a", "five_hour", "", time.Now())
		if !ok || rate < 0.95 || rate > 1.15 {
			t.Fatalf("want ≈1.05%%/min from the post-last-reset segment, got %v %v", rate, ok)
		}
	})

	t.Run("idle is data, not absence", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		for i := 0; i < 5; i++ {
			seed(d, 12-3*float64(i), 97)
		}
		rate, ok := d.burnRate("a", "five_hour", "", time.Now())
		if !ok || rate != 0 {
			t.Fatalf("a flat ring is genuine idle (0, true), got %v %v", rate, ok)
		}
	})

	t.Run("burst clamps to the plausible max", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		for i, pct := range []float64{0, 30, 60, 90} {
			seed(d, 12-4*float64(i), pct)
		}
		rate, ok := d.burnRate("a", "five_hour", "", time.Now())
		if !ok || rate != pilotapi.MaxPlausibleBurn {
			t.Fatalf("7.5%%/min must clamp to %v, got %v %v", pilotapi.MaxPlausibleBurn, rate, ok)
		}
	})

	t.Run("samples outside the window are dead", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		for i, pct := range []float64{10, 30, 50, 70, 90} {
			seed(d, 120-3*float64(i), pct) // all ~2h old
		}
		if _, ok := d.burnRate("a", "five_hour", "", time.Now()); ok {
			t.Fatal("stale samples must not support a projection")
		}
	})
}

// TestAutopilotCandidatesCarryBurnAndActiveTier: the adaptive inputs reach
// the policy — burn per bucket where the bars are met, tier for the
// ACTIVE lane only (a non-active fleet account's tier is not on disk
// anywhere; asking would answer with the active's identity).
func TestAutopilotCandidatesCarryBurnAndActiveTier(t *testing.T) {
	d, _, _ := pilotDaemon(t, nil)
	var seen []pilotapi.Candidate
	d.Pilot = scriptedPolicy{seen: &seen}
	d.TierMultiplier = func(_ context.Context, a store.Account) int {
		if a.ID != "a" {
			t.Fatalf("tier asked for non-active %q", a.ID)
		}
		return 20
	}
	for i, pct := range []float64{60, 63, 66, 69, 72} {
		d.appendHistory(historyKey("a", "five_hour", ""),
			HistorySample{At: time.Now().Add(-time.Duration((12 - 3*float64(i)) * float64(time.Minute))), Percent: pct})
	}
	d.maybeRotate(context.Background())
	if len(seen) != 2 {
		t.Fatalf("want both candidates, got %+v", seen)
	}
	for _, c := range seen {
		switch c.Account.ID {
		case "a":
			if c.TierMultiplier != 20 {
				t.Fatalf("active must carry its tier, got %+v", c)
			}
			rate, ok := c.Burn[pilotapi.BucketKey("five_hour", "")]
			if !ok || rate < 0.9 || rate > 1.1 {
				t.Fatalf("active must carry its burn, got %+v", c.Burn)
			}
		case "b":
			if c.TierMultiplier != 0 || c.Burn != nil {
				t.Fatalf("non-active with no history must carry neither, got %+v", c)
			}
		}
	}
}

// TestWatchOnlyHeadroomNotice: LAYER 2 end to end at the daemon layer. A
// hold that names a watch-only lane nudges the user exactly once — never
// once per poll — with the move-it remedy, and lands one event.
func TestWatchOnlyHeadroomNotice(t *testing.T) {
	d, switched, notes := pilotDaemon(t, nil)
	// The decision's Label deliberately DISAGREES with the registry ("b"):
	// the banner must name the lane from the daemon's own row, never from
	// the in-flight decision copy (reviewer N2).
	d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
		From: store.Account{ID: "a"}, Hold: true, HoldKind: "watch-only-headroom",
		PinnedHeadroom: store.Account{ID: "b", Label: "sam@work", Pinned: true},
		Reason:         "a at 95% (five_hour) — held: sam@work has headroom but is watch-only",
	}}
	d.maybeRotate(context.Background())
	want := "b has headroom, but it's watch-only — move it into the fleet and the autopilot can use it"
	if len(*notes) != 1 || (*notes)[0] != want {
		t.Fatalf("want the move-it nudge, got %v", *notes)
	}
	if len(*switched) != 0 {
		t.Fatalf("a hold must not switch: %v", *switched)
	}
	evs, err := d.Store.Events(0)
	if err != nil || len(evs) != 2 || evs[0].Kind != "autopilot_hold" ||
		evs[1].Kind != "watch_only_headroom" || evs[1].AccountID != "b" || evs[1].Message != want {
		t.Fatalf("want hold + watch_only_headroom events, got %v (err %v)", evs, err)
	}
	// Every later poll inside the 24h window stays silent.
	d.maybeRotate(context.Background())
	d.maybeRotate(context.Background())
	if len(*notes) != 1 {
		t.Fatalf("nudge repeated within 24h: %v", *notes)
	}
	// A nil NotifyUser (engine-absent wiring) must never panic — and the
	// event still lands for a DIFFERENT lane.
	registerLane(t, d, "c")
	d.NotifyUser = nil
	d.Pilot = scriptedPolicy{dec: watchOnlyHold("c", "c@work")}
	d.maybeRotate(context.Background())
	if kinds := eventKinds(t, d); len(kinds) != 3 || kinds[2] != "watch_only_headroom" {
		t.Fatalf("nil NotifyUser must still event, got %v", kinds)
	}
}

// watchOnlyHold is the engine's watch-only-headroom hold naming one lane.
func watchOnlyHold(id, label string) *pilotapi.Decision {
	return &pilotapi.Decision{
		From: store.Account{ID: "a"}, Hold: true, HoldKind: "watch-only-headroom",
		PinnedHeadroom: store.Account{ID: id, Label: label, Pinned: true},
		Reason:         "a at 95% (five_hour) — held: " + label + " has headroom but is watch-only",
	}
}

// registerLane adds one more account to the two-lane test registry — the
// nudge verifies its lane against the registry before bannering.
func registerLane(t *testing.T, d *Daemon, id string) {
	t.Helper()
	err := d.Store.SaveAccounts([]store.Account{
		{ID: "a", Label: "a", Email: "a@example.dev"},
		{ID: "b", Label: "b", Email: "b@example.dev"},
		{ID: id, Label: id, Email: id + "@example.dev"},
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestWatchOnlyHeadroomClaimVerified (reviewer P2): the banner is a
// user-facing CLAIM — the daemon refuses to voice it when its own state
// says otherwise, and a refused banner never spends the 24h window.
func TestWatchOnlyHeadroomClaimVerified(t *testing.T) {
	t.Run("a lane the registry no longer knows is never bannered", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("ghost", "ghost")}
		d.maybeRotate(context.Background())
		if len(*notes) != 0 {
			t.Fatalf("bannered a deleted lane: %v", *notes)
		}
	})

	t.Run("a lane moved into the fleet mid-poll is never bannered", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		d.Pinned = func(store.Account) bool { return false } // the move already landed
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("b", "b")}
		d.maybeRotate(context.Background())
		if len(*notes) != 0 {
			t.Fatalf("bannered a lane that is already switchable: %v", *notes)
		}
		// The refusal must not have spent the window: the moment the lane
		// really is watch-only again, the nudge fires.
		d.Pinned = func(a store.Account) bool { return a.ID == "b" }
		d.maybeRotate(context.Background())
		if len(*notes) != 1 {
			t.Fatalf("refused banner spent the 24h window: %v", *notes)
		}
	})

	t.Run("a stale or quarantined lane is not headroom", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("b", "b")}
		d.mu.Lock()
		d.stale["b"] = time.Now()
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		d.mu.Lock()
		delete(d.stale, "b")
		d.quarantine["b"] = "sha256:dead"
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		if len(*notes) != 0 {
			t.Fatalf("bannered a stale/quarantined lane: %v", *notes)
		}
	})
}

// TestWatchOnlyHeadroomNoticeDedupe: the event log is the durable dedupe
// memory — a daemon restart inside the 24h window stays silent, a nudge
// older than a day re-fires while the hold persists, and the window is per
// ACCOUNT, never global.
func TestWatchOnlyHeadroomNoticeDedupe(t *testing.T) {
	seedNudge := func(t *testing.T, d *Daemon, id string, age time.Duration) {
		t.Helper()
		err := d.Store.AppendEvent(store.Event{
			At: time.Now().Add(-age).UTC(), Kind: "watch_only_headroom", AccountID: id,
			Message: id + " has headroom, but it's watch-only — move it into the fleet and the autopilot can use it",
		})
		if err != nil {
			t.Fatal(err)
		}
	}

	t.Run("restart inside the window stays silent", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil) // fresh in-memory state = a restart
		seedNudge(t, d, "b", 2*time.Hour)
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("b", "b")}
		d.maybeRotate(context.Background())
		if len(*notes) != 0 {
			t.Fatalf("restart re-nudged inside 24h: %v", *notes)
		}
		// The log's timestamp seeds the in-memory window: the next nudge is
		// due 24h after the LOGGED one, not 24h after boot.
		d.mu.Lock()
		last := d.lastWatchOnly["b"]
		d.mu.Unlock()
		if last.IsZero() || time.Since(last) < time.Hour {
			t.Fatalf("logged nudge time not remembered, got %v", last)
		}
	})

	t.Run("a day-old nudge re-fires while the hold persists", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		seedNudge(t, d, "b", 25*time.Hour)
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("b", "b")}
		d.maybeRotate(context.Background())
		if len(*notes) != 1 {
			t.Fatalf("want one fresh nudge after 24h, got %v", *notes)
		}
	})

	t.Run("the window is per account", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		registerLane(t, d, "c")
		seedNudge(t, d, "b", 2*time.Hour)
		d.Pilot = scriptedPolicy{dec: watchOnlyHold("c", "c@work")}
		d.maybeRotate(context.Background())
		if len(*notes) != 1 {
			t.Fatalf("another lane's window silenced c@work: %v", *notes)
		}
	})

	t.Run("append failure never breaks the window", func(t *testing.T) {
		// When the event write fails, the in-memory map is the ONLY dedupe
		// left — without it this is a banner every poll (reviewer P2: this
		// state was previously untested, so the map could be deleted with
		// the suite green).
		home := t.TempDir()
		st := store.At(home)
		accs := []store.Account{
			{ID: "a", Label: "a", Email: "a@example.dev"},
			{ID: "b", Label: "b", Email: "b@example.dev"},
		}
		if err := st.SaveAccounts(accs); err != nil {
			t.Fatal(err)
		}
		saveSnap(t, st, "a", 95)
		saveSnap(t, st, "b", 10)
		var notes []string
		d := &Daemon{
			Store:  st,
			Pilot:  scriptedPolicy{dec: watchOnlyHold("b", "b")},
			Switch: func(context.Context, string) error { return nil },
			Active: func(context.Context) string { return "a" },
			NotifyUser: func(_ context.Context, _, body string) {
				notes = append(notes, body)
			},
		}
		d.init()
		// r-x on the store home: reads keep working, event appends fail.
		if err := os.Chmod(home, 0o500); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(home, 0o700) })
		d.maybeRotate(context.Background())
		d.maybeRotate(context.Background())
		if len(notes) != 1 {
			t.Fatalf("in-memory window must hold alone when the log write fails, got %v", notes)
		}
	})
}

// scriptedPolicy returns a preset decision and records the candidates it was
// shown — the daemon's routing (stale marking, revive vs switch, hold
// events) is under test here, not the rule set.
type scriptedPolicy struct {
	dec  *pilotapi.Decision
	seen *[]pilotapi.Candidate
}

func (s scriptedPolicy) Decide(_ time.Time, _ string, _ time.Time, cands []pilotapi.Candidate) *pilotapi.Decision {
	if s.seen != nil {
		*s.seen = append((*s.seen)[:0], cands...)
	}
	return s.dec
}

func eventKinds(t *testing.T, d *Daemon) []string {
	t.Helper()
	evs, err := d.Store.Events(0)
	if err != nil {
		t.Fatal(err)
	}
	kinds := make([]string, 0, len(evs))
	for _, e := range evs {
		kinds = append(kinds, e.Kind)
	}
	return kinds
}

// TestAutopilotStaleCandidatesFlagged: the daemon marks candidates from the
// P1 stale map, so the policy can route them strict by staleness — not by
// snapshot age. Quarantine/pinned filtering and the keep-the-active rule are
// unchanged.
func TestAutopilotStaleCandidatesFlagged(t *testing.T) {
	d, _, _ := pilotDaemon(t, nil)
	var seen []pilotapi.Candidate
	d.Pilot = scriptedPolicy{seen: &seen}
	d.mu.Lock()
	d.stale["b"] = time.Now()
	d.mu.Unlock()
	d.maybeRotate(context.Background())
	if len(seen) != 2 {
		t.Fatalf("want both candidates, got %+v", seen)
	}
	for _, c := range seen {
		if want := c.Account.ID == "b"; c.Stale != want {
			t.Fatalf("stale flag wrong for %s: %+v", c.Account.ID, c)
		}
	}
	// A stale AND quarantined non-active account is still filtered out
	// entirely — quarantine means provably dead, revive would only fail.
	d.mu.Lock()
	d.quarantine["b"] = "sha256:dead"
	d.mu.Unlock()
	d.maybeRotate(context.Background())
	if len(seen) != 1 || seen[0].Account.ID != "a" {
		t.Fatalf("quarantined stale target not filtered: %+v", seen)
	}
}

// TestAutopilotRevive: the strict path end to end at the daemon layer. A
// revive decision routes through d.Revive (never the best-effort d.Switch);
// a proven revive is an autoswitch; ErrReviveNotProven is a designed HOLD —
// one de-spammed event, no failure alarm, no user banner; a real error stays
// an autoswitch_failed.
func TestAutopilotRevive(t *testing.T) {
	revDec := &pilotapi.Decision{
		From:   store.Account{ID: "a"},
		To:     store.Account{ID: "b"},
		Revive: true,
		Reason: "a at 95% — reviving idle b at 10%",
	}

	t.Run("proven revive switches strict", func(t *testing.T) {
		d, switched, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: revDec}
		var revived []string
		d.Revive = func(_ context.Context, id string) error {
			revived = append(revived, id)
			return nil
		}
		d.maybeRotate(context.Background())
		if len(revived) != 1 || revived[0] != "b" {
			t.Fatalf("want one revive of b, got %v", revived)
		}
		if len(*switched) != 0 {
			t.Fatalf("revive must never ride the best-effort switch: %v", *switched)
		}
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autoswitch" {
			t.Fatalf("want one autoswitch event, got %v", kinds)
		}
		if len(*notes) != 1 {
			t.Fatalf("a proven revive is a switch — it notifies, got %v", *notes)
		}
	})

	t.Run("not-proven holds despammed", func(t *testing.T) {
		d, switched, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: revDec}
		fail := fmt.Errorf("%w: budget exhausted — 2 refreshes in 24h", ErrReviveNotProven)
		d.Revive = func(context.Context, string) error { return fail }
		d.maybeRotate(context.Background())
		d.mu.Lock()
		d.lastSwitch = time.Time{} // bypass cooldown to prove the de-spam alone gates
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
			t.Fatalf("want exactly one autopilot_hold, got %v", kinds)
		}
		if len(*switched) != 0 || len(*notes) != 0 {
			t.Fatalf("a hold must not switch or banner: switched=%v notes=%v", *switched, *notes)
		}
		// A different reason is news: second event.
		fail = fmt.Errorf("%w: refresh paused after a rate limit", ErrReviveNotProven)
		d.Revive = func(context.Context, string) error { return fail }
		d.mu.Lock()
		d.lastSwitch = time.Time{}
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		if kinds := eventKinds(t, d); len(kinds) != 2 || kinds[1] != "autopilot_hold" {
			t.Fatalf("a new hold reason must surface, got %v", kinds)
		}
		// An aborted revive still armed the cooldown (set before the attempt).
		d.mu.Lock()
		armed := !d.lastSwitch.IsZero()
		d.mu.Unlock()
		if !armed {
			t.Fatal("failed revive must arm the cooldown")
		}
	})

	t.Run("revive unwired holds instead of best-effort", func(t *testing.T) {
		d, switched, _ := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: revDec}
		d.Revive = nil
		d.maybeRotate(context.Background())
		if len(*switched) != 0 {
			t.Fatalf("stale target rode the best-effort switch: %v", *switched)
		}
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
			t.Fatalf("want autopilot_hold, got %v", kinds)
		}
	})

	t.Run("real failure is an alarm not a hold", func(t *testing.T) {
		d, _, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: revDec}
		d.Revive = func(context.Context, string) error {
			return errors.New(`account "b": sign-in expired — log in to it again`)
		}
		d.maybeRotate(context.Background())
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autoswitch_failed" {
			t.Fatalf("want autoswitch_failed, got %v", kinds)
		}
		if len(*notes) != 1 {
			t.Fatal("a real failure must notify")
		}
	})

	t.Run("hold decision surfaces without cooldown", func(t *testing.T) {
		d, switched, notes := pilotDaemon(t, nil)
		d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
			From: store.Account{ID: "a"}, Hold: true,
			Reason: "a at 95% — held: no account with headroom is available",
		}}
		d.maybeRotate(context.Background())
		d.maybeRotate(context.Background())
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
			t.Fatalf("want one de-spammed autopilot_hold, got %v", kinds)
		}
		if len(*switched) != 0 || len(*notes) != 0 {
			t.Fatalf("hold must not switch or banner: %v %v", *switched, *notes)
		}
		d.mu.Lock()
		armed := !d.lastSwitch.IsZero()
		d.mu.Unlock()
		if armed {
			t.Fatal("a hold must not arm the cooldown — the fleet moves the moment a target appears")
		}
	})

	t.Run("hold despam is percent-immune", func(t *testing.T) {
		// The rendered Reason embeds the active's utilization, which climbs
		// while the fleet holds — the de-spam keys on HoldKind, so a night
		// of 90→91→93% produces ONE event, not one per percent (review P1-3).
		d, _, _ := pilotDaemon(t, nil)
		for _, pct := range []string{"90", "91", "93", "91"} {
			d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
				From: store.Account{ID: "a"}, Hold: true, HoldKind: "no-account-with-headroom",
				Reason: "a at " + pct + "% (five_hour) — held: no account with headroom is available",
			}}
			d.maybeRotate(context.Background())
		}
		if kinds := eventKinds(t, d); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
			t.Fatalf("percent changes defeated the de-spam: %v", kinds)
		}
		// Same for a revive hold: the Reason percent moves, the error stays.
		d2, _, _ := pilotDaemon(t, nil)
		fail := fmt.Errorf("%w: its refresh budget is spent", ErrReviveNotProven)
		d2.Revive = func(context.Context, string) error { return fail }
		for _, pct := range []string{"92", "94"} {
			d2.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
				From: store.Account{ID: "a"}, To: store.Account{ID: "b"}, Revive: true,
				Reason: "a at " + pct + "% — reviving idle b at 10%",
			}}
			d2.mu.Lock()
			d2.lastSwitch = time.Time{}
			d2.mu.Unlock()
			d2.maybeRotate(context.Background())
		}
		if kinds := eventKinds(t, d2); len(kinds) != 1 || kinds[0] != "autopilot_hold" {
			t.Fatalf("revive-hold de-spam not percent-immune: %v", kinds)
		}
	})

	t.Run("stale target routes strict even unmarked", func(t *testing.T) {
		// Structural window-closure (review P2-2): the daemon owns the stale
		// map — a decision that reaches a stale target WITHOUT the Revive
		// flag still goes through d.Revive, never the best-effort switch.
		d, switched, _ := pilotDaemon(t, nil)
		d.mu.Lock()
		d.stale["b"] = time.Now()
		d.mu.Unlock()
		var revived []string
		d.Revive = func(_ context.Context, id string) error {
			revived = append(revived, id)
			return nil
		}
		d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{
			From: store.Account{ID: "a"}, To: store.Account{ID: "b"}, Reason: "rotate", // Revive NOT set
		}}
		d.maybeRotate(context.Background())
		if len(*switched) != 0 || len(revived) != 1 {
			t.Fatalf("stale target rode best-effort: switched=%v revived=%v", *switched, revived)
		}
	})

	t.Run("switch attempt resets hold despam", func(t *testing.T) {
		d, _, _ := pilotDaemon(t, nil)
		hold := &pilotapi.Decision{From: store.Account{ID: "a"}, Hold: true, Reason: "held: nowhere to go"}
		d.Pilot = scriptedPolicy{dec: hold}
		d.maybeRotate(context.Background())
		d.Pilot = scriptedPolicy{dec: &pilotapi.Decision{From: store.Account{ID: "a"}, To: store.Account{ID: "b"}, Reason: "rotate"}}
		d.mu.Lock()
		d.lastSwitch = time.Time{}
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		d.Pilot = scriptedPolicy{dec: hold}
		d.mu.Lock()
		d.lastSwitch = time.Time{}
		d.mu.Unlock()
		d.maybeRotate(context.Background())
		want := []string{"autopilot_hold", "autoswitch", "autopilot_hold"}
		if kinds := eventKinds(t, d); len(kinds) != 3 || kinds[0] != want[0] || kinds[1] != want[1] || kinds[2] != want[2] {
			t.Fatalf("want %v, got %v", want, kinds)
		}
	})
}
