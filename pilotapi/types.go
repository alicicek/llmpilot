package pilotapi

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// Account is one registered Claude Code account: a config dir plus the
// identity Claude Code stores for it.
type Account struct {
	ID              string `json:"id"`
	Label           string `json:"label"`
	Email           string `json:"email"`
	ConfigDir       string `json:"config_dir"`
	KeychainService string `json:"keychain_service"`
	Pinned          bool   `json:"pinned"`
}

// Bucket is one rate-limit bucket as reported by the usage endpoint.
// Kind is an open string: unknown kinds must survive load/save round-trips
// unchanged — the endpoint ships new and experimental kinds routinely.
// Severity is passed through from the server when it provides one; it is
// empty (unknown) otherwise — no locally invented thresholds.
type Bucket struct {
	Kind     string     `json:"kind"`
	Scope    string     `json:"scope,omitempty"` // e.g. model display name for scoped buckets
	Percent  float64    `json:"percent"`
	ResetsAt *time.Time `json:"resets_at,omitempty"`
	Severity string     `json:"severity,omitempty"`
	Active   bool       `json:"active,omitempty"`
}

// UsageSnapshot is one account's buckets as of a moment.
type UsageSnapshot struct {
	AccountID string    `json:"account_id"`
	AsOf      time.Time `json:"as_of"`
	Buckets   []Bucket  `json:"buckets"`
}

// Event is one line in the append-only event log at $LLMPILOT_HOME/
// events.jsonl: auto-switches, window triggers, wake arms — the autopilot's
// visible memory, served by `llmpilot log` and pushed over SSE. Kind is an
// open string; volume is human-scale (a handful per day), so the log is not
// rotated. Never carries tokens.
type Event struct {
	At        time.Time `json:"at"`
	Kind      string    `json:"kind"`
	AccountID string    `json:"account_id,omitempty"`
	Message   string    `json:"message"`
	Late      bool      `json:"late,omitempty"`
}

// Schedule is one daily window trigger: fire a cheapest-model prompt on an
// account at a local wall-clock time so its 5-hour window starts then (a
// trigger only STARTS a window when none is active — it cannot shift an
// open one; the model enforces this).
type Schedule struct {
	ID        string `json:"id"`
	AccountID string `json:"account_id"`
	Hour      int    `json:"hour"`
	Minute    int    `json:"minute"`
	// Model/Effort steer the trigger prompt (empty = cheapest default).
	// A trigger aimed at the Fable weekly bucket must BE a Fable prompt —
	// only the prompted model's bucket starts (owner insight 2026-07-10).
	Model  string `json:"model,omitempty"`
	Effort string `json:"effort,omitempty"`
}

// scheduleIDRe: the ID becomes a launchd label, a plist filename, and a log
// filename — only the boring charset survives all three (review P2-7; a
// space or control char wedges launchctl bootstrap with the schedule
// already persisted).
var scheduleIDRe = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

// scheduleIDUnsafe matches everything scheduleIDRe rejects — used to
// sanitize a human label into the ID charset.
var scheduleIDUnsafe = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// ScheduleID derives a schedule ID from an account label and a trigger time
// (e.g. "kai-0900"). The one scheme shared by `llmpilot schedule add` and the
// cockpit API (POST /v1/schedules) — never reinvented per caller.
func ScheduleID(label string, hour, minute int) string {
	return fmt.Sprintf("%s-%02d%02d", scheduleIDUnsafe.ReplaceAllString(label, "-"), hour, minute)
}

// UniqueScheduleID is what CREATE paths use: the human "<label>-<hhmm>" when
// free, or "<label>-<acct6>-<hhmm>" when a DIFFERENT account already holds
// that ID — labels are not unique across accounts, and the ID is a global
// key (launchd label, plist filename), so "work" and "work!" colliding at
// the same time must not block each other (Greptile review P1, 2026-07-11).
// A same-account duplicate keeps the bare ID so callers' "already scheduled"
// checks still fire.
func UniqueScheduleID(existing []Schedule, accountID, label string, hour, minute int) string {
	id := ScheduleID(label, hour, minute)
	for _, sc := range existing {
		if sc.ID == id && sc.AccountID != accountID {
			frag := fmt.Sprintf("%x", sha256.Sum256([]byte(accountID)))[:6]
			return fmt.Sprintf("%s-%s-%02d%02d",
				scheduleIDUnsafe.ReplaceAllString(label, "-"), frag, hour, minute)
		}
	}
	return id
}

// Validate rejects out-of-range wall-clock fields before they reach disk or
// a launchd plist.
func (sc Schedule) Validate() error {
	if sc.Hour < 0 || sc.Hour > 23 || sc.Minute < 0 || sc.Minute > 59 {
		return fmt.Errorf("schedule %s: time %02d:%02d out of range", sc.ID, sc.Hour, sc.Minute)
	}
	if !scheduleIDRe.MatchString(sc.ID) || sc.ID == ".." {
		return fmt.Errorf("invalid schedule id %q — letters, digits, . _ - only", sc.ID)
	}
	for _, v := range []string{sc.Model, sc.Effort} {
		if v != "" && !scheduleIDRe.MatchString(v) {
			return fmt.Errorf("schedule %s: invalid model/effort %q", sc.ID, v)
		}
	}
	return ValidateID(sc.AccountID)
}

// ValidateID rejects IDs that could escape a filename or path segment.
func ValidateID(id string) error {
	if id == "" || strings.ContainsAny(id, `/\`) || id == ".." {
		return fmt.Errorf("invalid id %q", id)
	}
	return nil
}

// AutopilotConfig tunes threshold rotation. Auto-switch is ON by default
// (ledger 2026-07-08): absence of the file or the section means enabled.
type AutopilotConfig struct {
	Disabled         bool    `json:"disabled,omitempty"`
	ThresholdPercent float64 `json:"threshold_percent,omitempty"` // default 90
	CooldownMinutes  int     `json:"cooldown_minutes,omitempty"`  // default 15
}
