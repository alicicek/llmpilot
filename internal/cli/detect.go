package cli

import (
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
)

// Detected is one config dir that holds a logged-in Claude Code account. A
// thin re-export: the real detection logic lives in internal/detect so both
// this package (`llmpilot init`) and internal/daemon (GET /v1/detect, POST
// /v1/adopt) share it without an import cycle (internal/cli depends on
// internal/daemon via render.go, so internal/daemon cannot depend back on
// internal/cli).
type Detected = detect.Detected

// DetectDirs finds every config dir on this machine with a logged-in
// account. See internal/detect.Dirs.
func DetectDirs() ([]Detected, error) { return detect.Dirs() }

// SuggestLabel picks a label for a detected account. See
// internal/detect.SuggestLabel.
func SuggestLabel(d Detected, existing []store.Account) string {
	return detect.SuggestLabel(d, existing)
}
