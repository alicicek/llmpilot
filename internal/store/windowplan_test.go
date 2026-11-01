package store

import (
	"testing"
	"time"
)

func TestWindowPlansRoundTripAndEmptyRemoves(t *testing.T) {
	s := At(t.TempDir())
	if plans, err := s.WindowPlans(); err != nil || len(plans) != 0 {
		t.Fatalf("fresh store: %v %v", plans, err)
	}
	at := time.Date(2026, 11, 1, 18, 30, 0, 0, time.UTC)
	if err := s.SetWindowPlan(WindowPlan{AccountID: "a", Rolling: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetWindowPlan(WindowPlan{AccountID: "b", NextAt: &at}); err != nil {
		t.Fatal(err)
	}
	if p, _ := s.WindowPlanFor("b"); p.NextAt == nil || !p.NextAt.Equal(at) {
		t.Fatalf("b = %+v", p)
	}
	// Replacing keeps one entry per account.
	if err := s.SetWindowPlan(WindowPlan{AccountID: "a"}); err != nil {
		t.Fatal(err)
	}
	plans, err := s.WindowPlans()
	if err != nil || len(plans) != 1 || plans[0].AccountID != "b" {
		t.Fatalf("an empty plan must remove the account: %+v %v", plans, err)
	}
	if err := s.SetWindowPlan(WindowPlan{}); err == nil {
		t.Fatal("a plan with no account was stored")
	}
}
