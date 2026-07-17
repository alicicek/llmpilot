package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

type notification struct{ title, body string }

func thresholdTestDaemon(t *testing.T, cfg store.Config) (*Daemon, *store.Store, *[]notification) {
	t.Helper()
	st := testStore(t)
	if err := st.SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	var notes []notification
	d := &Daemon{
		Store: st,
		NotifyUser: func(_ context.Context, title, body string) {
			notes = append(notes, notification{title, body})
		},
	}
	d.init()
	return d, st, &notes
}

func resetsAt(d time.Duration) *time.Time {
	t := time.Now().Add(d).UTC()
	return &t
}

func eventCount(t *testing.T, st *store.Store, kind string) int {
	t.Helper()
	evs, err := st.Events(0)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, e := range evs {
		if e.Kind == kind {
			n++
		}
	}
	return n
}

// TestThresholdCrossingFiresOnce proves a rising crossing fires exactly one
// notification, and a re-poll at the same (or higher, same-window) percent
// does not re-fire.
func TestThresholdCrossingFiresOnce(t *testing.T) {
	d, st, notes := thresholdTestDaemon(t, store.Config{})
	acc := store.Account{ID: "a", Label: "kai"}
	rz := resetsAt(4 * time.Hour)

	low := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 50, ResetsAt: rz}}}
	high := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 80, ResetsAt: rz}}}

	// First-ever poll (prev==nil): must not fire even though the bucket is
	// low — this just establishes the baseline.
	d.checkThresholds(context.Background(), acc, nil, low)
	if len(*notes) != 0 {
		t.Fatalf("first poll fired: %+v", *notes)
	}

	// 50 → 80 crosses 75: fires once.
	d.checkThresholds(context.Background(), acc, low, high)
	if len(*notes) != 1 {
		t.Fatalf("crossing notes = %+v, want 1", *notes)
	}
	if got := (*notes)[0]; got.title != "llmpilot" || got.body != "kai session at 80% — resets "+rz.Local().Format("15:04") {
		t.Fatalf("notification = %+v", got)
	}
	if n := eventCount(t, st, "threshold"); n != 1 {
		t.Fatalf("threshold events = %d, want 1", n)
	}

	// Same-window re-poll at the same percent: no re-fire.
	d.checkThresholds(context.Background(), acc, high, high)
	if len(*notes) != 1 {
		t.Fatalf("re-poll re-fired: %+v", *notes)
	}
}

// TestThresholdResetsAtChangeRearms proves a new window (resets_at moves,
// percent drops) lets the SAME threshold fire again on the next rise.
func TestThresholdResetsAtChangeRearms(t *testing.T) {
	d, _, notes := thresholdTestDaemon(t, store.Config{})
	acc := store.Account{ID: "a", Label: "kai"}
	oldWindow := resetsAt(1 * time.Hour)
	newWindow := resetsAt(5 * time.Hour)

	base := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 50, ResetsAt: oldWindow}}}
	fired := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 95, ResetsAt: oldWindow}}}

	d.checkThresholds(context.Background(), acc, nil, base)
	d.checkThresholds(context.Background(), acc, base, fired)
	if len(*notes) != 1 {
		t.Fatalf("initial crossing notes = %+v, want 1", *notes)
	}

	// New window starts low.
	freshLow := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 5, ResetsAt: newWindow}}}
	d.checkThresholds(context.Background(), acc, fired, freshLow)
	if len(*notes) != 1 {
		t.Fatalf("window reset alone fired: %+v", *notes)
	}

	// Rising again in the new window re-fires.
	freshHigh := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 80, ResetsAt: newWindow}}}
	d.checkThresholds(context.Background(), acc, freshLow, freshHigh)
	if len(*notes) != 2 {
		t.Fatalf("re-arm crossing notes = %+v, want 2", *notes)
	}
}

// TestThresholdDisabledIsSilent proves Notifications.Disabled suppresses
// everything, even a large crossing.
func TestThresholdDisabledIsSilent(t *testing.T) {
	d, st, notes := thresholdTestDaemon(t, store.Config{Notifications: store.NotificationsConfig{Disabled: true}})
	acc := store.Account{ID: "a", Label: "kai"}
	rz := resetsAt(time.Hour)
	low := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 10, ResetsAt: rz}}}
	high := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 95, ResetsAt: rz}}}

	d.checkThresholds(context.Background(), acc, low, high)
	if len(*notes) != 0 {
		t.Fatalf("disabled config fired: %+v", *notes)
	}
	if n := eventCount(t, st, "threshold"); n != 0 {
		t.Fatalf("disabled config appended %d threshold events", n)
	}
}

// TestThresholdMultipleCrossedFiresOnlyHighest proves a one-poll jump past
// several configured thresholds fires a single notification for the
// highest one crossed.
func TestThresholdMultipleCrossedFiresOnlyHighest(t *testing.T) {
	d, _, notes := thresholdTestDaemon(t, store.Config{
		Notifications: store.NotificationsConfig{Thresholds: []float64{50, 75, 90}},
	})
	acc := store.Account{ID: "a", Label: "kai"}
	rz := resetsAt(time.Hour)
	low := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 10, ResetsAt: rz}}}
	jump := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 95, ResetsAt: rz}}}

	d.checkThresholds(context.Background(), acc, low, jump)
	if len(*notes) != 1 {
		t.Fatalf("multi-cross notes = %+v, want exactly 1", *notes)
	}
	if got := (*notes)[0].body; got != "kai session at 95% — resets "+rz.Local().Format("15:04") {
		t.Fatalf("notification body = %q", got)
	}
}

// TestThresholdSkipsBucketsWithoutResetsAt proves a bucket with no
// resets_at never fires — there's no notion of "this window" to re-arm on.
func TestThresholdSkipsBucketsWithoutResetsAt(t *testing.T) {
	d, _, notes := thresholdTestDaemon(t, store.Config{})
	acc := store.Account{ID: "a", Label: "kai"}
	low := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 10}}}
	high := &store.UsageSnapshot{AccountID: "a", Buckets: []store.Bucket{{Kind: "session", Percent: 95}}}

	d.checkThresholds(context.Background(), acc, low, high)
	if len(*notes) != 0 {
		t.Fatalf("no resets_at fired: %+v", *notes)
	}
}
