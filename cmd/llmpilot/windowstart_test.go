package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
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

// A scheduled trigger finds Claude Code where its own installer puts it
// (~/.local/bin), which a launchd job's PATH never holds — and runs it
// pinned to the account's config dir. A sandbox keeps the engine's own exec.
func TestScheduledTriggersFindClaudeCodeOffPATH(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "claude")
	if err := os.WriteFile(fake, []byte("#!/bin/sh\necho \"ran $* in $CLAUDE_CONFIG_DIR\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	shell := filepath.Join(dir, "noshell")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("LLMPILOT_TEST", "")
	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin") // what launchd gives a job
	run := claudeRunner(&claudecfg.CLIResolver{Shell: shell, Candidates: []string{fake}, Timeout: time.Second})
	if run == nil {
		t.Fatal("no runner outside a sandbox")
	}
	out, err := run(context.Background(), []string{"PATH=/usr/bin:/bin", "CLAUDE_CONFIG_DIR=/Users/x/.claude"}, "claude", "-p", "hi", "--model", "haiku")
	if err != nil {
		t.Fatalf("run: %v (%s)", err, out)
	}
	if got := strings.TrimSpace(string(out)); got != "ran -p hi --model haiku in /Users/x/.claude" {
		t.Fatalf("output = %q", got)
	}

	t.Setenv("LLMPILOT_TEST", "1")
	if claudeRunner(&claudecfg.CLIResolver{}) != nil {
		t.Fatal("a sandbox must keep the engine's own exec of the claude on its PATH")
	}
}
