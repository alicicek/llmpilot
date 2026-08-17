package switcher

// Refresh budget + global trip breaker, enforced INSIDE the keep-warm engine
// so every caller — daemon switch, CLI `account refresh`, future autopilot —
// is governed by construction. Ground truth: ~6 refresh POSTs/day earned a
// permanent 429 (#38248), the token endpoint sends NO authoritative
// Retry-After (verified by probing the live endpoint), and the throttle's
// scope (lineage vs account vs IP) is UNVERIFIED — so one 429 anywhere trips
// the breaker for EVERY account: a needless global pause costs nothing
// (swaps proceed un-freshened), probing a forming machine-level throttle can
// cost an account.
//
// The budget file holds attempt timestamps and breaker state ONLY — never
// token material (the cache rule; a test asserts it). Reads-modify-writes
// are serialized under a DEDICATED .budget.lock: the daemon and CLI are two
// processes on one file, and unserialized increments would silently double
// the cap. Deliberately NOT the backups mutex — keep-warm mode A releases
// the CC dir locks before touching the backups lock so a best-effort save
// never stalls a live claude session; budget accounting must not re-open
// that stall class.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// RefreshBudgetMax is the rolling-window cap per account. An ATTEMPT is a
// refresh POST actually issued — the engine's early returns (not near
// expiry, no refresh token, no stored expiry) never charge it.
const RefreshBudgetMax = 2

// RefreshBudgetWindow is the rolling window the cap applies to.
const RefreshBudgetWindow = 24 * time.Hour

// BreakerCooldown is the hard LOCAL cooldown after a REFRESH 429 from the
// token endpoint. Hours-scale on purpose: observed recovery horizons run
// hours-to-days and the endpoint's Retry-After (when present at all)
// understates them — it is never trusted.
const BreakerCooldown = 24 * time.Hour

// SignInBreakerCooldown is the cooldown after a SIGN-IN (authorization-code
// exchange) 429. Same endpoint, so it is still evidence the endpoint is
// rate-limiting this client right now and refreshes still pause — but one
// interactive attempt is not the serial keep-warm hammering that earned the
// 24h horizon, and a fresh install's first sign-in must not lock every
// refresh out for a day (fresh-user audit 2026-08-16, F7). The sign-in flow
// itself is never gated by either breaker.
const SignInBreakerCooldown = time.Hour

// Breaker sources — what tripped it. Persisted with the trip so a daemon
// restart keeps both the horizon and the explanation.
const (
	BreakerSourceRefresh = "refresh"
	BreakerSourceSignIn  = "sign-in"
)

// BreakerCooldownFor is the cooldown a trip from `source` imposes. An
// unknown or empty source (a document written before sources existed) is
// the conservative refresh horizon.
func BreakerCooldownFor(source string) time.Duration {
	if source == BreakerSourceSignIn {
		return SignInBreakerCooldown
	}
	return BreakerCooldown
}

// budgetFile persists attempts + breaker state in $LLMPILOT_HOME.
const budgetFile = "refresh-budget.json"

// ReasonRefreshPaused / ReasonBudgetExhausted are the STABLE skip-reason
// prefixes callers match on. Match these constants, never full rendered
// strings — a copy change must not silently break event gating or the
// caller-side rewrites (P3 review).
const (
	ReasonRefreshPaused   = "refresh paused"
	ReasonBudgetExhausted = "refresh budget exhausted"
)

// budgetDoc is the on-disk document. Timestamps and breaker state only.
type budgetDoc struct {
	Version   int                    `json:"version"`
	Attempts  map[string][]time.Time `json:"attempts"` // account ID → POST instants
	TrippedAt *time.Time             `json:"breaker_tripped_at,omitempty"`
	// TrippedBy is the breaker source (BreakerSourceRefresh / BreakerSourceSignIn);
	// empty in documents written before 1.3.1 and read as a refresh trip.
	TrippedBy string `json:"breaker_source,omitempty"`
}

