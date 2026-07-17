package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

func TestDemoFleetSeedsAndServes(t *testing.T) {
	st := store.At(t.TempDir())
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	active, err := SeedDemo(st, now)
	if err != nil {
		t.Fatal(err)
	}
	if active != "rin" {
		t.Fatalf("active = %q", active)
	}

	d := &Daemon{Store: st, Active: func(context.Context) string { return active }}
	got, err := d.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Accounts) != 4 {
		t.Fatalf("accounts = %d, want 4", len(got.Accounts))
	}
	if got.ActiveID != "rin" {
		t.Fatalf("active id = %q", got.ActiveID)
	}
	withSnap := 0
	for _, a := range got.Accounts {
		if a.Snapshot != nil && len(a.Snapshot.Buckets) > 0 {
			withSnap++
		}
	}
	if withSnap != 4 {
		t.Fatalf("accounts with snapshots = %d, want 4", withSnap)
	}
	if len(got.Schedules) != 2 {
		t.Fatalf("schedules = %d, want 2", len(got.Schedules))
	}
	if len(got.Events) == 0 {
		t.Fatal("no demo events")
	}
}

func TestDemoScheduleAndEventCopyAreClean(t *testing.T) {
	accounts, _, schedules, events, _ := DemoFleet(time.Now())
	byID := map[string]bool{}
	for _, a := range accounts {
		byID[a.ID] = true
	}
	for _, sc := range schedules {
		if err := sc.Validate(); err != nil {
			t.Fatalf("demo schedule %s invalid: %v", sc.ID, err)
		}
		if !byID[sc.AccountID] {
			t.Fatalf("schedule %s references unknown account %q", sc.ID, sc.AccountID)
		}
	}
	// User-facing copy says "switched", never "rotated" (queued W8 item).
	for _, e := range events {
		if strings.Contains(strings.ToLower(e.Message), "rotat") {
			t.Fatalf("demo event uses banned word: %q", e.Message)
		}
	}
}
