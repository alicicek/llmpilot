package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEventsAppendTailAndCorruption(t *testing.T) {
	s := At(t.TempDir())
	if evs, err := s.Events(10); err != nil || evs != nil {
		t.Fatalf("missing log must be empty, got %v (err %v)", evs, err)
	}
	for i := range 5 {
		e := Event{Kind: "trigger", AccountID: "a", Message: string(rune('a' + i))}
		if err := s.AppendEvent(e); err != nil {
			t.Fatal(err)
		}
	}
	// a corrupt line (crash mid-write, hand edit) is skipped, never fatal.
	f, err := os.OpenFile(filepath.Join(s.Home(), "events.jsonl"), os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString("{garbage\n"); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if err := s.AppendEvent(Event{Kind: "autoswitch", Message: "last"}); err != nil {
		t.Fatal(err)
	}
	evs, err := s.Events(3)
	if err != nil || len(evs) != 3 {
		t.Fatalf("want tail of 3, got %v (err %v)", evs, err)
	}
	if evs[2].Kind != "autoswitch" || evs[2].At.IsZero() {
		t.Fatalf("tail order or timestamp wrong: %+v", evs[2])
	}
	all, _ := s.Events(0)
	if len(all) != 6 {
		t.Fatalf("want all 6 valid events, got %d", len(all))
	}
}

func TestSchedulesRoundTripAndValidation(t *testing.T) {
	s := At(t.TempDir())
	if scheds, err := s.Schedules(); err != nil || scheds != nil {
		t.Fatalf("missing file must be empty, got %v (err %v)", scheds, err)
	}
	in := []Schedule{{ID: "a-0400", AccountID: "a", Hour: 4, Minute: 0}}
	if err := s.SaveSchedules(in); err != nil {
		t.Fatal(err)
	}
	out, err := s.Schedules()
	if err != nil || len(out) != 1 || out[0] != in[0] {
		t.Fatalf("round trip lost data: %v (err %v)", out, err)
	}
	for _, bad := range []Schedule{
		{ID: "x", AccountID: "a", Hour: 24},
		{ID: "x", AccountID: "a", Minute: 60},
		{ID: "x", AccountID: "a", Hour: -1},
		{ID: "x", AccountID: "../evil", Hour: 1},
	} {
		if err := s.SaveSchedules([]Schedule{bad}); err == nil {
			t.Fatalf("invalid schedule %+v saved", bad)
		}
	}
}

func TestConfigDefaultsAndParse(t *testing.T) {
	s := At(t.TempDir())
	c, err := s.Config()
	if err != nil || c.Autopilot.Disabled {
		t.Fatalf("missing config must default to enabled, got %+v (err %v)", c, err)
	}
	err = WriteJSONAtomic(filepath.Join(s.Home(), "config.json"), Config{
		Autopilot: AutopilotConfig{Disabled: true, ThresholdPercent: 85, CooldownMinutes: 5},
	})
	if err != nil {
		t.Fatal(err)
	}
	c, err = s.Config()
	if err != nil || !c.Autopilot.Disabled || c.Autopilot.ThresholdPercent != 85 {
		t.Fatalf("config not honored: %+v (err %v)", c, err)
	}
	if err := os.WriteFile(filepath.Join(s.Home(), "config.json"), []byte("{bad"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Config(); err == nil {
		t.Fatal("corrupt config must error loudly, not silently default")
	}
}
