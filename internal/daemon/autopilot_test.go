package daemon

import (
	"context"
	"errors"
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
