package daemon

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

func postPlan(t *testing.T, url, body string) (int, string) {
	t.Helper()
	resp, err := http.Post(url+"/v1/window-plans", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp.StatusCode, string(raw)
}

// Rolling pauses the account's fixed daily times — their launchd jobs go,
// the schedules stay — and switching it off brings them back.
func TestWindowPlanRoutePausesFixedTimes(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSchedules([]store.Schedule{
		{ID: "a-0900", AccountID: "a", Hour: 9}, {ID: "b-0900", AccountID: "b", Hour: 9},
	}); err != nil {
		t.Fatal(err)
	}
	var synced [][]string
	failSync := false
	d := &Daemon{Store: st, TriggerSync: func(_ context.Context, scheds []store.Schedule) error {
		if failSync {
			return errors.New("launchd said no")
		}
		var ids []string
		for _, sc := range scheds {
			ids = append(ids, sc.ID)
		}
		synced = append(synced, ids)
		return nil
	}}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()

	if code, body := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusOK {
		t.Fatalf("rolling on = %d %s", code, body)
	}
	if len(synced) != 1 || strings.Join(synced[0], ",") != "b-0900" {
		t.Fatalf("rolling must pause a's fixed time in launchd, synced %v", synced)
	}
	if scheds, _ := st.Schedules(); len(scheds) != 2 {
		t.Fatalf("pausing deleted a schedule: %+v", scheds)
	}
	stt, err := d.State(context.Background())
	if err != nil || len(stt.WindowPlans) != 1 || !stt.WindowPlans[0].Rolling {
		t.Fatalf("state window_plans = %+v %v", stt.WindowPlans, err)
	}

	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":false}`); code != http.StatusOK {
		t.Fatalf("rolling off = %d", code)
	}
	if len(synced) != 2 || strings.Join(synced[1], ",") != "a-0900,b-0900" {
		t.Fatalf("switching rolling off must bring the fixed time back, synced %v", synced)
	}

	// A one-tap leaves launchd alone; rolling drops a one-tap.
	next := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	if code, body := postPlan(t, srv.URL, `{"account_id":"b","next_at":"`+next+`"}`); code != http.StatusOK {
		t.Fatalf("one-tap = %d %s", code, body)
	}
	if len(synced) != 2 {
		t.Fatalf("a one-tap re-synced launchd: %v", synced)
	}
	if code, _ := postPlan(t, srv.URL, `{"account_id":"b","rolling":true,"next_at":"`+next+`"}`); code != http.StatusOK {
		t.Fatal("rolling with a one-tap refused")
	}
	if p, _ := st.WindowPlanFor("b"); !p.Rolling || p.NextAt != nil {
		t.Fatalf("rolling must drop the one-tap: %+v", p)
	}

	// Refusals.
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","next_at":"`+past+`"}`); code != http.StatusBadRequest {
		t.Fatalf("a one-tap in the past = %d, want 400", code)
	}
	if code, _ := postPlan(t, srv.URL, `{"account_id":"nobody","rolling":true}`); code != http.StatusNotFound {
		t.Fatalf("unknown account = %d, want 404", code)
	}
	// launchd refusing the pause leaves the plan as it was.
	failSync = true
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusInternalServerError {
		t.Fatalf("a failed launchd sync = %d, want 500", code)
	}
	if p, _ := st.WindowPlanFor("a"); p.Rolling {
		t.Fatal("rolling was stored although launchd still runs the fixed times")
	}
}

func TestWindowPlanRouteNeedsPro(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st, EntitlementAllowed: func(string, time.Time) bool { return false }}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusPaymentRequired {
		t.Fatalf("without Pro = %d, want 402", code)
	}
	if plans, _ := st.WindowPlans(); len(plans) != 0 {
		t.Fatalf("a refused plan was stored: %+v", plans)
	}
}

