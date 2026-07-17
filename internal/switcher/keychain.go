package switcher

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"

	"github.com/alicicek/llmpilot/internal/anthropic"
)

// errSecItemNotFound is /usr/bin/security's exit code for a missing item.
const errSecItemNotFound = 44

// StdinRunner executes a command feeding it stdin. Injectable so unit tests
// never invoke the real /usr/bin/security; integration tests run it for real
// against a throwaway keychain.
type StdinRunner func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error)

// ExecStdinRunner runs the command for real.
func ExecStdinRunner(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = bytes.NewReader(stdin)
	return cmd.Output()
}

// Keychain reads, writes, and deletes generic-password items via
// /usr/bin/security (absolute path — never resolved through $PATH).
//
// Writes pass the secret hex-encoded on `security -i`'s stdin, never argv,
// so it cannot appear in process listings (claude-swap's hardening, adopted).
//
// Interlock: EVERY method — reads included — refuses to run under
// LLMPILOT_TEST unless File names a throwaway keychain (see
// anthropic.AssertThrowawayKeychain). A buggy test path must never be able
// to touch the login keychain.
type Keychain struct {
	File string      // optional keychain file; REQUIRED under LLMPILOT_TEST
	Run  StdinRunner // nil = ExecStdinRunner
}

func (k *Keychain) runner() StdinRunner {
	if k.Run != nil {
		return k.Run
	}
	return ExecStdinRunner
}

func (k *Keychain) interlock() error {
	if os.Getenv("LLMPILOT_TEST") != "" {
		return anthropic.AssertThrowawayKeychain(k.File)
	}
	return nil
}

// securityStdinLimit is `security -i`'s input line buffer: commands longer
// than this fail. Real Claude Code credential payloads (~8KB → ~16KB hex)
// exceed it, so those fall back to argv (claude-swap does the same; the hex
// blob is then briefly visible in the process listing — an accepted local
// trade-off, matching upstream).
const securityStdinLimit = 4000

// Set upserts (add-generic-password -U) an item's secret.
func (k *Keychain) Set(ctx context.Context, service, account string, secret []byte) error {
	if err := k.interlock(); err != nil {
		return err
	}
	hexSecret := hex.EncodeToString(secret)
	// Preferred: `security -i` reads commands from stdin; quoted args keep
	// the space-carrying service name intact and -X keeps the secret hex.
	line := fmt.Sprintf("add-generic-password -U -a %q -s %q -X %s", account, service, hexSecret)
	if k.File != "" {
		line += fmt.Sprintf(" %q", k.File)
	}
	if len(line) <= securityStdinLimit {
		if _, err := k.runner()(ctx, []byte(line+"\n"), "/usr/bin/security", "-i"); err != nil {
			// stdin mode: the error carries no secret (it went via stdin, hex).
			return fmt.Errorf("keychain write for service %q: %w", service, err)
		}
		return nil
	}
	args := []string{"add-generic-password", "-U", "-a", account, "-s", service, "-X", hexSecret}
	if k.File != "" {
		args = append(args, k.File)
	}
	if _, err := k.runner()(ctx, nil, "/usr/bin/security", args...); err != nil {
		return fmt.Errorf("keychain write for service %q: %w", service, err)
	}
	return nil
}

// Get reads an item's secret. A missing item is (nil, ErrNotFound).
func (k *Keychain) Get(ctx context.Context, service string) ([]byte, error) {
	if err := k.interlock(); err != nil {
		return nil, err
	}
	args := []string{"find-generic-password", "-s", service, "-w"}
	if k.File != "" {
		args = append(args, k.File)
	}
	out, err := k.runner()(ctx, nil, "/usr/bin/security", args...)
	if err != nil {
		if exitCode(err) == errSecItemNotFound {
			return nil, fmt.Errorf("service %q: %w", service, ErrNotFound)
		}
		return nil, fmt.Errorf("keychain read for service %q: %w", service, err)
	}
	return bytes.TrimRight(out, "\n"), nil
}

// GetAccount reads an item's secret matching both service and account attrs.
func (k *Keychain) GetAccount(ctx context.Context, service, account string) ([]byte, error) {
	if err := k.interlock(); err != nil {
		return nil, err
	}
	args := []string{"find-generic-password", "-s", service, "-a", account, "-w"}
	if k.File != "" {
		args = append(args, k.File)
	}
	out, err := k.runner()(ctx, nil, "/usr/bin/security", args...)
	if err != nil {
		if exitCode(err) == errSecItemNotFound {
			return nil, fmt.Errorf("service %q account %q: %w", service, account, ErrNotFound)
		}
		return nil, fmt.Errorf("keychain read for service %q: %w", service, err)
	}
	return bytes.TrimRight(out, "\n"), nil
}

// Delete removes an item; a missing item is not an error (like claude-swap,
// exit 44 → success).
func (k *Keychain) Delete(ctx context.Context, service, account string) error {
	if err := k.interlock(); err != nil {
		return err
	}
	args := []string{"delete-generic-password", "-s", service, "-a", account}
	if k.File != "" {
		args = append(args, k.File)
	}
	if _, err := k.runner()(ctx, nil, "/usr/bin/security", args...); err != nil {
		if exitCode(err) == errSecItemNotFound {
			return nil
		}
		return fmt.Errorf("keychain delete for service %q: %w", service, err)
	}
	return nil
}

// ErrNotFound marks a missing keychain item.
var ErrNotFound = errors.New("keychain item not found")

// exitCoder covers *exec.ExitError and any injected runner's error type.
type exitCoder interface{ ExitCode() int }

func exitCode(err error) int {
	var ec exitCoder
	if errors.As(err, &ec) {
		return ec.ExitCode()
	}
	return -1
}

// redact is a paranoia helper for transcript lines: it proves a payload
// exists without showing any of it.
func redact(b []byte) string {
	if len(b) == 0 {
		return "(empty)"
	}
	return fmt.Sprintf("(%d bytes, redacted)", len(b))
}
