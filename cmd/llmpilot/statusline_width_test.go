package main

import (
	"io"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/statusline"
)

// TestStatuslineRecordsClaudeCodeWidth: a render fed by Claude Code (its
// payload carries a session id, plus COLUMNS) remembers the width for the
// editor's preview; a human running it — bare, or piping JSON by hand with
// COLUMNS exported — records nothing.
func TestStatuslineRecordsClaudeCodeWidth(t *testing.T) {
	run := func(stdin string) (int, bool) {
		home := t.TempDir()
		t.Setenv("LLMPILOT_HOME", home)
		t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
		t.Setenv("COLUMNS", "93")
		cmd := statuslineCmd()
		cmd.SetIn(strings.NewReader(stdin))
		cmd.SetOut(io.Discard)
		cmd.SetArgs(nil)
		if err := cmd.Execute(); err != nil {
			t.Fatal(err)
		}
		return statusline.LastWidth(home)
	}
	if n, ok := run(`{"session_id":"s-1","model":{"display_name":"Fable"}}`); !ok || n != 93 {
		t.Errorf("Claude Code render: width %d, %v; want 93", n, ok)
	}
	if _, ok := run(""); ok {
		t.Error("a run without Claude Code's stdin recorded a width")
	}
	if _, ok := run(`{}`); ok {
		t.Error("hand-piped JSON with no session id recorded a width")
	}
}