// ErrRotationNotPersisted marks the worst refresh outcome: the token
// endpoint ROTATED the lineage (the old refresh token is dead server-side)
// but storing the result failed — the stored token is now known-dead.
// Installing it while reporting "switched" would strand the user, so the
// switch path ABORTS on this class; transient failures merely proceed
// un-freshened.
var ErrRotationNotPersisted = errors.New("refresh rotated server-side but the result could not be stored (stored token is now stale)")

func (s *Switcher) budgetPath() (string, bool) {
	if s.Registry == nil {
		return "", false
	}
	return filepath.Join(s.Registry.Home(), budgetFile), true
}

// acquireBudgetLock takes the dedicated budget mutex (mkdir-mutex, same
// mechanics as the backups lock, own file so it never serializes against
// credential writes).
func (s *Switcher) acquireBudgetLock(ctx context.Context) (*mutexLock, error) {
	if s.Registry == nil {
		return nil, nil
	}
	path := filepath.Join(s.Registry.Home(), ".budget.lock")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("budget lock dir: %w", err)
	}
	l, err := acquireLock(ctx, path, 10*time.Second, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("budget lock: %w", err)
	}
	return l, nil
}

func (s *Switcher) loadBudget() (budgetDoc, error) {
	doc := budgetDoc{Version: 1, Attempts: map[string][]time.Time{}}
	path, ok := s.budgetPath()
	if !ok {
		return doc, nil
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return doc, nil
	}
	if err != nil {
		return doc, err
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return doc, fmt.Errorf("parse %s: %w", path, err)
	}
	if doc.Attempts == nil {
		doc.Attempts = map[string][]time.Time{}
	}
	return doc, nil
}

