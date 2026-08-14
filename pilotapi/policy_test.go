package pilotapi

import (
	"testing"
	"time"
)

func TestParamsFromDefaults(t *testing.T) {
	p := ParamsFrom(AutopilotConfig{})
	if !p.Enabled || p.Threshold != 90 || p.Cooldown != 15*time.Minute {
		t.Fatalf("unexpected defaults: %+v", p)
	}
	c := ParamsFrom(AutopilotConfig{Disabled: true, ThresholdPercent: 80, CooldownMinutes: 5})
	if c.Enabled || c.Threshold != 80 || c.Cooldown != 5*time.Minute {
		t.Fatalf("config not applied: %+v", c)
	}
}

func TestUtilizationBucketAgnosticMax(t *testing.T) {
	if u, k := Utilization(nil); u != 0 || k != "" {
		t.Fatalf("nil snapshot must be zero, got %v %q", u, k)
	}
	snap := &UsageSnapshot{Buckets: []Bucket{
		{Kind: "five_hour", Percent: 30},
		{Kind: "brand_new_kind", Percent: 70},
	}}
	u, k := Utilization(snap)
	if u != 70 || k != "brand_new_kind" {
		t.Fatalf("unknown kind must drive the max, got %v %q", u, k)
	}
}

// Adaptive time-to-wall (owner 2026-08-13): the mode flag, the locked
// defaults, and the shared math — each guard's fail case.
func TestAdaptiveParamsAndCeilings(t *testing.T) {
	p := ParamsFrom(AutopilotConfig{})
	if !p.Adaptive || p.RunwayFloor != 8*time.Minute || p.Threshold != 90 {
		t.Fatalf("default config must be adaptive with the 8-min floor and the 90 fallback: %+v", p)
	}
	f := ParamsFrom(AutopilotConfig{ThresholdPercent: 95})
	if f.Adaptive || f.Threshold != 95 {
		t.Fatalf("an explicit threshold is FIXED mode, verbatim: %+v", f)
	}
	r := ParamsFrom(AutopilotConfig{RunwayMinutes: 12})
	if !r.Adaptive || r.RunwayFloor != 12*time.Minute {
		t.Fatalf("runway override not applied: %+v", r)
	}
	for mult, want := range map[int]float64{20: 97, 5: 95, 1: 92, 0: 92, 7: 92} {
		if got := AdaptiveCeiling(mult); got != want {
			t.Fatalf("ceiling(%d) = %v, want %v — unknown must never guess high", mult, got, want)
		}
	}
}

func TestTimeToWall(t *testing.T) {
	if _, coming := TimeToWall(97, 0); coming {
		t.Fatal("an idle bucket has no wall coming")
	}
	if ttw, coming := TimeToWall(80, 4); !coming || ttw != 5*time.Minute {
		t.Fatalf("80%% at 4%%/min must project 5 min, got %v %v", ttw, coming)
	}
	// The clamp: a burst can never project TTW≈0 from a half-empty bucket.
	if ttw, coming := TimeToWall(50, 100); !coming || ttw != 10*time.Minute {
		t.Fatalf("clamped burn must project (100-50)/5 = 10 min, got %v %v", ttw, coming)
	}
	if ttw, coming := TimeToWall(100, 1); !coming || ttw != 0 {
		t.Fatalf("a spent bucket's wall is now, got %v %v", ttw, coming)
	}
}

func TestParamsFresh(t *testing.T) {
	p := ParamsFrom(AutopilotConfig{})
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	if p.Fresh(now, nil) {
		t.Fatal("nil snapshot reported fresh")
	}
	if !p.Fresh(now, &UsageSnapshot{AsOf: now.Add(-time.Minute)}) {
		t.Fatal("fresh snapshot reported stale")
	}
	if p.Fresh(now, &UsageSnapshot{AsOf: now.Add(-time.Hour)}) {
		t.Fatal("stale snapshot reported fresh")
	}
}
