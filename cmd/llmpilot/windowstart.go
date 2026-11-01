package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// wireWindowStarts gives the daemon the window plans' start: the engine's
// guarded trigger, run from the daemon itself at an account's reset.
func wireWindowStarts(d *daemon.Daemon, st *store.Store, prov pilotapi.Provider) {
	resolver := &claudecfg.CLIResolver{}
	d.StartWindow = func(ctx context.Context, accountID, why string) (pilotapi.StartOutcome, error) {
		defer holdAwake()()
		// Find Claude Code first and run exactly that: the lookup can ask the
		// login shell for up to ten seconds, and the engine's identity check
		// should sit right before the run, not before that wait.
		cli, err := resolver.Resolve(ctx)
		if err != nil {
			return pilotapi.StartFailed, err
		}
		firer := prov.NewFirer(pilotapi.FirerConfig{
			Store:    st,
			Out:      os.Stderr, // the trigger transcript goes to the daemon log
			Fetch:    d.Fetch,
			Identity: signedInEmail,
			// A daemon started by launchd has none of the user's PATH: run
			// the Claude Code the sign-in finds, in the environment it
			// resolved — never the daemon's own, which may carry an API key
			// or a token that would sign the start in as someone else —
			// pinned to the account.
			Run: func(ctx context.Context, env []string, _ string, args ...string) ([]byte, error) {
				cmd := exec.CommandContext(ctx, cli.Path, args...)
				cmd.Env = startEnv(env, cli.Env)
				return cmd.CombinedOutput()
			},
		})
		return firer.Start(ctx, accountID, why)
	}
	// The same exact comparison the engine's identity guard makes, so a
	// start that passes here is never refused there.
	d.CanStart = func(a store.Account) bool {
		who := signedInEmail(a.ConfigDir)
		return who != "" && (a.Email == "" || who == a.Email)
	}
	d.HoldAwake = holdAwakeFor
}

// signedInEmail is the account a config dir is signed in to ("" if none or
// unknown) — read through the claudecfg adapter.
func signedInEmail(configDir string) string {
	acct, err := claudecfg.DirAt(configDir).OAuthAccount()
	if err != nil || acct == nil {
		return ""
	}
	return acct.EmailAddress
}

// startEnv is the resolved Claude Code's environment (its contract: complete,
// with API keys and the user's own config dir kept out) plus the engine's
// pinned CLAUDE_CONFIG_DIR — what makes the start run as the right account.
func startEnv(engine, cli []string) []string {
	out := make([]string, 0, len(cli)+1)
	for _, kv := range cli {
		if !strings.HasPrefix(kv, "CLAUDE_CONFIG_DIR=") {
			out = append(out, kv)
		}
	}
	for _, kv := range engine {
		if strings.HasPrefix(kv, "CLAUDE_CONFIG_DIR=") {
			out = append(out, kv)
		}
	}
	return out
}

// holdAwakeFor keeps the Mac out of idle sleep for d, so a planned start
// shortly after a scheduled wake is not lost to the Mac dozing off again.
// A sandbox never runs it.
func holdAwakeFor(d time.Duration) {
	if os.Getenv("LLMPILOT_TEST") != "" || d <= 0 {
		return
	}
	secs := int(d.Seconds()) + 1
	cmd := exec.Command("/usr/bin/caffeinate", "-i", "-t", strconv.Itoa(secs))
	if err := cmd.Start(); err != nil {
		return
	}
	go func() { _ = cmd.Wait() }()
}

// claudeRunner runs Claude Code for a scheduled trigger. A launchd job has
// none of the user's PATH — Claude Code's own installer puts it in
// ~/.local/bin, which launchd never sees — so it runs the Claude Code the
// sign-in finds, in the environment that lookup resolved, pinned to the
// engine's config dir. A sandbox keeps the engine's own exec of the `claude`
// on its PATH (the golden recordings put a stand-in there): nil.
func claudeRunner(resolver *claudecfg.CLIResolver) pilotapi.TriggerRunner {
	if os.Getenv("LLMPILOT_TEST") != "" {
		return nil
	}
	return func(ctx context.Context, env []string, _ string, args ...string) ([]byte, error) {
		cli, err := resolver.Resolve(ctx)
		if err != nil {
			return nil, fmt.Errorf("no Claude Code where llmpilot can find it: %w", err)
		}
		cmd := exec.CommandContext(ctx, cli.Path, args...)
		cmd.Env = startEnv(env, cli.Env)
		return cmd.CombinedOutput()
	}
}
