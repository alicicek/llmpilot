package daemon

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// climb seeds account a's 5-hour history: one sample every 3 minutes up to
// now, rising perStep each time, ending at last%.
func climb(d *Daemon, now time.Time, last, perStep float64) {
	for i := 4; i >= 0; i-- {
		d.appendHistory(historyKey("a", "five_hour", ""), HistorySample{
			At: now.Add(-time.Duration(i*3) * time.Minute).UTC(), Percent: last - float64(i)*perStep,
		})
	}
}

func windowSnap(now time.Time, pct float64, resetIn time.Duration) *store.UsageSnapshot {
	reset := now.Add(resetIn)
	week := now.Add(72 * time.Hour)
	return &store.UsageSnapshot{AccountID: "a", AsOf: now.UTC(),
		Buckets: []store.Bucket{{Kind: "five_hour", Percent: pct, ResetsAt: &reset, Active: true},
			{Kind: "seven_day", Percent: 40, ResetsAt: &week}}}
}

func TestForecastsTheOpenWindowOnly(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	d.init()
	now := time.Now()
	// The weekly bucket climbs too, with a reset of its own: still never
	// forecast — fifteen minutes of burn says nothing about a week.
	for i := 4; i >= 0; i-- {
		d.appendHistory(historyKey("a", "seven_day", ""), HistorySample{
			At: now.Add(-time.Duration(i*3) * time.Minute).UTC(), Percent: 40 - float64(i)*3,
		})
	}
	// No burn yet: nothing to say.
	if got := d.forecasts("a", windowSnap(now, 50, 3*time.Hour), now); len(got) != 0 {
		t.Fatalf("forecast without a burn: %+v", got)
	}
	// 3% every 3 min = 60%/h. At 50% the wall is 50 min out, before a reset
	// 3 h away.
	climb(d, now, 50, 3)
	got := d.forecasts("a", windowSnap(now, 50, 3*time.Hour), now)
	if len(got) != 1 || got[0].Kind != "five_hour" {
		t.Fatalf("want one 5-hour forecast (never the weekly), got %+v", got)
	}
	f := got[0]
	if f.PerHour != 60 || f.WallAt == nil || !f.BeforeReset {
		t.Fatalf("forecast = %+v", f)
	}
	if d := f.WallAt.Sub(now); d < 49*time.Minute || d > 51*time.Minute {
		t.Fatalf("wall in %v, want ≈50 min", d)
	}
	// A reset sooner than the wall: no wall before it.
	if got := d.forecasts("a", windowSnap(now, 50, 20*time.Minute), now); len(got) != 1 || got[0].BeforeReset {
		t.Fatalf("a reset before the wall still warned: %+v", got)
	}
	// A full window, or a closed one: nothing.
	if got := d.forecasts("a", windowSnap(now, 100, time.Hour), now); len(got) != 0 {
		t.Fatalf("a full window was forecast: %+v", got)
	}
	if got := d.forecasts("a", windowSnap(now, 50, -time.Minute), now); len(got) != 0 {
		t.Fatalf("a closed window was forecast: %+v", got)
	}
}

func TestStateCarriesTheForecast(t *testing.T) {
	st := testStore(t)
	now := time.Now()
	if err := st.SaveSnapshot(windowSnap(now, 50, 3*time.Hour)); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st}
	d.init()
	climb(d, now, 50, 3)
	s, err := d.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range s.Accounts {
		if a.ID == "a" && (len(a.Forecasts) != 1 || !a.Forecasts[0].BeforeReset) {
			t.Fatalf("state forecast = %+v", a.Forecasts)
		}
	}
}

// One notice a window, only when the wall is within the hour and before
// the reset, and only with usage notifications on.
func TestPaceNoticeOncePerWindow(t *testing.T) {
	st := testStore(t)
	var mu sync.Mutex
	var notes []string
	d := &Daemon{Store: st, NotifyUser: func(_ context.Context, _, body string) {
		mu.Lock()
		notes = append(notes, body)
		mu.Unlock()
	}}
	d.init()
	now := time.Now()
	acct := store.Account{ID: "a", Label: "a"}
	climb(d, now, 50, 3)

	snap := windowSnap(now, 50, 3*time.Hour)
	d.checkPace(context.Background(), acct, snap)
	d.checkPace(context.Background(), acct, snap) // same window: no repeat
	if len(notes) != 1 || !strings.Contains(notes[0], "at this pace you hit the 5-hour limit around") ||
		!strings.Contains(notes[0], "before it resets at") {
		t.Fatalf("notes = %q", notes)
	}
	// A new window re-arms it.
	d.checkPace(context.Background(), acct, windowSnap(now, 50, 4*time.Hour))
	if len(notes) != 2 {
		t.Fatalf("a new window did not re-arm the notice: %q", notes)
	}

	// A wall further than an hour out: not yet.
	d2 := &Daemon{Store: st, NotifyUser: d.NotifyUser}
	d2.init()
	climb(d2, now, 20, 1) // 20%/h → wall 4 h out
	d2.checkPace(context.Background(), acct, windowSnap(now, 20, 5*time.Hour))
	if len(notes) != 2 {
		t.Fatalf("a wall 4 h out notified: %q", notes)
	}

	// Usage notifications off: silent.
	cfg, err := st.Config()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Notifications.Disabled = true
	if err := st.SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	d3 := &Daemon{Store: st, NotifyUser: d.NotifyUser}
	d3.init()
	climb(d3, now, 50, 3)
	d3.checkPace(context.Background(), acct, windowSnap(now, 50, 3*time.Hour))
	if len(notes) != 2 {
		t.Fatalf("notified with usage notifications off: %q", notes)
	}
}

