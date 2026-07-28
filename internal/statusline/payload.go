package statusline

import (
	"encoding/json"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// Payload is the subset of Claude Code's statusline stdin JSON the segments
// consume (schema verified against the CC docs 2026-07-11; every field may be
// independently absent — stdin-first data with graceful absence, teardown
// requiredFields pattern).
type Payload struct {
	// SessionID is Claude Code's stable per-session identifier ("Unique
	// session ID", schema re-verified against the 2.1.220 binary + docs,
	// 2026-07-25). It is the floor guard's key: stdin rate_limits belong to
	// the SESSION's account, which a global swap can divorce from the config
	// dir's current identity.
	SessionID string `json:"session_id"`
	Model     struct {
		ID          string `json:"id"`
		DisplayName string `json:"display_name"`
	} `json:"model"`
	Workspace struct {
		CurrentDir string `json:"current_dir"`
	} `json:"workspace"`
	CWD  string `json:"cwd"`
	Cost struct {
		TotalCostUSD *float64 `json:"total_cost_usd"`
	} `json:"cost"`
	ContextWindow struct {
		UsedPercentage    *float64 `json:"used_percentage"` // null early in a session
		ContextWindowSize int      `json:"context_window_size"`
	} `json:"context_window"`
	RateLimits struct {
		FiveHour *StdinWindow `json:"five_hour"`
		SevenDay *StdinWindow `json:"seven_day"`
	} `json:"rate_limits"`
}

// StdinWindow is one rate-limit window from stdin — the always-available
// floor under the daemon cache.
type StdinWindow struct {
	UsedPercentage float64 `json:"used_percentage"`
	ResetsAt       int64   `json:"resets_at"` // unix epoch seconds
}

// Bucket converts a stdin window to the store's bucket shape.
func (w *StdinWindow) Bucket(kind string, loc *time.Location) store.Bucket {
	b := store.Bucket{Kind: kind, Percent: w.UsedPercentage}
	if w.ResetsAt > 0 {
		t := time.Unix(w.ResetsAt, 0).In(loc)
		b.ResetsAt = &t
	}
	return b
}

// ParsePayload is lenient: garbage stdin is no stdin.
func ParsePayload(stdin []byte) Payload {
	var p Payload
	_ = json.Unmarshal(stdin, &p)
	return p
}

// SamplePayload is the deterministic stdin fixture the daemon preview renders
// with — session-scoped fields (model, dir, cost, context) have no live
// source inside the daemon, so the preview shows these sample values while
// usage/fleet segments show the LIVE store. The preview-parity proof feeds
// the same payload to the binary.
func SamplePayload() []byte {
	return []byte(`{
		"model": {"id": "claude-fable-5", "display_name": "Fable"},
		"workspace": {"current_dir": "/Users/you/dev/llmpilot"},
		"cwd": "/Users/you/dev/llmpilot",
		"cost": {"total_cost_usd": 3.42},
		"context_window": {"used_percentage": 34, "context_window_size": 200000}
	}`)
}
