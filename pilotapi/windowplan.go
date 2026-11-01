package pilotapi

import "time"

// WindowPlan is one account's automatic window starts. Rolling starts the
// next 5-hour window the moment each one resets, for as long as it is on;
// NextAt starts one window at one moment — the board's one-tap "start the
// next window at 18:30" — and is cleared once used.
type WindowPlan struct {
	AccountID string     `json:"account_id"`
	Rolling   bool       `json:"rolling,omitempty"`
	NextAt    *time.Time `json:"next_at,omitempty"`
}

// Empty reports a plan that asks for nothing (and need not be stored).
func (p WindowPlan) Empty() bool { return !p.Rolling && p.NextAt == nil }

// StartMargin is how long after a reset a planned start fires: the usage
// endpoint must already see the old window closed, or the cannot-shift
// check refuses the start.
const StartMargin = 30 * time.Second

// PlannedStart is when plan wants the account's next window started, read
// from the account's latest usage snapshot; ok=false means nothing is due.
// Rolling starts at the open window's reset, or now when none is open; with
// no snapshot yet it waits for the first poll rather than start blind.
// NextAt starts at that moment — never inside a window that is still open.
func PlannedStart(now time.Time, plan WindowPlan, snap *UsageSnapshot) (time.Time, bool) {
	if NoFiveHourLimit(snap) {
		return time.Time{}, false // no window to start
	}
	var reset *time.Time
	known := snap != nil
	if known {
		var open bool
		open, reset = windowOpen(now, snap.Buckets)
		if open && reset == nil {
			return time.Time{}, false // open with no known end: nothing to aim at
		}
	}
	if plan.Rolling {
		if !known {
			return time.Time{}, false
		}
		if reset == nil {
			return now, true
		}
		return reset.Add(StartMargin), true
	}
	if plan.NextAt != nil {
		at := plan.NextAt.Add(StartMargin)
		if reset != nil && reset.Add(StartMargin).After(at) {
			at = reset.Add(StartMargin)
		}
		return at, true
	}
	return time.Time{}, false
}

// NoFiveHourLimit reports an account whose usage carries no 5-hour limit at
// all — Anthropic drops it for verified accounts on some plans (Ultra, from
// 2026-10-30), account by account — as opposed to one whose window is just
// not open: an account with a 5-hour limit lists it even while idle. With no
// snapshot, or one with no buckets, it is unknown and reports false.
func NoFiveHourLimit(snap *UsageSnapshot) bool {
	if snap == nil || len(snap.Buckets) == 0 {
		return false
	}
	for _, b := range snap.Buckets {
		if b.Kind == "session" || b.Kind == "five_hour" {
			return false
		}
	}
	return true
}

// windowOpen mirrors the engine's WindowActive: a known reset in the past
// means the window closed whatever the cached Active flag says.
func windowOpen(now time.Time, buckets []Bucket) (bool, *time.Time) {
	for _, b := range buckets {
		if b.Kind != "session" && b.Kind != "five_hour" {
			continue
		}
		if b.ResetsAt != nil {
			if b.ResetsAt.After(now) {
				r := *b.ResetsAt
				return true, &r
			}
			continue
		}
		if b.Active {
			return true, nil
		}
	}
	return false, nil
}

// LiveSchedules is the schedules that fire: an account that keeps its
// windows rolling has its fixed daily times paused (kept, not deleted, so
// they come back exactly as they were when rolling is switched off).
func LiveSchedules(scheds []Schedule, plans []WindowPlan) []Schedule {
	rolling := map[string]bool{}
	for _, p := range plans {
		if p.Rolling {
			rolling[p.AccountID] = true
		}
	}
	out := make([]Schedule, 0, len(scheds))
	for _, sc := range scheds {
		if !rolling[sc.AccountID] {
			out = append(out, sc)
		}
	}
	return out
}