// startRecorder fakes the engine's start: it records calls and, when
// opening, saves a snapshot with a fresh window — as the engine does.
type startRecorder struct {
	mu    sync.Mutex
	calls []string
	fail  bool
	// lag: the start fires but the usage check after it fails, so no new
	// snapshot is saved.
	lag  bool
	st   *store.Store
	also func()
}

func (r *startRecorder) start(_ context.Context, accountID, why string) (pilotapi.StartOutcome, error) {
	r.mu.Lock()
	r.calls = append(r.calls, accountID+":"+why)
	fail, lag, also := r.fail, r.lag, r.also
	r.mu.Unlock()
	if also != nil {
		also()
	}
	if fail {
		return pilotapi.StartFailed, errors.New("claude failed")
	}
	if lag {
		return pilotapi.StartFired, nil
	}
	reset := time.Now().Add(5 * time.Hour)
	return pilotapi.StartFired, r.st.SaveSnapshot(&store.UsageSnapshot{AccountID: accountID, AsOf: time.Now().UTC(),
		Buckets: []store.Bucket{{Kind: "five_hour", Percent: 1, ResetsAt: &reset, Active: true}}})
}

func (r *startRecorder) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.calls)
}

func waitCalls(t *testing.T, d *Daemon, r *startRecorder, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		busy := false
		for _, try := range d.planTries {
			busy = busy || try.inFlight
		}
		d.mu.Unlock()
		if r.count() >= want && !busy {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if got := r.count(); got != want {
		t.Fatalf("starts = %d (%v), want %d", got, r.calls, want)
	}
}

func closedWindow(t *testing.T, st *store.Store, accountID string) {
	t.Helper()
	ended := time.Now().Add(-time.Minute)
	if err := st.SaveSnapshot(&store.UsageSnapshot{AccountID: accountID, AsOf: time.Now().UTC(),
		Buckets: []store.Bucket{{Kind: "five_hour", Percent: 80, ResetsAt: &ended}}}); err != nil {
		t.Fatal(err)
	}
}

// Rolling starts a window once its reset has passed, and only once; a
// start that does not open a window is retried with a growing wait.
func TestStartPlannedRollsAndBacksOff(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start}
	d.init()
	ctx := context.Background()
	now := time.Now()

	d.startPlanned(ctx, now)
	waitCalls(t, d, rec, 1)
	if rec.calls[0] != "a:rolling" {
		t.Fatalf("start = %q", rec.calls[0])
	}
	// The window is open now: nothing more until its reset.
	d.startPlanned(ctx, now.Add(time.Minute))
	waitCalls(t, d, rec, 1)

	// A start that fails: retried after 2 min, then after 4 more. (A fresh
	// daemon — the one above holds the window it just opened.)
	closedWindow(t, st, "a")
	rec.fail = true
	d = &Daemon{Store: st, StartWindow: rec.start}
	d.init()
	t0 := now.Add(10 * time.Minute)
	d.startPlanned(ctx, t0)
	waitCalls(t, d, rec, 2)
	d.startPlanned(ctx, t0.Add(time.Minute))
	waitCalls(t, d, rec, 2)
	d.startPlanned(ctx, t0.Add(2*time.Minute+time.Second))
	waitCalls(t, d, rec, 3)
	d.startPlanned(ctx, t0.Add(5*time.Minute))
	waitCalls(t, d, rec, 3)
	d.startPlanned(ctx, t0.Add(6*time.Minute+2*time.Second))
	waitCalls(t, d, rec, 4)
}

// A shared folder signed in to another account: the start waits quietly
// instead of failing, and goes once the account is the one signed in.
func TestStartPlannedWaitsForTheAccountToBeSignedIn(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	signedIn := false
	d := &Daemon{Store: st, StartWindow: rec.start, CanStart: func(store.Account) bool { return signedIn }}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	waitCalls(t, d, rec, 0)
	signedIn = true
	d.startPlanned(context.Background(), time.Now())
	waitCalls(t, d, rec, 1)
}

