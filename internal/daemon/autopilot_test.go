package daemon

import (
	"context"
	"errors"
	"fmt"
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

// TestMaybeRotateSkipsPinnedTarget: Swap refuses pinned accounts, so the
// autopilot must never nominate one (it would burn the cooldown on a switch
// that can only fail).
func TestMaybeRotateSkipsPinnedTarget(t *testing.T) {
	d, switched, _ := pilotDaemon(t, nil)
	d.Pinned = func(a store.Account) bool { return a.ID == "b" }
	d.maybeRotate(context.Background())
	if len(*switched) != 0 {
		t.Fatalf("rotated to a pinned target: %v", *switched)
	}
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