func TestRoughDuration(t *testing.T) {
	for d, want := range map[time.Duration]string{50 * time.Minute: "50 min", 2 * time.Hour: "2 h", 80 * time.Minute: "1 h 20 min",
		29 * time.Hour: "1 day 5 h", 48 * time.Hour: "2 days"} {
		if got := roughDuration(d); got != want {
			t.Errorf("roughDuration(%v) = %q, want %q", d, got, want)
		}
	}
}

// Notifications turned on mid-window still warn: a window is only marked
// once its notice really went out.
func TestPaceNoticeAfterNotificationsTurnOn(t *testing.T) {
	st := testStore(t)
	cfg, err := st.Config()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Notifications.Disabled = true
	if err := st.SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	var notes []string
	d := &Daemon{Store: st, NotifyUser: func(_ context.Context, _, body string) { notes = append(notes, body) }}
	d.init()
	now := time.Now()
	climb(d, now, 50, 3)
	acct := store.Account{ID: "a", Label: "a"}
	snap := windowSnap(now, 50, 3*time.Hour)
	d.checkPace(context.Background(), acct, snap)
	if len(notes) != 0 {
		t.Fatalf("notified while off: %q", notes)
	}
	cfg.Notifications.Disabled = false
	if err := st.SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
	d.checkPace(context.Background(), acct, snap)
	if len(notes) != 1 {
		t.Fatalf("turned on mid-window, notices = %q, want one", notes)
	}
}

// An account with no 5-hour limit is forecast on its weekly limit, from the
// week's average pace — and never on a 5-hour window it does not have.
func TestWeeklyForecastWithoutAFiveHourLimit(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	d.init()
	now := time.Now()
	reset := now.Add(4 * 24 * time.Hour) // 3 days into the week
	snap := &store.UsageSnapshot{AccountID: "a", AsOf: now.UTC(), Buckets: []store.Bucket{
		{Kind: "weekly_all", Percent: 54, ResetsAt: &reset, Active: true},
		{Kind: "weekly_scoped", Scope: "Fable", ResetsAt: &reset},
	}}
	got := d.forecasts("a", snap, now)
	if len(got) != 1 || got[0].Kind != "weekly_all" {
		t.Fatalf("want one weekly forecast, got %+v", got)
	}
	// 54% in 72 h = 0.75 %/h → 46% left lands ≈61 h out, before a reset 96 h out.
	f := got[0]
	if f.PerHour != 0.75 || f.WallAt == nil || !f.BeforeReset {
		t.Fatalf("forecast = %+v", f)
	}
	if h := f.WallAt.Sub(now).Hours(); h < 60 || h > 62 {
		t.Fatalf("wall in %.1f h, want ≈61", h)
	}
	// Too early in the week to judge: nothing.
	early := now.Add(7*24*time.Hour - 6*time.Hour)
	snap.Buckets[0].ResetsAt = &early
	if got := d.forecasts("a", snap, now); len(got) != 0 {
		t.Fatalf("forecast six hours into a week: %+v", got)
	}
}

// The week gets one notice, when its wall is within a day and before the reset.
func TestWeeklyPaceNotice(t *testing.T) {
	st := testStore(t)
	var notes []string
	d := &Daemon{Store: st, NotifyUser: func(_ context.Context, _, body string) { notes = append(notes, body) }}
	d.init()
	now := time.Now()
	acct := store.Account{ID: "a", Label: "a"}
	// 90% after 6 days: the wall is ≈16 h out, the reset 24 h out.
	reset := now.Add(24 * time.Hour)
	snap := &store.UsageSnapshot{AccountID: "a", AsOf: now.UTC(), Buckets: []store.Bucket{{Kind: "weekly_all", Percent: 90, ResetsAt: &reset}}}
	d.checkPace(context.Background(), acct, snap)
	d.checkPace(context.Background(), acct, snap)
	if len(notes) != 1 || !strings.Contains(notes[0], "this week's pace you hit the weekly limit around") {
		t.Fatalf("notes = %q", notes)
	}
	// Far from the wall: no notice.
	d2 := &Daemon{Store: st, NotifyUser: d.NotifyUser}
	d2.init()
	far := now.Add(4 * 24 * time.Hour)
	d2.checkPace(context.Background(), acct, &store.UsageSnapshot{AccountID: "a", AsOf: now.UTC(),
		Buckets: []store.Bucket{{Kind: "weekly_all", Percent: 54, ResetsAt: &far}}})
	if len(notes) != 1 {
		t.Fatalf("a wall days away notified: %q", notes)
	}
}
