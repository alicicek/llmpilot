package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alicicek/llmpilot/pilotapi"
)

// WindowPlan is one account's rolling / one-off window starts; defined in
// pilotapi (the engine's wake armer reads it).
type WindowPlan = pilotapi.WindowPlan

func (s *Store) windowPlansPath() string { return filepath.Join(s.home, "window-plans.json") }

// WindowPlans loads every account's window plan. A missing file is none.
func (s *Store) WindowPlans() ([]WindowPlan, error) {
	data, err := os.ReadFile(s.windowPlansPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var plans []WindowPlan
	if err := json.Unmarshal(data, &plans); err != nil {
		return nil, fmt.Errorf("parse %s: %w", s.windowPlansPath(), err)
	}
	return plans, nil
}

// SetWindowPlan stores one account's plan, replacing its previous one; an
// empty plan removes the account's entry.
func (s *Store) SetWindowPlan(p WindowPlan) error {
	if p.AccountID == "" {
		return errors.New("window plan needs an account")
	}
	plans, err := s.WindowPlans()
	if err != nil {
		return err
	}
	kept := plans[:0]
	for _, q := range plans {
		if q.AccountID != p.AccountID {
			kept = append(kept, q)
		}
	}
	if !p.Empty() {
		kept = append(kept, p)
	}
	return WriteJSONAtomic(s.windowPlansPath(), kept)
}

// WindowPlanFor is one account's plan (the zero plan when it has none).
func (s *Store) WindowPlanFor(accountID string) (WindowPlan, error) {
	plans, err := s.WindowPlans()
	if err != nil {
		return WindowPlan{AccountID: accountID}, err
	}
	for _, p := range plans {
		if p.AccountID == accountID {
			return p, nil
		}
	}
	return WindowPlan{AccountID: accountID}, nil
}
