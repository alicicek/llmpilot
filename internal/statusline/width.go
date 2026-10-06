package statusline

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/alicicek/llmpilot/internal/store"
)

// DefaultPreviewColumns is the editor's preview width until Claude Code has
// rendered the line once.
const DefaultPreviewColumns = 120

// seenWidth is $LLMPILOT_HOME/statusline-width.json: the terminal width
// (COLUMNS) Claude Code last rendered the line at, so the editor previews
// at the user's real width instead of a guess. A number only.
type seenWidth struct {
	Columns int `json:"columns"`
}

func widthPath(home string) string { return filepath.Join(home, "statusline-width.json") }

// RecordWidth remembers the width Claude Code rendered the line at. It runs
// on every statusline refresh, so it writes only when the width changed.
func RecordWidth(home string, columns int) error {
	if columns <= 0 || columns > 1000 {
		return nil
	}
	if n, ok := LastWidth(home); ok && n == columns {
		return nil
	}
	return store.WriteJSONAtomic(widthPath(home), seenWidth{Columns: columns})
}

// LastWidth is the recorded width; ok is false until Claude Code has
// rendered the line (or when the file is unreadable).
func LastWidth(home string) (int, bool) {
	data, err := os.ReadFile(widthPath(home))
	if err != nil {
		return 0, false
	}
	var w seenWidth
	if json.Unmarshal(data, &w) != nil || w.Columns <= 0 || w.Columns > 1000 {
		return 0, false
	}
	return w.Columns, true
}