func (s *Switcher) saveBudget(doc budgetDoc) error {
	path, ok := s.budgetPath()
	if !ok {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(path, append(data, '\n'), 0o600)
}

// chargeRefreshAttempt gates one refresh POST for accountID at now. It
// returns ("", true) after RECORDING the attempt (charge-then-POST: a crash
// between the two overcounts, never undercounts), or (reason, false) when
// the breaker is open or the budget is exhausted — the caller skips the
// POST and proceeds un-freshened. The budget NEVER blocks a switch; it only
// withholds the freshen. reserve is how many of the account's slots this
// caller must leave untouched: unattended callers (the autopilot revive)
// pass 1 so they can never spend the user's last refresh slot (P3 review
// NEW-1 — two failed unattended revives must not lock the user's own
// switch-time freshen out for 24h).
func (s *Switcher) chargeRefreshAttempt(ctx context.Context, accountID string, now time.Time, reserve int) (string, bool, error) {
	if _, ok := s.budgetPath(); !ok {
		return "", true, nil // no shared home (throwaway switcher) — nothing to persist against
	}
	l, err := s.acquireBudgetLock(ctx)
	if err != nil {
		return "", false, err
	}
	defer releaseLock(l)
	doc, err := s.loadBudget()
	if err != nil {
		return "", false, err
	}
	if doc.TrippedAt != nil && now.Sub(*doc.TrippedAt) < BreakerCooldownFor(doc.TrippedBy) {
		what := "a refresh"
		if doc.TrippedBy == BreakerSourceSignIn {
			what = "a sign-in"
		}
		return fmt.Sprintf(ReasonRefreshPaused+": the token endpoint rate-limited %s at %s — all refreshes wait out a %s local cooldown",
			what, doc.TrippedAt.UTC().Format(time.RFC3339), BreakerCooldownFor(doc.TrippedBy)), false, nil
	}
	recent := doc.Attempts[accountID][:0:0]
	for _, at := range doc.Attempts[accountID] {
		if now.Sub(at) < RefreshBudgetWindow {
			recent = append(recent, at)
		}
	}
	if reserve < 0 || reserve >= RefreshBudgetMax {
		// Invariant: a caller reserves SOME slots, never all (that would be
		// a permanent self-lockout) and never negative. Clamp to the largest
		// meaningful reserve; no production caller passes >1.
		reserve = RefreshBudgetMax - 1
	}
	if allowed := RefreshBudgetMax - reserve; len(recent) >= allowed {
		return fmt.Sprintf(ReasonBudgetExhausted+" for this account (%d of %d slots usable by this caller)",
			allowed, RefreshBudgetMax), false, nil
	}
	doc.Attempts[accountID] = append(recent, now.UTC())
	if err := s.saveBudget(doc); err != nil {
		return "", false, fmt.Errorf("recording refresh attempt: %w", err)
	}
	return "", true, nil
}

// BudgetSnapshot is a READ-ONLY view of the refresh budget: the attempt
// instants recorded per account and the breaker's trip time. It is what the
// doctor reads to explain a withheld refresh.
type BudgetSnapshot struct {
	Attempts  map[string][]time.Time
	TrippedAt *time.Time
	// TrippedBy is the breaker source (BreakerSourceRefresh / BreakerSourceSignIn);
	// empty for a trip persisted before sources existed (read as refresh).
	TrippedBy string
}

// BreakerClears is when the current trip stops withholding refreshes — nil
// when the breaker is not tripped.
func (b BudgetSnapshot) BreakerClears() *time.Time {
	if b.TrippedAt == nil {
		return nil
	}
	t := b.TrippedAt.Add(BreakerCooldownFor(b.TrippedBy))
	return &t
}

// BudgetSnapshot reads the budget document without taking the budget lock and
// without writing anything. The lock exists to serialize read-modify-WRITE
// cycles (an unserialized increment would double the cap); a pure reader
// needs none, and the file is only ever replaced by an atomic rename, so a
// reader sees one whole document or the previous one — never a torn mix.
// Nothing here charges an attempt or trips a breaker.
func (s *Switcher) BudgetSnapshot() (BudgetSnapshot, error) {
	doc, err := s.loadBudget()
	if err != nil {
		return BudgetSnapshot{Attempts: map[string][]time.Time{}}, err
	}
	return BudgetSnapshot{Attempts: doc.Attempts, TrippedAt: doc.TrippedAt, TrippedBy: doc.TrippedBy}, nil
}

// NoteTokenEndpoint429 trips the global breaker for a REFRESH 429 (the
// keep-warm engine's observation): every refresh pauses for BreakerCooldown.
// Persisted: a daemon restart must not re-enable probing.
func (s *Switcher) NoteTokenEndpoint429(ctx context.Context) {
	s.trip(ctx, BreakerSourceRefresh)
}

// NoteSignIn429 records a SIGN-IN (code exchange) 429: same endpoint, so
// refreshes still pause, but only for SignInBreakerCooldown, and the trip is
// tagged so the doctor says a sign-in was rate-limited — not a refresh. The
// login flow's own behavior never changes. A sign-in trip never SHORTENS a
// refresh trip that is still open: the longer horizon stands.
func (s *Switcher) NoteSignIn429(ctx context.Context) {
	s.trip(ctx, BreakerSourceSignIn)
}

func (s *Switcher) trip(ctx context.Context, source string) {
	if _, ok := s.budgetPath(); !ok {
		return
	}
	l, err := s.acquireBudgetLock(ctx)
	if err != nil {
		s.logf("breaker: could not persist a token-endpoint 429 observation: %v", err)
		return
	}
	defer releaseLock(l)
	doc, err := s.loadBudget()
	if err != nil {
		s.logf("breaker: budget file unreadable: %v", err)
		return
	}
	now := time.Now().UTC()
	if doc.TrippedAt != nil {
		// Keep whichever horizon ends later — a sign-in trip must not cut a
		// still-open refresh trip short.
		if cur := doc.TrippedAt.Add(BreakerCooldownFor(doc.TrippedBy)); cur.After(now.Add(BreakerCooldownFor(source))) {
			s.logf("breaker: %s 429 observed while a %s trip is open until %s — keeping the longer horizon", source, docSource(doc), cur.UTC().Format(time.RFC3339))
			return
		}
	}
	doc.TrippedAt = &now
	doc.TrippedBy = source
	if err := s.saveBudget(doc); err != nil {
		s.logf("breaker: could not persist the trip: %v", err)
		return
	}
	s.logf("breaker TRIPPED globally: token-endpoint 429 observed on %s — no refresh for %s", source, BreakerCooldownFor(source))
}

func docSource(doc budgetDoc) string {
	if doc.TrippedBy == "" {
		return BreakerSourceRefresh
	}
	return doc.TrippedBy
}
