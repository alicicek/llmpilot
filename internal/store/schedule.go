package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alicicek/llmpilot/pilotapi"
)

// Schedule is one daily window trigger; defined in pilotapi (the engine
// consumes it), aliased here with its ID helpers.
type Schedule = pilotapi.Schedule

// ScheduleID derives a schedule ID from an account label and a trigger time.
func ScheduleID(label string, hour, minute int) string {
	return pilotapi.ScheduleID(label, hour, minute)
}

// UniqueScheduleID is what CREATE paths use — see pilotapi.UniqueScheduleID.
func UniqueScheduleID(existing []Schedule, accountID, label string, hour, minute int) string {
	return pilotapi.UniqueScheduleID(existing, accountID, label, hour, minute)
}

func (s *Store) schedulesPath() string { return filepath.Join(s.home, "schedules.json") }

// Schedules loads the schedule registry. A missing file is an empty registry.
func (s *Store) Schedules() ([]Schedule, error) {
	data, err := os.ReadFile(s.schedulesPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var scheds []Schedule
	if err := json.Unmarshal(data, &scheds); err != nil {
		return nil, fmt.Errorf("parse %s: %w", s.schedulesPath(), err)
	}
	return scheds, nil
}

// SaveSchedules writes the schedule registry atomically.
func (s *Store) SaveSchedules(scheds []Schedule) error {
	for _, sc := range scheds {
		if err := sc.Validate(); err != nil {
			return err
		}
	}
	return WriteJSONAtomic(s.schedulesPath(), scheds)
}
