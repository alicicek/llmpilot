package pilotapi

import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"time"
)

// TriggerRunner runs the trigger subprocess with an explicit environment.
// Injectable: dry-run transcripts and CI use a stub standing in for
// `claude`; each fire is an isolated process with its own CLAUDE_CONFIG_DIR
// (two near-simultaneous fires never serialize through one env).
type TriggerRunner func(ctx context.Context, env []string, name string, args ...string) ([]byte, error)

// CmdRunner executes a plain subprocess (launchctl, sudo pmset).
// Injectable: tests and CI use a recorder — the real binaries never run
// against a sandbox.
type CmdRunner func(ctx context.Context, name string, args ...string) ([]byte, error)

// Firer executes one schedule's trigger (the cannot-shift rule lives in the
// engine's implementation).
type Firer interface {
	Fire(ctx context.Context, id string) error
}

// FirerConfig carries the Firer's injected dependencies. Identity is
// REQUIRED wiring (the claudecfg adapter stays internal to the public
// module — the engine never learns Claude Code's config layout).
type FirerConfig struct {
	Store Store
	// Fetch reads an account's live buckets (nil = cache only). Used for the
	// cannot-shift check when the cache is stale and to capture the new
	// resets_at after a fire.
	Fetch func(ctx context.Context, a Account) ([]Bucket, error)
	Run   TriggerRunner // nil = real exec
	Model string        // trigger model; empty = cheapest default
	Out   io.Writer
	// Identity reads the email actually logged into a config dir ("" if
	// none/unknown).
	Identity func(configDir string) string

	Now         func() time.Time // tests
	LateAfter   time.Duration    // fire this long past schedule ⇒ LATE (default 5m)
	CacheMaxAge time.Duration    // cache older than this triggers a live check (default 10m)
	Timeout     time.Duration    // trigger subprocess budget (default 3m)
}

// TriggerSync mirrors the schedule registry into launchd jobs, idempotently.
type TriggerSync interface {
	Sync(ctx context.Context, binPath string, scheds []Schedule, logDir string) error
}

// TriggerSyncConfig carries the launchd syncer's injected dependencies.
type TriggerSyncConfig struct {
	Dir string // LaunchAgents dir
	UID int    // gui domain uid
	Run CmdRunner
	Out io.Writer
}

// Armer keeps one pmset wake event pointed at the earliest upcoming fire.
type Armer interface {
	Sync(ctx context.Context, now time.Time) error
}

// ArmerConfig carries the wake armer's injected dependencies.
type ArmerConfig struct {
	Store Store
	Run   CmdRunner
	Log   *slog.Logger
}

// Provider is what a build supplies: the engine's constructors in official
// builds (`-tags pro`, github.com/alicicek/llmpilot-pro), nothing in source
// builds. Callers branch on Available and show honest not-available copy —
// never a stub that pretends to work.
type Provider struct {
	Available bool
	// Version identifies the engine build ("" when unavailable).
	Version        string
	NewPolicy      func(Params) Policy
	NewFirer       func(FirerConfig) Firer
	NewTriggerSync func(TriggerSyncConfig) TriggerSync
	NewArmer       func(ArmerConfig) Armer
	// WakeInstall runs the guided privileged-helper install (prints the
	// exact sudoers rule, validates with visudo, proves the passwordless
	// path, uninstalls on failure).
	WakeInstall func(ctx context.Context, out io.Writer) error
}

// AgentsDir is the current user's LaunchAgents directory.
func AgentsDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents"), nil
}
