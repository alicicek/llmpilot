package pilotapi

import "time"

// Defaults per the decision ledger: auto-switch ON, threshold ~90%,
// configurable via $LLMPILOT_HOME/config.json.
const (
	DefaultThreshold      = 90.0
	DefaultCooldown       = 15 * time.Minute
	DefaultMaxSnapshotAge = 15 * time.Minute
)

// Adaptive time-to-wall defaults (owner 2026-08-13, docs/research/
// ADAPTIVE-TIME-TO-WALL-2026-08-13.md). These are the SHIPPED numbers;
// they tune via config only, never per-release churn.
const (
	// DefaultRunwayFloor: switch when the projected wall is nearer than
	// this — 2 poll cycles (~6 min) + swap overhead.
	DefaultRunwayFloor = 8 * time.Minute
	// AdaptiveUtilFloor: adaptive never switches below this utilization —
	// churn protection (with MaxPlausibleBurn the floor is also structural:
	// a clamped burn cannot project an 8-minute wall from below ~60%).
	AdaptiveUtilFloor = 60.0
	// MaxPlausibleBurn clamps a smoothed slope (percent per minute) so one
	// burst can never project TTW≈0 from a half-empty bucket.
	MaxPlausibleBurn = 5.0
)

// AdaptiveCeiling is the hard stop for riding an account's bucket when
// burn data says there is runway (and the idle bound when there is data
// but no burn): the plan's usage multiple decides how much a blind poll
// window can cost. Unknown multipliers get the safest ceiling — never a
// guess.
func AdaptiveCeiling(tierMultiplier int) float64 {
	switch tierMultiplier {
	case 20:
		return 97
	case 5:
		return 95
	default:
		return 92 // Pro-class and unknown (Team raw values unobserved)
	}
}

// BucketKey identifies one bucket inside Candidate.Burn — the same
// (kind, scope) pair the buckets themselves carry.
func BucketKey(kind, scope string) string { return kind + "|" + scope }

// TimeToWall projects when a bucket hits 100% at the given burn rate
// (percent per minute). Returns (0, false) when the burn is too small to
// project anything — an idle bucket has no wall coming.
func TimeToWall(percent, burnPerMin float64) (time.Duration, bool) {
	if burnPerMin < 0.01 {
		return 0, false
	}
	if burnPerMin > MaxPlausibleBurn {
		burnPerMin = MaxPlausibleBurn
	}
	remaining := 100 - percent
	if remaining <= 0 {
		return 0, true
	}
	return time.Duration(remaining / burnPerMin * float64(time.Minute)), true
}

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
	// Adaptive switches the ACTIVE account on projected time-to-wall
	// instead of the fixed threshold (owner 2026-08-13). An explicit
	// ThresholdPercent in config turns it OFF — the user chose fixed mode
	// and it is honored verbatim, forever. Threshold stays meaningful
	// either way: it is the cold-start fallback and the target-eligibility
	// bar (arrive somewhere with ≥10% room; leave as late as data allows).
	Adaptive bool
	// RunwayFloor: with burn data, switch when the projected wall is
	// nearer than this.
	RunwayFloor time.Duration
}

// ParamsFrom applies ledger defaults over the user's config. Adaptive is
// the default; an explicit ThresholdPercent is the user choosing fixed
// mode.
func ParamsFrom(c AutopilotConfig) Params {
	p := Params{
		Enabled:        !c.Disabled,
		Threshold:      DefaultThreshold,
		Cooldown:       DefaultCooldown,
		MaxSnapshotAge: DefaultMaxSnapshotAge,
		Adaptive:       c.ThresholdPercent == 0,
		RunwayFloor:    DefaultRunwayFloor,
	}
	if c.ThresholdPercent > 0 {
		p.Threshold = c.ThresholdPercent
	}
	if c.CooldownMinutes > 0 {
		p.Cooldown = time.Duration(c.CooldownMinutes) * time.Minute
	}
	if c.RunwayMinutes > 0 {
		p.RunwayFloor = time.Duration(c.RunwayMinutes) * time.Minute
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
	// Burn is the smoothed live burn rate per bucket (percent per minute,
	// keyed BucketKey(kind, scope)), computed by the daemon from its
	// history ring. A missing key or nil map means NO reliable data (cold
	// start, daemon restart, too few samples) — the policy falls back to
	// the fixed threshold, never guesses. A present 0 means genuinely
	// idle, which is a different fact.
	Burn map[string]float64
	// TierMultiplier is the plan's usage multiple of Pro (1, 5, 20; 0
	// unknown), from the claudecfg adapter. The daemon sets it for the
	// ACTIVE candidate only (the active's config dir is the one whose
	// identity is verifiably its own); the policy uses it only for the
	// adaptive ceiling.
	TierMultiplier int
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
	// PinnedHeadroom names the pinned (watch-only) account that WOULD have
	// qualified on usage alone — live, fresh snapshot, below threshold —
	// when a hold found no switchable account with headroom; most headroom
	// wins, zero when none qualifies. The one hold the user can fix
	// themselves: the daemon turns it into the "move it into the fleet"
	// nudge. The policy still never nominates a pinned target.
	PinnedHeadroom Account
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
