package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/alicicek/llmpilot/pilotapi"
)

// Config is the user-editable settings file at $LLMPILOT_HOME/config.json.
// A missing file means all defaults; unknown fields are ignored so newer
// binaries never choke on older files (and vice versa).
type Config struct {
	Autopilot     AutopilotConfig     `json:"autopilot"`
	Notifications NotificationsConfig `json:"notifications"`
	// PlanCostMonthly maps an account ID to a user-set monthly plan cost —
	// the transcript schema has no price table (see internal/analytics doc
	// comment), so cost is only ever what the owner tells us.
	PlanCostMonthly map[string]float64 `json:"plan_cost_monthly,omitempty"`
}

// AutopilotConfig tunes threshold rotation; defined in pilotapi, aliased
// here. Auto-switch is ON by default (ledger 2026-07-08): absence of the
// file or the section means enabled.
type AutopilotConfig = pilotapi.AutopilotConfig

// NotificationsConfig tunes the burn-rate threshold notifications. Absence of
// the file or the section means enabled with DefaultNotificationThresholds.
type NotificationsConfig struct {
	Disabled bool `json:"disabled,omitempty"`
	// Thresholds are percent crossings that fire a notification, rising edge
	// only. Empty means DefaultNotificationThresholds.
	Thresholds []float64 `json:"thresholds,omitempty"`
}

// DefaultNotificationThresholds apply when NotificationsConfig.Thresholds is
// empty (ledger 2026-07-10: 75% is an early heads-up, 90% is the "about to
// rotate/run dry" wall).
var DefaultNotificationThresholds = []float64{75, 90}

// EffectiveThresholds returns the configured thresholds, sorted ascending,
// or a copy of DefaultNotificationThresholds when none are set — the
// defaulting logic lives once here so the config API and the daemon's poll
// path can never disagree about what "no thresholds set" means.
func (n NotificationsConfig) EffectiveThresholds() []float64 {
	if len(n.Thresholds) == 0 {
		out := make([]float64, len(DefaultNotificationThresholds))
		copy(out, DefaultNotificationThresholds)
		return out
	}
	out := make([]float64, len(n.Thresholds))
	copy(out, n.Thresholds)
	sort.Float64s(out)
	return out
}

func (s *Store) configPath() string { return filepath.Join(s.home, "config.json") }

// Config loads the settings file. Missing file = zero value (all defaults).
func (s *Store) Config() (Config, error) {
	data, err := os.ReadFile(s.configPath())
	if errors.Is(err, os.ErrNotExist) {
		return Config{}, nil
	}
	if err != nil {
		return Config{}, err
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return Config{}, fmt.Errorf("parse %s: %w", s.configPath(), err)
	}
	return c, nil
}

// SaveConfig validates and writes the settings file atomically. Thresholds
// must be in (0,100] and are stored sorted ascending — the one place that
// invariant is enforced, so every reader can trust the on-disk order.
func (s *Store) SaveConfig(c Config) error {
	for _, th := range c.Notifications.Thresholds {
		if th <= 0 || th > 100 {
			return fmt.Errorf("invalid notification threshold %v — must be in (0,100]", th)
		}
	}
	sort.Float64s(c.Notifications.Thresholds)
	return WriteJSONAtomic(s.configPath(), c)
}
