package switcher

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

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

// ErrWriteNotAttempted marks a Keychain.Set that was refused BEFORE the
// /usr/bin/security subprocess ran (interlock or the empty-secret CAS): the
// stored item is provably untouched. The swap path clears its journal only
// for this class — a subprocess error may have landed the write and then
// been SIGKILLed by the deadline, so that case must KEEP the journal for
// recovery (adversarial review P2, 2026-07-25).
var ErrWriteNotAttempted = errors.New("keychain write not attempted")

// Set upserts (add-generic-password -U) an item's secret.
func (k *Keychain) Set(ctx context.Context, service, account string, secret []byte) error {
	if err := k.interlock(); err != nil {
		return fmt.Errorf("%w: %w", ErrWriteNotAttempted, err)
	}
	// CAS floor: an empty write can only ever destroy — the #76905 blanking
	// class. Every legitimate payload this adapter stores is non-empty JSON.
	if len(bytes.TrimSpace(secret)) == 0 {
		return fmt.Errorf("%w: keychain write for service %q: refusing to overwrite with an empty secret", ErrWriteNotAttempted, service)
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

// List enumerates the account attributes of every generic-password item in
// one service — attribute-only via `security dump-keychain` WITHOUT -d, so
// no secret payloads are read and no unlock prompts fire. Added for the
// legacy unmatched-* migration sweep; payload reads still go through
// GetAccount one item at a time.
func (k *Keychain) List(ctx context.Context, service string) ([]string, error) {
	if err := k.interlock(); err != nil {
		return nil, err
	}
	args := []string{"dump-keychain"}
	if k.File != "" {
		args = append(args, k.File)
	}
	out, err := k.runner()(ctx, nil, "/usr/bin/security", args...)
	if err != nil {
		return nil, fmt.Errorf("keychain list for service %q: %w", service, err)
	}
	return parseDumpAccounts(out, service), nil
}

// Services enumerates every service name that holds at least one item, in
// ONE dump. Attribute-only, exactly like List — no secret is read and no ACL
// prompt can fire. Callers asking about several dirs at once use this so a
// fleet of N folders costs one enumeration rather than N.
func (k *Keychain) Services(ctx context.Context) (map[string]bool, error) {
	if err := k.interlock(); err != nil {
		return nil, err
	}
	args := []string{"dump-keychain"}
	if k.File != "" {
		args = append(args, k.File)
	}
	out, err := k.runner()(ctx, nil, "/usr/bin/security", args...)
	if err != nil {
		return nil, fmt.Errorf("keychain enumerate: %w", err)
	}
	found := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if v, ok := dumpAttr(strings.TrimSpace(line), "svce"); ok && v != "" {
			found[v] = true
		}
	}
	return found, nil
}

// parseDumpAccounts extracts acct attributes for items whose svce matches.
// dump-keychain emits one block per item ("keychain: ..." then attributes);
// acct/svce lines look like `    "acct"<blob>="value"`.
func parseDumpAccounts(dump []byte, service string) []string {
	var accounts []string
	var acct, svce string
	flush := func() {
		if svce == service && acct != "" {
			accounts = append(accounts, acct)
		}
		acct, svce = "", ""
	}
	for _, line := range strings.Split(string(dump), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "keychain:") {
			flush()
			continue
		}
		if v, ok := dumpAttr(trimmed, "acct"); ok {
			acct = v
		}
		if v, ok := dumpAttr(trimmed, "svce"); ok {
			svce = v
		}
	}
	flush()
	return accounts
}

// dumpAttr parses `"name"<blob>="value"` lines (quoted-string form; our own
// keys are ASCII so the hex form never applies to them).
func dumpAttr(line, name string) (string, bool) {
	prefix := `"` + name + `"<blob>="`
	if !strings.HasPrefix(line, prefix) {
		return "", false
	}
	rest := line[len(prefix):]
	end := strings.LastIndex(rest, `"`)
	if end < 0 {
		return "", false
	}
	return rest[:end], true
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
