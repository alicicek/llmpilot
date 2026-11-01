package main

import (
	"strings"
	"testing"
)

// The start runs in the resolved Claude Code's environment, pinned to the
// account — never the daemon's own, which may carry a key or a token that
// would sign the start in as someone else.
func TestStartEnvIsTheResolvedOnePinnedToTheAccount(t *testing.T) {
	got := startEnv(
		[]string{"PATH=/usr/bin:/bin", "ANTHROPIC_API_KEY=sk-daemon", "CLAUDE_CODE_OAUTH_TOKEN=tok", "CLAUDE_CONFIG_DIR=/Users/x/.claude"},
		[]string{"PATH=/Users/x/.local/bin:/usr/bin", "HOME=/Users/x", "HTTPS_PROXY=http://proxy", "CLAUDE_CONFIG_DIR=/elsewhere"},
	)
	joined := strings.Join(got, "\n")
	for _, want := range []string{"PATH=/Users/x/.local/bin:/usr/bin", "HTTPS_PROXY=http://proxy", "HOME=/Users/x", "CLAUDE_CONFIG_DIR=/Users/x/.claude"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %q in %v", want, got)
		}
	}
	for _, leaked := range []string{"ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "/elsewhere", "/usr/bin:/bin"} {
		if strings.Contains(joined, leaked) {
			t.Errorf("%q leaked into the start: %v", leaked, got)
		}
	}
	if strings.Count(joined, "CLAUDE_CONFIG_DIR=") != 1 {
		t.Fatalf("want exactly one config dir: %v", got)
	}
}
