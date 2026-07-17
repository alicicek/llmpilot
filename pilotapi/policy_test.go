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
