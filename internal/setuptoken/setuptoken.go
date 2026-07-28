// Package setuptoken stores long-lived headless tokens (the `claude
// setup-token` / CLAUDE_CODE_OAUTH_TOKEN class) as a UTILITY — never a fleet
// lane. There is no registry row, no switch verb, no synthesized credential
// block and no refresh machinery: a setup token has no refresh token, so when
// the year ends the user mints again.
//
// Token bytes live ONLY in llmpilot's own Keychain service (Service), written
// through the switcher adapter so the LLMPILOT_TEST interlock, the empty-write
// CAS floor and the stdin/argv discipline are inherited, never reimplemented.
// Metadata (label + dates, never a token byte) lives in setup-tokens.json
// under the llmpilot home.
//
// The token has exactly one egress: the clipboard, on an explicit copy. No
// method returns or logs token bytes; errors carry labels and dates only.
package setuptoken

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// Service is llmpilot's own Keychain service for setup tokens — a sibling of
// switcher.BackupService, and like it never read by the doctor's sweep.
const Service = "llmpilot-setup-tokens"

// TokenPrefix is the shape `claude setup-token` mints (CC 2.1.220, verified
// against a real token). Validation stops at the boundary: prefix + non-empty.
const TokenPrefix = "sk-ant-oat01-"

// Lifetime is DECLARED, not proven: the CC 2.1.220 binary calls the token
// "long-lived (1-year)". Nothing verifies it server-side; the copy says so.
const Lifetime = 365 * 24 * time.Hour