// A one-tap is used once — and only the one that fired is cleared.
func TestStartPlannedClearsTheOneTapItUsed(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	at := time.Now().Add(-2 * time.Minute)
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", NextAt: &at}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	waitCalls(t, d, rec, 1)
	if rec.calls[0] != "a:one-tap" {
		t.Fatalf("start = %q", rec.calls[0])
	}
	if p, _ := st.WindowPlanFor("a"); !p.Empty() {
		t.Fatalf("the used one-tap was kept: %+v", p)
	}

	// Set again while the start runs: the new one stays.
	st2 := testStore(t)
	closedWindow(t, st2, "a")
	if err := st2.SetWindowPlan(store.WindowPlan{AccountID: "a", NextAt: &at}); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(3 * time.Hour)
	rec2 := &startRecorder{st: st2, also: func() {
		if err := st2.SetWindowPlan(store.WindowPlan{AccountID: "a", NextAt: &later}); err != nil {
			t.Error(err)
		}
	}}
	d2 := &Daemon{Store: st2, StartWindow: rec2.start}
	d2.init()
	d2.startPlanned(context.Background(), time.Now())
	waitCalls(t, d2, rec2, 1)
	if p, _ := st2.WindowPlanFor("a"); p.NextAt == nil || !p.NextAt.Equal(later) {
		t.Fatalf("a one-tap set meanwhile was cleared: %+v", p)
	}
}

// Without Pro nothing planned ever fires.
func TestStartPlannedNeedsPro(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start, EntitlementAllowed: func(string, time.Time) bool { return false }}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	waitCalls(t, d, rec, 0)
}

