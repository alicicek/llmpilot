package daemon

import (
	"context"
	"fmt"
	"strings"

	"github.com/alicicek/llmpilot/internal/store"
)

// checkThresholds fires a calm, once-per-crossing notification when a
// bucket's percent rises through a configured threshold. It is driven
// entirely by comparing the two most recent snapshots — no separate
// "already fired" memory is kept, because that comparison alone already
// gives every required property:
//
//   - crosses once: once prev's own percent is at/above a threshold, that
//     threshold's rising-edge condition can never true again until the
//     percent actually dips back below it.
//   - same-window re-poll never re-fires: consecutive polls compare against
//     the immediately preceding (already-saved) snapshot, not some earlier
//     baseline.
//   - a resets_at change re-arms naturally: a new window's percent starts
//     low again, so the next rise re-triggers the same rising-edge check.
//
// prev == nil (this account has never been polled before) skips entirely —
// an account that's already at 80% the moment it's added to llmpilot must
// not immediately fire a burst of "welcome, you're already hot" notices.
func (d *Daemon) checkThresholds(ctx context.Context, a store.Account, prev, snap *store.UsageSnapshot) {
	if prev == nil {
		return
	}
	cfg, err := d.Store.Config()
	if err != nil {
		d.Log.Warn("config unreadable — thresholds skipped", "account", a.ID, "err", err)
		return
	}
	if cfg.Notifications.Disabled {
		return
	}
	thresholds := cfg.Notifications.EffectiveThresholds() // sorted ascending
	if len(thresholds) == 0 {
		return
	}

	for _, b := range snap.Buckets {
		if b.ResetsAt == nil {
			continue // nothing to re-arm on — no notion of "this window"
		}
		prevPercent := 0.0
		for _, pb := range prev.Buckets {
			if pb.Kind == b.Kind && pb.Scope == b.Scope {
				prevPercent = pb.Percent
				break
			}
		}
		// Multiple thresholds can cross in one jump (e.g. 60% → 95% between
		// two polls); thresholds is ascending, so the last crossed one found
		// is the highest — fire only that one.
		crossedMax := -1.0
		for _, th := range thresholds {
			if prevPercent < th && b.Percent >= th {
				crossedMax = th
			}
		}
		if crossedMax < 0 {
			continue
		}
		d.fireThreshold(ctx, a, b, crossedMax)
	}
}

func (d *Daemon) fireThreshold(ctx context.Context, a store.Account, b store.Bucket, threshold float64) {
	resets := ""
	if b.ResetsAt != nil {
		resets = b.ResetsAt.Local().Format("15:04")
	}
	msg := fmt.Sprintf("%s %s at %.0f%% — resets %s", a.Label, bucketLabel(b), b.Percent, resets)
	if err := d.Store.AppendEvent(store.Event{Kind: "threshold", AccountID: a.ID, Message: msg}); err != nil {
		d.Log.Error("append event", "err", err)
	}
	d.notify(ctx)
	if d.NotifyUser != nil {
		// VOICE: calm, no exclamation — title is always the plain product name.
		d.NotifyUser(ctx, "llmpilot", msg)
	}
	d.Log.Info("threshold notification", "account", a.ID, "kind", b.Kind, "scope", b.Scope,
		"threshold", threshold, "percent", b.Percent)
}

// bucketLabel is a local, minimal stand-in for internal/cli's
// render.BucketLabel: internal/cli depends on internal/daemon (render.go
// takes a *daemon.State), so internal/daemon cannot import internal/cli
// without a cycle. Kept intentionally small — this is copy for a
// notification body, not the fleet's canonical bucket rendering.
func bucketLabel(b store.Bucket) string {
	switch {
	case b.Kind == "session" || b.Kind == "five_hour":
		return "session"
	case b.Kind == "weekly_all" || b.Kind == "seven_day":
		return "weekly"
	case b.Scope != "":
		return strings.ToLower(b.Scope)
	default:
		return b.Kind
	}
}
