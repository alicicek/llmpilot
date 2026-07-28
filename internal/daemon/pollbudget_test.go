package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestBudgetWaitEnforcesRollingWindow pins the hard ceiling math: a spent
// window waits for the oldest in-budget request to age out; aged entries
// free slots.
func TestBudgetWaitEnforcesRollingWindow(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	d.init()
	now := time.Now()

	d.mu.Lock()
	defer d.mu.Unlock()
	if got := d.budgetWait("a", now); got != 0 {
		t.Fatalf("empty window wait = %v, want 0", got)
	}
	// 27 requests in the last hour (oldest first, the recordPoll order): one
	// slot left.
	for i := HourlyPollBudget - 1; i >= 1; i-- {
		d.pollTimes["a"] = append(d.pollTimes["a"], now.Add(-time.Duration(i)*time.Minute))
	}
	if got := d.budgetWait("a", now); got != 0 {
		t.Fatalf("wait with one free slot = %v, want 0", got)
	}
	// A 28th request spends the window; the wait runs to the oldest + 1h.
	oldest := now.Add(-50 * time.Minute)
	d.pollTimes["a"] = append([]time.Time{oldest}, d.pollTimes["a"]...)
	got := d.budgetWait("a", now)
	if want := oldest.Add(time.Hour).Sub(now); got != want {
		t.Fatalf("spent-window wait = %v, want %v", got, want)
	}
	// Entries older than an hour do not count.
	d.pollTimes["b"] = nil
	for i := 0; i < HourlyPollBudget; i++ {
		d.pollTimes["b"] = append(d.pollTimes["b"], now.Add(-2*time.Hour))
	}
	if got := d.budgetWait("b", now); got != 0 {
		t.Fatalf("aged-out window wait = %v, want 0", got)
	}
}

// TestPollDueSkipsWhenBudgetSpent: a spent budget blocks ONE account's
// network call and reschedules it — never the rest of the fleet.
func TestPollDueSkipsWhenBudgetSpent(t *testing.T) {
	st := testStore(t)
	polled := map[string]int{}
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled[a.ID]++
			return []store.Bucket{{Kind: "five_hour", Percent: 5}}, nil
		},
	}
	d.init()
	now := time.Now()
	d.mu.Lock()
	for i := HourlyPollBudget; i >= 1; i-- {
		d.pollTimes["a"] = append(d.pollTimes["a"], now.Add(-time.Duration(i)*time.Minute))
	}
	d.mu.Unlock()
	d.pollDue(context.Background())
	if polled["a"] != 0 {
		t.Fatalf("budget-spent account a polled %d times, want 0", polled["a"])
	}
	if polled["b"] != 1 {
		t.Fatalf("account b polled %d times, want 1", polled["b"])
	}
	d.mu.Lock()
	next := d.nextPoll["a"]
	d.mu.Unlock()
	if !next.After(now) {
		t.Fatalf("nextPoll[a] = %v, want pushed past now while the budget recovers", next)
	}
}

// TestResetPullSchedulesJustAfterReset: a bucket resetting sooner than the
// steady cadence pulls the next poll to a beat after the reset (jittered
// 10–30s), so the freed headroom renders promptly.
func TestResetPullSchedulesJustAfterReset(t *testing.T) {
	st := testStore(t)
	reset := time.Now().Add(10 * time.Minute)
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour, // steady cadence far beyond the reset
		Fetch: func(context.Context, store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: 90, ResetsAt: &reset}}, nil
		},
	}
	d.init()
	accs, err := st.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	d.pollOne(context.Background(), accs[0])
	d.mu.Lock()
	next := d.nextPoll["a"]
	d.mu.Unlock()
	if next.Before(reset.Add(10*time.Second)) || next.After(reset.Add(30*time.Second)) {
		t.Fatalf("nextPoll = %v, want 10–30s after the %v reset", next, reset)
	}
}

// TestResetPullNeverBeatsThePollGap: a reset in seconds must not pull the
// next poll under the per-account request spacing.
func TestResetPullNeverBeatsThePollGap(t *testing.T) {
	st := testStore(t)
	reset := time.Now().Add(5 * time.Second)
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour, // > MinPollGap, so the real gap applies
		Fetch: func(context.Context, store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: 90, ResetsAt: &reset}}, nil
		},
	}
	d.init()
	accs, err := st.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	d.pollOne(context.Background(), accs[0])
	d.mu.Lock()
	next := d.nextPoll["a"]
	d.mu.Unlock()
	// Deterministic without tolerance: pollOne captures its own now AFTER
	// this test's, so its floor is at least now+MinPollGap.
	if next.Before(now.Add(MinPollGap)) {
		t.Fatalf("nextPoll = %v, want floored at %v from now (MinPollGap)", next, MinPollGap)
	}
}