// Meta is one stored token's record: label and dates, never a token byte.
type Meta struct {
	Label     string    `json:"label"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

// DaysLeft is whole days until the declared expiry (floored, so it goes
// negative the moment a day past expiry begins — truncation held the whole
// (-24h, 0] window at "0 days left", a lapsed token looking alive).
func (m Meta) DaysLeft(now time.Time) int {
	return int(math.Floor(m.ExpiresAt.Sub(now).Hours() / 24))
}

// Expired compares INSTANTS: day-rounding must never decide whether a lapsed
// token renders as alive.
func (m Meta) Expired(now time.Time) bool { return !m.ExpiresAt.After(now) }

type document struct {
	Tokens []Meta `json:"tokens"`
}

// ErrExists refuses an add over a stored label without --replace: rotation is
// explicit, never a silent overwrite.
var ErrExists = errors.New("token already stored")

// ErrTorn marks a rotation that landed its Keychain half and then failed the
// metadata half. The stored dates are stale until add --replace is rerun; the
// token itself is the NEW one.
var ErrTorn = errors.New("keychain updated, record stale")

// Store manages the two halves of every token: the Keychain item and the
// metadata row. Every seam is injectable so tests run with a live-shaped
// token against fakes and no real /usr/bin/security or pbcopy ever runs.
type Store struct {
	Home     string             // llmpilot home (metadata file lives here)
	Keychain *switcher.Keychain // the ONE write adapter; interlock inherited
	// Clipboard writes bytes to the pasteboard. nil = /usr/bin/pbcopy.
	Clipboard func(ctx context.Context, data []byte) error
	// Now defaults to time.Now.
	Now func() time.Time
}

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Store) path() string { return filepath.Join(s.Home, "setup-tokens.json") }

func (s *Store) clipboard(ctx context.Context, data []byte) error {
	if s.Clipboard != nil {
		return s.Clipboard(ctx, data)
	}
	// The same interlock discipline as the Keychain adapter: a test that
	// forgot to inject a fake must never put a token on the real pasteboard.
	if os.Getenv("LLMPILOT_TEST") != "" {
		return errors.New("clipboard write not attempted: LLMPILOT_TEST is set (interlock; inject a fake clipboard)")
	}
	cmd := exec.CommandContext(ctx, "/usr/bin/pbcopy")
	cmd.Stdin = bytes.NewReader(data)
	// The token rides stdin; stdout/stderr are discarded, never captured into
	// an error a caller might print.
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("/usr/bin/pbcopy: %w", err)
	}
	return nil
}

// load reads the metadata document. A missing file is an empty document; a
// corrupt one is an error — never rebuilt, never renamed.
func (s *Store) load() (document, error) {
	var doc document
	data, err := os.ReadFile(s.path())
	if errors.Is(err, os.ErrNotExist) {
		return doc, nil
	}
	if err != nil {
		return doc, fmt.Errorf("read %s: %w", s.path(), err)
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return doc, fmt.Errorf("parse %s: %w", s.path(), err)
	}
	return doc, nil
}

func (s *Store) save(doc document) error {
	if doc.Tokens == nil {
		doc.Tokens = []Meta{}
	}
	return store.WriteJSONAtomic(s.path(), doc)
}

// ValidateToken is the boundary check: prefix, non-empty, and a length cap.
// The cap keeps the adapter's oversized-payload argv fallback unreachable —
// a >4000-char `security -i` line (2 hex chars per byte) would put the hex
// payload in the process listing. 1024 leaves real headroom over the
// measured 108-char shape while staying far under the ~1975-char cliff.
func ValidateToken(token []byte) error {
	t := bytes.TrimSpace(token)
	if len(t) == 0 {
		return errors.New("no token: paste the value `claude setup-token` printed")
	}
	if !bytes.HasPrefix(t, []byte(TokenPrefix)) {
		return fmt.Errorf("that does not look like a setup token (they start with %s…)", TokenPrefix)
	}
	if len(t) > 1024 {
		return errors.New("that is too long to be a setup token")
	}
	return nil
}

// labelRe is the label boundary. The label becomes a Keychain account
// attribute through `security -i`'s quoted-string parser, whose un-escaping
// DISAGREES with %q's escaping on control characters — "a\tb" lands under
// account "atb" — so two distinct labels could collide on one item, letting
// an add WITHOUT --replace destroy a stored credential and remove delete the
// wrong one (adversarial review P0, proven live 2026-07-26). A portable
// charset closes destroy + orphan + collision at once.
var labelRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// ValidateLabel trims and enforces the boundary; every store operation that
// touches the Keychain goes through it.
func ValidateLabel(label string) (string, error) {
	label = strings.TrimSpace(label)
	// A token pasted where a label goes must NOT be echoed back — the
	// refusal below quotes the input, and a token-shaped string would land
	// in stderr/scrollback. Checked first: a real token also fails the
	// length rule, which would echo it.
	if strings.HasPrefix(label, TokenPrefix) {
		return "", errors.New("that looks like a token, not a label — labels NAME tokens (e.g. ci); the token itself goes to the add prompt")
	}
	if !labelRe.MatchString(label) {
		return "", fmt.Errorf("label %q: use 1-64 letters, digits, dots, dashes or underscores", label)
	}
	return label, nil
}

// Add stores a token under a label: Keychain first, metadata second. An
// existing label refuses without replace. A metadata failure after a landed
// Keychain write returns ErrTorn — the caller must say the dates are stale
// rather than pretend the rotation half-happened cleanly.
func (s *Store) Add(ctx context.Context, label string, token []byte, replace bool) (Meta, error) {
	label, err := ValidateLabel(label)
	if err != nil {
		return Meta{}, err
	}
	if err := ValidateToken(token); err != nil {
		return Meta{}, err
	}
	doc, err := s.load()
	if err != nil {
		return Meta{}, err
	}
	existing := -1
	for i, m := range doc.Tokens {
		if m.Label == label {
			existing = i
			break
		}
	}
	if existing >= 0 && !replace {
		return Meta{}, fmt.Errorf("%w under %q — rerun with --replace to rotate it", ErrExists, label)
	}
	now := s.now()
	meta := Meta{Label: label, CreatedAt: now, ExpiresAt: now.Add(Lifetime)}
	if err := s.Keychain.Set(ctx, Service, label, bytes.TrimSpace(token)); err != nil {
		// The adapter distinguishes "provably untouched" from "the subprocess
		// errored, so the write MAY have landed" — collapsing them would tell
		// a user whose Keychain half changed that nothing happened, the
		// inverse of the torn state below (adversarial review P1).
		if errors.Is(err, switcher.ErrWriteNotAttempted) {
			return Meta{}, fmt.Errorf("store the token for %q: %w", label, err)
		}
		return Meta{}, fmt.Errorf("store the token for %q: %w (the Keychain half may or may not have changed — rerun `llmpilot token add --replace %s`)", label, err, label)
	}
	if existing >= 0 {
		doc.Tokens[existing] = meta
	} else {
		doc.Tokens = append(doc.Tokens, meta)
	}
	if err := s.save(doc); err != nil {
		return meta, fmt.Errorf("%w: the token under %q is the new one, but its record failed (%v) — rerun `llmpilot token add --replace %s`", ErrTorn, label, err, label)
	}
	return meta, nil
}

// List renders metadata ONLY — no Keychain read. Presence-probing every item
// would read secrets (find-generic-password -w) or dump the login search
// list; torn states surface at the verbs that touch the Keychain anyway.
func (s *Store) List() ([]Meta, error) {
	doc, err := s.load()
	if err != nil {
		return nil, err
	}
	return doc.Tokens, nil
}

// Copy reads the token and writes it to the clipboard — the one egress. The
// metadata row, when present, is returned so the caller can print dates; a
// missing Keychain half is reported, never rendered healthy.
func (s *Store) Copy(ctx context.Context, label string) (Meta, error) {
	label, err := ValidateLabel(label)
	if err != nil {
		return Meta{}, err
	}
	doc, err := s.load()
	if err != nil {
		return Meta{}, err
	}
	meta := Meta{Label: label}
	for _, m := range doc.Tokens {
		if m.Label == label {
			meta = m
			break
		}
	}
	token, err := s.Keychain.GetAccount(ctx, Service, label)
	if errors.Is(err, switcher.ErrNotFound) {
		return meta, fmt.Errorf("no token stored under %q in the Keychain — its record may be stale; store one with `llmpilot token add --label %s`", label, label)
	}
	if err != nil {
		return meta, fmt.Errorf("read the token for %q: %w", label, err)
	}
	if err := s.clipboard(ctx, bytes.TrimSpace(token)); err != nil {
		// The clipboard runner's error is rewrapped label-only: an exec error
		// string never carries the payload (it rode stdin), and nothing here
		// may add it.
		return meta, fmt.Errorf("copy the token for %q to the clipboard: %w", label, err)
	}
	return meta, nil
}

// Remove converges both halves to gone: Keychain first, metadata only after
// the Keychain half returned. The adapter's Delete swallows a missing item,
// so Remove is idempotent — it reports what it did, never claims to know what
// existed. A Keychain delete ERROR keeps the metadata row so no orphan item
// can go invisible.
func (s *Store) Remove(ctx context.Context, label string) error {
	label, err := ValidateLabel(label)
	if err != nil {
		return err
	}
	if err := s.Keychain.Delete(ctx, Service, label); err != nil {
		return fmt.Errorf("remove the token for %q from the Keychain: %w (its record is kept so the item cannot be lost track of)", label, err)
	}
	doc, err := s.load()
	if err != nil {
		return err
	}
	kept := doc.Tokens[:0]
	for _, m := range doc.Tokens {
		if m.Label != label {
			kept = append(kept, m)
		}
	}
	doc.Tokens = kept
	return s.save(doc)
}
