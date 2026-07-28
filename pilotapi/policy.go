package pilotapi

import "time"

// Defaults per the decision ledger: auto-switch ON, threshold ~90%,
// configurable via $LLMPILOT_HOME/config.json.
const (
	DefaultThreshold      = 90.0
	DefaultCooldown       = 15 * time.Minute
	DefaultMaxSnapshotAge = 15 * time.Minute
)

// Params is the rotation rule set derived from user config. This is display
// math, not engine IP: the statusline's rotation preview and the cockpit
// render eligibility from it whether or not the engine is present.
type Params struct {
	Enabled bool
	// Threshold is the utilization percent at which the active account
	// rotates away — switch before the wall, notify after.
	Threshold float64
	// Cooldown suppresses rotation for a period after the last switch
	// attempt so a borderline fleet never flaps.
	Cooldown time.Duration
	// MaxSnapshotAge is how old a cached snapshot may be and still justify
	// a rotation decision — stale data never drives a credential write.
	MaxSnapshotAge time.Duration
}

// ParamsFrom applies ledger defaults over the user's config.
func ParamsFrom(c AutopilotConfig) Params {
	p := Params{
		Enabled:        !c.Disabled,
		Threshold:      DefaultThreshold,
		Cooldown:       DefaultCooldown,
		MaxSnapshotAge: DefaultMaxSnapshotAge,
	}
	if c.ThresholdPercent > 0 {
		p.Threshold = c.ThresholdPercent
	}
	if c.CooldownMinutes > 0 {
		p.Cooldown = time.Duration(c.CooldownMinutes) * time.Minute
	}
	return p
}

// Fresh reports whether a snapshot exists and is recent enough to act on.
func (p Params) Fresh(now time.Time, snap *UsageSnapshot) bool {
	return snap != nil && now.Sub(snap.AsOf) <= p.MaxSnapshotAge
}

// Candidate is one account plus its latest cached snapshot (nil if never
// polled).
type Candidate struct {
	Account  Account
	Snapshot *UsageSnapshot
	// Stale marks an account whose stored token expired while idle (the
	// daemon's stale gate froze its snapshot). Its frozen utilization is an
	// UPPER bound — idle usage only falls as windows reset — so the policy
	// may nominate it for a REVIVE, never for a normal switch. Residual,
	// stated honestly: the same subscription used from another machine can
	// raise real usage above the frozen number; the post-switch first poll
	// reveals it and threshold rotation moves away again.
	Stale bool
}

// Decision says who rotates where and why. Reason is the human line that
// lands in the event log and the macOS notification.
type Decision struct {
	From   Account
	To     Account
	Reason string
	// Revive marks a stale target: the switch must PROVE a live credential
	// (a successful refresh) before installing anything — any skip or
	// failure means hold, never a swap onto a token known to be expired.
	Revive bool
	// Hold reports "wanted to rotate, couldn't": the active account is over
	// threshold and no candidate is eligible. To is zero. The daemon
	// surfaces it as one de-spammed event; benign no-ops (below threshold,
	// cooldown) stay nil so the feed never fills with silence-breakers.
	Hold bool
	// HoldKind is the stable machine key for the hold CLASS. The daemon
	// de-spams hold events on it, never on the rendered Reason — Reason
	// embeds percentages that change every poll and would defeat the dedup.
	HoldKind string
}

// Utilization is an account's limit proximity: the max percent across every
// bucket present, and the kind that drives it. Bucket-agnostic by design —
// if the Fable weekly bucket leaves subscriptions (2026-07-12) it simply
// drops out of the max; an empty or nil snapshot reports zero.
func Utilization(snap *UsageSnapshot) (float64, string) {
	if snap == nil {
		return 0, ""
	}
	max, kind := 0.0, ""
	for _, b := range snap.Buckets {
		if b.Percent > max {
			max, kind = b.Percent, b.Kind
		}
	}
	return max, kind
}

// Policy decides rotations. The engine implements it; free builds have no
// implementation and the daemon leaves its Pilot nil (rotation off).
type Policy interface {
	// Decide returns the rotation to perform now, or nil.
	Decide(now time.Time, activeID string, lastSwitch time.Time, cands []Candidate) *Decision
}
