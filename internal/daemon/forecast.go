package daemon

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// BucketForecast is an open 5-hour window's pace, from the same live burn
// the autopilot switches on: percent per hour, and when it reaches 100% at
// that pace. Only the 5-hour window is forecast — a fifteen-minute burn
// stretched over a week would promise a wall that will not come.
type BucketForecast struct {
	Kind    string  `json:"kind"`
	Scope   string  `json:"scope,omitempty"`
	PerHour float64 `json:"per_hour"`
	// WallAt is when the window reaches 100% at this pace; nil when the pace
	// is too slow to reach it at all.
	WallAt *time.Time `json:"wall_at,omitempty"`
	// BeforeReset is whether WallAt lands before the window resets.
	BeforeReset bool `json:"before_reset,omitempty"`
}

// paceNoticeLead is how close a wall before the reset must be for the one
// notification a window gets: early in a window the pace still swings.
const paceNoticeLead = time.Hour

const (
	// weekLength is the weekly limit's window.
	weekLength = 7 * 24 * time.Hour
	// weeklyMinElapsed is how much of a week must have passed before its
	// average pace means anything.
	weeklyMinElapsed = 12 * time.Hour
	// weeklyNoticeLead is how close a weekly wall before the reset must be
	// for the week's one notification.
	weeklyNoticeLead = 24 * time.Hour
)

// forecasts projects an account's open 5-hour windows. Nothing when the
// burn is not yet known (it needs a quarter hour of polls) or the window is
// already full.
func (d *Daemon) forecasts(accountID string, snap *store.UsageSnapshot, now time.Time) []BucketForecast {
	if snap == nil {
		return nil
	}
	if pilotapi.NoFiveHourLimit(snap) {
		return weeklyForecasts(snap, now)
	}
	var out []BucketForecast
	for _, b := range snap.Buckets {
		if (b.Kind != "session" && b.Kind != "five_hour") || b.ResetsAt == nil || !b.ResetsAt.After(now) || b.Percent >= 100 {
			continue
		}
		rate, ok := d.burnRate(accountID, b.Kind, b.Scope, now)
		if !ok {
			continue
		}
		f := BucketForecast{Kind: b.Kind, Scope: b.Scope, PerHour: math.Round(rate*60*10) / 10}
		if dur, ok := pilotapi.TimeToWall(b.Percent, rate); ok {
			wall := snap.AsOf.Add(dur).Truncate(time.Minute)
			f.WallAt = &wall
			f.BeforeReset = wall.Before(*b.ResetsAt)
		}
		out = append(out, f)
	}
	return out
}

// weeklyForecasts is the pace of an account with no 5-hour limit (verified
// accounts on some plans): its weekly limit is the only wall. The week's
// average pace — usage so far over the time since the week began — needs no
// poll history and does not swing with one busy hour.
func weeklyForecasts(snap *store.UsageSnapshot, now time.Time) []BucketForecast {
	var out []BucketForecast
	for _, b := range snap.Buckets {
		if b.Kind != "weekly_all" && b.Kind != "seven_day" {
			continue
		}
		if b.ResetsAt == nil || !b.ResetsAt.After(now) || b.Percent <= 0 || b.Percent >= 100 {
			continue
		}
		elapsed := snap.AsOf.Sub(b.ResetsAt.Add(-weekLength))
		if elapsed < weeklyMinElapsed {
			continue
		}
		perHour := b.Percent / elapsed.Hours()
		wall := snap.AsOf.Add(time.Duration((100 - b.Percent) / perHour * float64(time.Hour))).Truncate(time.Minute)
		out = append(out, BucketForecast{
			Kind: b.Kind, Scope: b.Scope, PerHour: math.Round(perHour*100) / 100,
			WallAt: &wall, BeforeReset: wall.Before(*b.ResetsAt),
		})
	}
	return out
}

// checkPace sends the one "you will hit the limit" notification a window
// gets: when, at the live pace, its 5-hour window reaches 100% within the
// next hour and before it resets. The usage-notifications setting governs it
// like the threshold notices.
func (d *Daemon) checkPace(ctx context.Context, a store.Account, snap *store.UsageSnapshot) {
	now := time.Now()
	for _, f := range d.forecasts(a.ID, snap, now) {
		weekly := f.Kind == "weekly_all" || f.Kind == "seven_day"
		lead := paceNoticeLead
		if weekly {
			lead = weeklyNoticeLead
		}
		if !f.BeforeReset || f.WallAt == nil || f.WallAt.Sub(now) > lead {
			continue
		}
		var reset time.Time
		for _, b := range snap.Buckets {
			if b.Kind == f.Kind && b.Scope == f.Scope && b.ResetsAt != nil {
				// To the minute: a reset the server reports a second off
				// between polls is the same window.
				reset = b.ResetsAt.Truncate(time.Minute)
			}
		}
		// The setting first: a window is only marked once its notice really
		// went out, so turning notifications on mid-window still warns.
		cfg, err := d.Store.Config()
		if err != nil || cfg.Notifications.Disabled {
			continue
		}
		d.mu.Lock()
		if d.paceNoticed == nil {
			d.paceNoticed = map[string]time.Time{}
		}
		if d.paceNoticed[a.ID].Equal(reset) {
			d.mu.Unlock()
			continue // this window already had its notice
		}
		d.paceNoticed[a.ID] = reset
		d.mu.Unlock()

		msg := fmt.Sprintf("%s: at this pace you hit the 5-hour limit around %s — %s before it resets at %s",
			a.Label, f.WallAt.Local().Format("15:04"), roughDuration(reset.Sub(*f.WallAt)), reset.Local().Format("15:04"))
		if weekly {
			msg = fmt.Sprintf("%s: at this week's pace you hit the weekly limit around %s — %s before it resets %s",
				a.Label, f.WallAt.Local().Format("Mon 15:04"), roughDuration(reset.Sub(*f.WallAt)), reset.Local().Format("Mon 15:04"))
		}
		if err := d.Store.AppendEvent(store.Event{Kind: "pace", AccountID: a.ID, Message: msg}); err != nil {
			d.Log.Error("append event", "err", err)
		}
		d.notify(ctx)
		if d.NotifyUser != nil {
			d.NotifyUser(ctx, "llmpilot", msg)
		}
	}
}

// roughDuration is "50 min", "1 h 20 min" or "1 day 5 h" — copy, not
// arithmetic.
func roughDuration(d time.Duration) string {
	m := int(d.Round(time.Minute).Minutes())
	if m < 60 {
		return fmt.Sprintf("%d min", m)
	}
	if m >= 24*60 {
		days, h := m/(24*60), m%(24*60)/60
		unit := "days"
		if days == 1 {
			unit = "day"
		}
		if h == 0 {
			return fmt.Sprintf("%d %s", days, unit)
		}
		return fmt.Sprintf("%d %s %d h", days, unit, h)
	}
	if m%60 == 0 {
		return fmt.Sprintf("%d h", m/60)
	}
	return fmt.Sprintf("%d h %d min", m/60, m%60)
}
