package pilotapi

import (
	"testing"
	"time"
)

func TestPlannedStart(t *testing.T) {
	now := time.Date(2026, 11, 1, 15, 0, 0, 0, time.UTC)
	at := func(h, m int) *time.Time { v := time.Date(2026, 11, 1, h, m, 0, 0, time.UTC); return &v }
	open := &UsageSnapshot{Buckets: []Bucket{{Kind: "five_hour", Percent: 11, ResetsAt: at(18, 30), Active: true}}}
	closed := &UsageSnapshot{Buckets: []Bucket{{Kind: "five_hour", Percent: 0, ResetsAt: at(14, 0)}}}
	none := &UsageSnapshot{Buckets: []Bucket{{Kind: "weekly_all", Percent: 54}, {Kind: "weekly_scoped", Scope: "Fable"}}}
	// An account with a 5-hour limit lists it even with no window open
	// (testdata/fixtures/usage-cool.json).
	idle := &UsageSnapshot{Buckets: []Bucket{{Kind: "session", Percent: 0}, {Kind: "weekly_all", Percent: 20}}}
	openNoEnd := &UsageSnapshot{Buckets: []Bucket{{Kind: "session", Active: true}}}

	cases := []struct {
		name   string
		plan   WindowPlan
		snap   *UsageSnapshot
		want   time.Time
		wantOK bool
	}{
		{"rolling: at the open window's reset", WindowPlan{Rolling: true}, open, at(18, 30).Add(StartMargin), true},
		{"rolling: none open starts now", WindowPlan{Rolling: true}, closed, now, true},
		{"rolling: no 5-hour limit at all has nothing to start", WindowPlan{Rolling: true}, none, time.Time{}, false},
		{"one-tap: no 5-hour limit at all has nothing to start", WindowPlan{NextAt: at(18, 30)}, none, time.Time{}, false},
		{"rolling: an idle 5-hour limit starts now", WindowPlan{Rolling: true}, idle, now, true},
		{"rolling: no snapshot yet waits", WindowPlan{Rolling: true}, nil, time.Time{}, false},
		{"open with no known end: nothing to aim at", WindowPlan{Rolling: true}, openNoEnd, time.Time{}, false},
		{"one-tap at the reset", WindowPlan{NextAt: at(18, 30)}, open, at(18, 30).Add(StartMargin), true},
		{"one-tap never inside an open window", WindowPlan{NextAt: at(17, 0)}, open, at(18, 30).Add(StartMargin), true},
		{"one-tap without a snapshot", WindowPlan{NextAt: at(18, 30)}, nil, at(18, 30).Add(StartMargin), true},
		{"empty plan", WindowPlan{}, open, time.Time{}, false},
	}
	for _, tc := range cases {
		got, ok := PlannedStart(now, tc.plan, tc.snap)
		if ok != tc.wantOK || !got.Equal(tc.want) {
			t.Errorf("%s: PlannedStart = %v, %v; want %v, %v", tc.name, got, ok, tc.want, tc.wantOK)
		}
	}
}

func TestLiveSchedulesPausesARollingAccountsFixedTimes(t *testing.T) {
	scheds := []Schedule{{ID: "a1", AccountID: "a"}, {ID: "b1", AccountID: "b"}, {ID: "a2", AccountID: "a"}}
	got := LiveSchedules(scheds, []WindowPlan{{AccountID: "a", Rolling: true}, {AccountID: "b"}})
	if len(got) != 1 || got[0].ID != "b1" {
		t.Fatalf("live = %+v, want only b1", got)
	}
	if got := LiveSchedules(scheds, nil); len(got) != 3 {
		t.Fatalf("no plans paused something: %+v", got)
	}
}

func TestNoFiveHourLimit(t *testing.T) {
	for name, tc := range map[string]struct {
		snap *UsageSnapshot
		want bool
	}{
		"verified Ultra: weekly only":         {&UsageSnapshot{Buckets: []Bucket{{Kind: "weekly_all"}, {Kind: "weekly_scoped", Scope: "Fable"}}}, true},
		"a 5-hour limit, window open":         {&UsageSnapshot{Buckets: []Bucket{{Kind: "session", Active: true}, {Kind: "weekly_all"}}}, false},
		"a 5-hour limit, idle":                {&UsageSnapshot{Buckets: []Bucket{{Kind: "session"}, {Kind: "weekly_all"}}}, false},
		"legacy shape":                        {&UsageSnapshot{Buckets: []Bucket{{Kind: "five_hour"}, {Kind: "seven_day"}}}, false},
		"no snapshot yet: unknown":            {nil, false},
		"a snapshot with no buckets: unknown": {&UsageSnapshot{}, false},
	} {
		if got := NoFiveHourLimit(tc.snap); got != tc.want {
			t.Errorf("%s: NoFiveHourLimit = %v, want %v", name, got, tc.want)
		}
	}
}
