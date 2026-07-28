package daemon

// Demo mode (LLMPILOT_DEMO=1) serves a masked, launch-quality fleet so
// onboarding can show the product working before any account is registered, and
// so README media and site media render from ONE source. It is read-only:
// no Keychain, no network, no launchd — the daemon seeds a throwaway store and
// leaves Fetch/Switch/Wake nil.

import (
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

func at(t time.Time) *time.Time { return &t }

// DemoFleet returns four fictional accounts with mixed buckets, severities,
// schedules, and a short autopilot event log — all relative to now so the
// render always looks fresh. Identities are invented; no owner data appears.
func DemoFleet(now time.Time) (accounts []store.Account, snapshots []*store.UsageSnapshot, schedules []store.Schedule, events []store.Event, activeID string) {
	accounts = []store.Account{
		{ID: "kai", Label: "kai", Email: "kai@studioloop.dev"},
		{ID: "rin", Label: "rin", Email: "rin@ashgrove.io"},
		{ID: "mara", Label: "mara", Email: "mara@driftwork.co", Pinned: true},
		{ID: "theo", Label: "theo", Email: "theo@northpad.dev"},
	}
	snapshots = []*store.UsageSnapshot{
		{AccountID: "kai", AsOf: now, Buckets: []store.Bucket{
			{Kind: "session", Percent: 92, Severity: "critical", ResetsAt: at(now.Add(38 * time.Minute)), Active: true},
			{Kind: "weekly_all", Percent: 61, ResetsAt: at(now.Add(3 * 24 * time.Hour))},
			{Kind: "weekly_scoped", Scope: "Fable", Percent: 74, Severity: "warning", ResetsAt: at(now.Add(3 * 24 * time.Hour))},
		}},
		{AccountID: "rin", AsOf: now, Buckets: []store.Bucket{
			{Kind: "session", Percent: 44, ResetsAt: at(now.Add(3*time.Hour + 10*time.Minute)), Active: true},
			{Kind: "weekly_all", Percent: 37, ResetsAt: at(now.Add(4 * 24 * time.Hour))},
		}},
		{AccountID: "mara", AsOf: now, Buckets: []store.Bucket{
			{Kind: "session", Percent: 12, ResetsAt: at(now.Add(4 * time.Hour))},
			{Kind: "weekly_all", Percent: 88, Severity: "warning", ResetsAt: at(now.Add(2 * 24 * time.Hour))},
			{Kind: "weekly_scoped", Scope: "Opus", Percent: 95, Severity: "critical", ResetsAt: at(now.Add(2 * 24 * time.Hour))},
		}},
		{AccountID: "theo", AsOf: now, Buckets: []store.Bucket{
			{Kind: "session", Percent: 7, ResetsAt: at(now.Add(4*time.Hour + 55*time.Minute))},
			{Kind: "weekly_all", Percent: 21, ResetsAt: at(now.Add(5 * 24 * time.Hour))},
		}},
	}
	schedules = []store.Schedule{
		{ID: pilotapi.ScheduleID("kai", 9, 0), AccountID: "kai", Hour: 9, Minute: 0, Model: "fable"},
		{ID: pilotapi.ScheduleID("mara", 8, 30), AccountID: "mara", Hour: 8, Minute: 30},
	}
	// Oldest first: Events(n) returns the tail oldest-first, so this order is how
	// the log reads. Copy uses "switched", never "rotated" (user-facing rule).
	events = []store.Event{
		{At: now.Add(-8 * time.Hour), Kind: "wake", AccountID: "mara", Message: "armed wake for mara at 08:30"},
		{At: now.Add(-3 * time.Hour), Kind: "window", AccountID: "theo", Message: "started theo's 5-hour window at 09:00"},
		{At: now.Add(-6 * time.Minute), Kind: "switch", AccountID: "rin", Message: "switched to rin — kai hit 92% on the 5-hour window"},
	}
	return accounts, snapshots, schedules, events, "rin"
}

// SeedDemo writes the demo fleet into a throwaway store. Callers pass a temp
// store; nothing here touches the user's real ~/.llmpilot.
func SeedDemo(st *store.Store, now time.Time) (activeID string, err error) {
	accounts, snapshots, schedules, events, active := DemoFleet(now)
	if err := st.SaveAccounts(accounts); err != nil {
		return "", err
	}
	for _, snap := range snapshots {
		if err := st.SaveSnapshot(snap); err != nil {
			return "", err
		}
	}
	if err := st.SaveSchedules(schedules); err != nil {
		return "", err
	}
	for _, e := range events {
		if err := st.AppendEvent(e); err != nil {
			return "", err
		}
	}
	return active, nil
}
