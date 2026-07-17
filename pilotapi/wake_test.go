package pilotapi

import (
	"path/filepath"
	"testing"
	"time"
)

func TestNextFire(t *testing.T) {
	sc := Schedule{ID: "x", AccountID: "a", Hour: 4, Minute: 30}
	now := time.Date(2026, 7, 10, 3, 0, 0, 0, time.UTC)
	if got := NextFire(now, sc); got != time.Date(2026, 7, 10, 4, 30, 0, 0, time.UTC) {
		t.Fatalf("before slot: %v", got)
	}
	now = time.Date(2026, 7, 10, 4, 30, 0, 0, time.UTC) // exactly at the slot
	if got := NextFire(now, sc); got.Day() != 11 {
		t.Fatalf("at slot must roll to tomorrow: %v", got)
	}
	now = time.Date(2026, 7, 10, 23, 59, 0, 0, time.UTC)
	if got := NextFire(now, sc); got.Day() != 11 {
		t.Fatalf("past slot: %v", got)
	}
}

func TestWakeModeAndPlans(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	dir := t.TempDir()
	fake := filepath.Join(dir, "llmpilot-wake")
	t.Setenv("LLMPILOT_SUDOERS", fake)
	if WakeMode() != "degraded" {
		t.Fatal("no sudoers file must mean degraded")
	}

	now := time.Date(2026, 7, 10, 3, 0, 0, 0, time.UTC)
	scheds := []Schedule{{ID: "x", AccountID: "a", Hour: 4, Minute: 0}}
	ps := Plans(now, scheds, WakeMode())
	if len(ps) != 1 || !ps[0].WakeAt.IsZero() {
		t.Fatalf("degraded plan must carry no wake: %+v", ps)
	}

	if err := WriteJSONAtomic(fake, map[string]string{"fake": "sudoers"}); err != nil {
		t.Fatal(err)
	}
	if WakeMode() != "armed" {
		t.Fatal("sudoers file present must mean armed")
	}
	ps = Plans(now, scheds, WakeMode())
	if got := ps[0].FireAt.Sub(ps[0].WakeAt); got != Lead {
		t.Fatalf("armed wake must lead the fire by %v, got %v", Lead, got)
	}
}