// At start the daemon re-syncs launchd once: jobs an older build wrote are
// rewritten, and a rolling account's fixed times stay paused.
func TestRunResyncsTriggersOnceWithPausedTimes(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSchedules([]store.Schedule{{ID: "a-0900", AccountID: "a", Hour: 9}, {ID: "b-0900", AccountID: "b", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var synced [][]string
	d := &Daemon{Store: st, TriggerSync: func(_ context.Context, scheds []store.Schedule) error {
		var ids []string
		for _, sc := range scheds {
			ids = append(ids, sc.ID)
		}
		mu.Lock()
		synced = append(synced, ids)
		mu.Unlock()
		return nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = d.Run(ctx); close(done) }()
	time.Sleep(1200 * time.Millisecond) // past a tick: once, not every tick
	cancel()
	<-done
	mu.Lock()
	defer mu.Unlock()
	if len(synced) != 1 || strings.Join(synced[0], ",") != "b-0900" {
		t.Fatalf("start-up sync = %v, want one sync of b-0900 only", synced)
	}
}

// Saving a plan while its start is still running neither crashes the
// daemon nor launches a second start on the same account.
func TestPlanChangeWhileAStartRuns(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	var mu sync.Mutex
	calls := 0
	d := &Daemon{Store: st, StartWindow: func(context.Context, string, string) (pilotapi.StartOutcome, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		<-release
		return pilotapi.StartFailed, errors.New("claude failed")
	}}
	d.init()
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()

	d.startPlanned(context.Background(), time.Now())
	time.Sleep(20 * time.Millisecond) // the start is running
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":false}`); code != http.StatusOK {
		t.Fatalf("plan change = %d", code)
	}
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusOK {
		t.Fatalf("plan change = %d", code)
	}
	d.startPlanned(context.Background(), time.Now())
	time.Sleep(20 * time.Millisecond)
	mu.Lock()
	running := calls
	mu.Unlock()
	if running != 1 {
		t.Fatalf("starts while one is running = %d, want 1", running)
	}
	close(release) // must not panic on the bookkeeping the plan change touched
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		busy := d.planTries["a"].inFlight
		d.mu.Unlock()
		if !busy {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the start never settled")
}

// A start that fired holds the account even when the usage check after it
// lags: the snapshot still reads "closed", but no second start goes out.
func TestAFiredStartHoldsWhenTheUsageCheckLags(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st, lag: true}
	d := &Daemon{Store: st, StartWindow: rec.start}
	d.init()
	now := time.Now()
	d.startPlanned(context.Background(), now)
	waitCalls(t, d, rec, 1)
	for _, later := range []time.Duration{time.Minute, 30 * time.Minute, 4 * time.Hour} {
		d.startPlanned(context.Background(), now.Add(later))
		waitCalls(t, d, rec, 1)
	}
}

// No plans, or none due: the licence (a Keychain read) is never asked.
func TestThePlanLoopReadsTheLicenceOnlyWhenAStartIsDue(t *testing.T) {
	st := testStore(t)
	asked := 0
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start, EntitlementAllowed: func(string, time.Time) bool { asked++; return true }}
	d.init()
	for i := 0; i < 5; i++ {
		d.startPlanned(context.Background(), time.Now())
	}
	if asked != 0 {
		t.Fatalf("no plans, licence asked %d times", asked)
	}
	reset := time.Now().Add(2 * time.Hour)
	if err := st.SaveSnapshot(&store.UsageSnapshot{AccountID: "a", AsOf: time.Now().UTC(),
		Buckets: []store.Bucket{{Kind: "five_hour", Percent: 10, ResetsAt: &reset, Active: true}}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		d.startPlanned(context.Background(), time.Now())
	}
	if asked != 0 {
		t.Fatalf("a start two hours out asked the licence %d times", asked)
	}
}

// A one-tap that could not fire near its time is dropped, not kept for a
// start days later.
func TestAStaleOneTapExpires(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	old := time.Now().Add(-3 * time.Hour)
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", NextAt: &old}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start, CanStart: func(store.Account) bool { return false }}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	if p, _ := st.WindowPlanFor("a"); !p.Empty() {
		t.Fatalf("a three-hour-old one-tap was kept: %+v", p)
	}
	waitCalls(t, d, rec, 0)
}

// A rolling account's daily times are paused, so a new one is refused rather
// than saved out of sight, never to fire.
func TestScheduleCreateRefusedWhileRolling(t *testing.T) {
	st := testStore(t)
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	post := func(body string) int {
		resp, err := http.Post(srv.URL+"/v1/schedules", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}
	if code := post(`{"account_id":"a","hour":9,"minute":0}`); code != http.StatusConflict {
		t.Fatalf("a daily time on a rolling account = %d, want 409", code)
	}
	if scheds, _ := st.Schedules(); len(scheds) != 0 {
		t.Fatalf("the refused time was saved: %+v", scheds)
	}
	if code := post(`{"account_id":"b","hour":9,"minute":0}`); code != http.StatusCreated && code != http.StatusOK {
		t.Fatalf("another account's daily time = %d", code)
	}
}

// An account with no 5-hour limit has no window for a daily time to start:
// one is refused rather than saved out of sight, only ever to skip. A
// duplicate on an account that has the limit says which time, in words.
func TestScheduleCreateRefusedWithNoFiveHourLimit(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSnapshot(&store.UsageSnapshot{AccountID: "a", AsOf: time.Now().UTC(),
		Buckets: []store.Bucket{{Kind: "weekly_all", Percent: 60}}}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	post := func(body string) (int, string) {
		resp, err := http.Post(srv.URL+"/v1/schedules", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return resp.StatusCode, string(b)
	}
	if code, body := post(`{"account_id":"a","hour":2,"minute":15}`); code != http.StatusConflict || !strings.Contains(body, "no 5-hour limit") {
		t.Fatalf("a daily time with no 5-hour limit = %d %s, want 409", code, body)
	}
	if scheds, _ := st.Schedules(); len(scheds) != 0 {
		t.Fatalf("the refused time was saved: %+v", scheds)
	}
	if code, _ := post(`{"account_id":"b","hour":2,"minute":15}`); code != http.StatusCreated {
		t.Fatalf("another account's daily time = %d", code)
	}
	if code, body := post(`{"account_id":"b","hour":2,"minute":15}`); code != http.StatusConflict || !strings.Contains(body, "already has a daily time at 02:15") {
		t.Fatalf("a duplicate = %d %s", code, body)
	}
}

// The hold after a fire is wall-clock time: Go's monotonic clock stops while
// the Mac sleeps, and a hold counted in awake time would block the next
// morning's start.
func TestTheFiredHoldIsWallClock(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	waitCalls(t, d, rec, 1)
	d.mu.Lock()
	try := *d.planTries["a"]
	d.mu.Unlock()
	for name, at := range map[string]time.Time{"firedAt": try.firedAt, "firedUntil": try.firedUntil} {
		if strings.Contains(at.String(), "m=") {
			t.Errorf("%s carries a monotonic reading (stops while the Mac sleeps): %s", name, at)
		}
	}
}

// A poll since the fire is evidence: the window the fire opened has reset
// (start the next one), or still no window after the grace (it never opened).
func TestTheFiredHoldGivesWayToNews(t *testing.T) {
	setup := func(t *testing.T) (*Daemon, *startRecorder, *store.Store) {
		st := testStore(t)
		closedWindow(t, st, "a")
		if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
			t.Fatal(err)
		}
		rec := &startRecorder{st: st, lag: true}
		d := &Daemon{Store: st, StartWindow: rec.start}
		d.init()
		d.startPlanned(context.Background(), time.Now())
		waitCalls(t, d, rec, 1)
		return d, rec, st
	}
	t.Run("the opened window reset", func(t *testing.T) {
		d, rec, st := setup(t)
		// A poll after the fire: the window it opened resets in an hour.
		reset := time.Now().Add(time.Hour)
		if err := st.SaveSnapshot(&store.UsageSnapshot{AccountID: "a", AsOf: time.Now().UTC(),
			Buckets: []store.Bucket{{Kind: "five_hour", Percent: 40, ResetsAt: &reset, Active: true}}}); err != nil {
			t.Fatal(err)
		}
		d.startPlanned(context.Background(), reset.Add(time.Minute))
		waitCalls(t, d, rec, 2)
	})
	t.Run("still no window after the grace", func(t *testing.T) {
		d, rec, st := setup(t)
		time.Sleep(10 * time.Millisecond)
		closedWindow(t, st, "a") // polled since the fire: still closed
		d.startPlanned(context.Background(), time.Now().Add(5*time.Minute))
		waitCalls(t, d, rec, 1) // lag, most likely: hold
		d.startPlanned(context.Background(), time.Now().Add(planLagGrace+time.Minute))
		waitCalls(t, d, rec, 2)
	})
}

// A refused licence is asked once a minute at most, not every tick.
func TestARefusedLicenceIsCached(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	asked := 0
	rec := &startRecorder{st: st}
	d := &Daemon{Store: st, StartWindow: rec.start, EntitlementAllowed: func(string, time.Time) bool { asked++; return false }}
	d.init()
	now := time.Now()
	for i := 0; i < 5; i++ {
		d.startPlanned(context.Background(), now.Add(time.Duration(i)*time.Second))
	}
	if asked != 1 {
		t.Fatalf("licence asked %d times in five ticks, want 1", asked)
	}
	d.startPlanned(context.Background(), now.Add(planLicenceTTL+time.Second))
	if asked != 2 {
		t.Fatalf("licence not asked again after a minute: %d", asked)
	}
	waitCalls(t, d, rec, 0)
}

// Turning a plan off needs no licence — after a trial ends the user can
// still stop what they set up; turning one on does.
func TestAPlanCanBeSwitchedOffWithoutPro(t *testing.T) {
	st := testStore(t)
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st, EntitlementAllowed: func(string, time.Time) bool { return false }}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":false}`); code != http.StatusOK {
		t.Fatalf("switching off without Pro = %d, want 200", code)
	}
	if p, _ := st.WindowPlanFor("a"); !p.Empty() {
		t.Fatalf("still rolling: %+v", p)
	}
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusPaymentRequired {
		t.Fatalf("switching on without Pro = %d, want 402", code)
	}
}

// The licence coming (back) on re-runs the launchd sync a refusal skipped.
func TestTheLicenceComingOnResyncsLaunchd(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSchedules([]store.Schedule{{ID: "a-0900", AccountID: "a", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	synced := make(chan struct{}, 4)
	d := &Daemon{Store: st, TriggerSync: func(context.Context, []store.Schedule) error {
		synced <- struct{}{}
		return nil
	}}
	d.init()
	d.setLicenseStatus(context.Background(), "lifetime")
	select {
	case <-synced:
	case <-time.After(2 * time.Second):
		t.Fatal("the licence came on and launchd was not re-synced")
	}
}

// An expired one-tap says why the start never came.
func TestAnExpiredOneTapLeavesAnEvent(t *testing.T) {
	st := testStore(t)
	closedWindow(t, st, "a")
	old := time.Now().Add(-3 * time.Hour)
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", NextAt: &old}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st, StartWindow: (&startRecorder{st: st}).start, CanStart: func(store.Account) bool { return false }}
	d.init()
	d.startPlanned(context.Background(), time.Now())
	evs, err := st.Events(10)
	if err != nil || len(evs) != 1 || !strings.Contains(evs[0].Message, "did not happen") {
		t.Fatalf("events = %+v %v", evs, err)
	}
}

// After the licence ends, switching rolling off still saves: the launchd
// sync refuses without a licence, and nothing fires without one anyway.
func TestRollingOffSavesAfterTheLicenceEnds(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSchedules([]store.Schedule{{ID: "a-0900", AccountID: "a", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SetWindowPlan(store.WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st,
		EntitlementAllowed: func(string, time.Time) bool { return false },
		TriggerSync:        func(context.Context, []store.Schedule) error { return pilot.NotLicensed("scheduling") }}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	if code, body := postPlan(t, srv.URL, `{"account_id":"a","rolling":false}`); code != http.StatusOK {
		t.Fatalf("rolling off after the licence ended = %d %s, want 200", code, body)
	}
	if p, _ := st.WindowPlanFor("a"); p.Rolling {
		t.Fatal("rolling was put back because Pro is off")
	}
}

// The plan is saved only once launchd agrees: during the sync the start
// loop still sees the old plan, and a failed sync never saves the new one.
func TestAPlanIsSavedOnlyAfterLaunchdAgrees(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSchedules([]store.Schedule{{ID: "a-0900", AccountID: "a", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	fail := true
	var seenDuringSync []bool
	d := &Daemon{Store: st, TriggerSync: func(_ context.Context, scheds []store.Schedule) error {
		p, _ := st.WindowPlanFor("a")
		seenDuringSync = append(seenDuringSync, p.Rolling)
		if fail {
			return errors.New("launchd said no")
		}
		return nil
	}}
	srv := httptest.NewServer(withToken(d))
	defer srv.Close()
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusInternalServerError {
		t.Fatalf("a failed sync = %d, want 500", code)
	}
	if p, _ := st.WindowPlanFor("a"); p.Rolling {
		t.Fatal("rolling was saved although launchd refused it")
	}
	fail = false
	seenDuringSync = nil
	if code, _ := postPlan(t, srv.URL, `{"account_id":"a","rolling":true}`); code != http.StatusOK {
		t.Fatalf("rolling on = %d", code)
	}
	if len(seenDuringSync) == 0 || seenDuringSync[0] {
		t.Fatalf("the plan was visible to the start loop before launchd agreed: %v", seenDuringSync)
	}
	if p, _ := st.WindowPlanFor("a"); !p.Rolling {
		t.Fatal("rolling was not saved after launchd agreed")
	}
}
