// Package daemon is llmpilot's always-on brain: it polls every registered
// account's usage buckets, keeps snapshots cached under $LLMPILOT_HOME, and
// serves state to every surface over a unix socket and 127.0.0.1.
//
// The daemon NEVER refreshes an idle account's token on a timer (Anthropic's
// refresh throttle makes background refresh self-destructive — issue #38248;
// design pillar 4). An idle account whose stored token expired is served from
// its last-known snapshot with an honest stale marker; it wakes the moment
// the user uses or switches to it (the switch path freshens the target).
//
// All fragile-surface knowledge stays in internal/anthropic and
// internal/claudecfg; the daemon composes injectable functions so tests and
// CI never touch the network, the Keychain, or a real `claude` binary.
package daemon

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"math/rand"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// DefaultPollInterval is the steady-state cadence and the serve freshness
// target: a snapshot older than ~180s is worth refreshing. 20 GETs/hour at
// steady state — well inside HourlyPollBudget, leaving headroom for reset
// pulls and switch fast-polls.
const DefaultPollInterval = 180 * time.Second

// MinPollGap is the absolute per-account floor between two usage GETs.
// Special polls (a switch fast-poll, a post-reset pull) may pull the
// schedule in, but never below this spacing.
const MinPollGap = 120 * time.Second

// HourlyPollBudget caps one account's usage GETs per rolling 60 minutes
// (~28–30/60min/token is the researched safe envelope for the experimental
// endpoint). When the window is spent, the next poll waits for the oldest
// request to age out — the budget is a hard ceiling, not a target.
const HourlyPollBudget = 28

// SwitchRefreshLead is how long before token expiry the SWITCH-TIME freshen
// kicks in (the switcher's keep-warm engine, run only at activation — never
// on a timer). 10 minutes = ~2× Claude Code's own buffer, so the freshened
// target still outlives CC's post-switch re-read while draining the 2/day
// refresh budget far slower than the keep-warm-era 1h lead did.
const SwitchRefreshLead = 10 * time.Minute

// Fetcher fetches one account's current buckets.
type Fetcher func(ctx context.Context, acct store.Account) ([]store.Bucket, error)

// Switcher performs a full account swap to the target account ID.
type Switcher func(ctx context.Context, targetID string) error

// ExpiryFn reports when an account's stored access token expires.
type ExpiryFn func(ctx context.Context, acct store.Account) (time.Time, error)

// ActiveFn reports which registered account is currently active in the
// default config dir ("" if unknown).
type ActiveFn func(ctx context.Context) string

// UserNotifier delivers a user-facing notification (macOS notification
// center in production; a recorder in tests). Auto-switches always notify —
// switch before the wall, notify after.
type UserNotifier func(ctx context.Context, title, body string)

// ActiveEmailFn reports the raw email logged into the default config dir
// ("" if none) — including accounts the registry doesn't know, which
// ActiveFn by design cannot report.
type ActiveEmailFn func(ctx context.Context) string

// DetectFn lists every config dir on this machine with a logged-in account
// (GET /v1/detect).
type DetectFn func(ctx context.Context) ([]detect.Detected, error)

// EntitlementAllowed evaluates the locally signed grant. It must not perform
// network I/O: the daemon calls it on action paths so trial expiry pauses Pro
// immediately even when the Mac is offline.
type EntitlementAllowed func(feature string, now time.Time) bool

// EntitlementDue reports whether the opportunistic weekly validation is due.
// Implementations persist their last success and deterministic jitter so a
// daemon restart cannot reset the clock.
type EntitlementDue func(now time.Time) bool

// EntitlementValidation is the small status projection returned after an
// online check. Tokens and license identifiers never enter daemon logs.
type EntitlementValidation struct {
	Status string
}

// EntitlementRevalidator performs one online status refresh. It is run by a
// single coalescing background worker after successful usage network traffic.
type EntitlementRevalidator func(ctx context.Context) (EntitlementValidation, error)

// MoveResult reports one "Move into the fleet" migration. CloneSuspect means
// the source copy could not be proven gone: the account is registered and
// safe, but llmpilot will not rotate it until a human resolves the second
// copy. Note carries the honest explanation for that state.
type MoveResult struct {
	Account      store.Account
	CloneSuspect bool
	Note         string
}

// MoveFn performs the migration for POST /v1/adopt/move.
type MoveFn func(ctx context.Context, d detect.Detected, label string) (MoveResult, error)

// AdoptFn registers the account at a detected config dir exactly like
// `llmpilot init` (same ID/label derivation) and returns the registered
// account (POST /v1/adopt).
type AdoptFn func(ctx context.Context, d detect.Detected, label string) (store.Account, error)

// Daemon owns the poll loop and the state served to surfaces. Zero-value
// fields get safe defaults in Run.
type Daemon struct {
	Store  *store.Store
	Fetch  Fetcher
	Switch Switcher
	Expiry ExpiryFn
	Active ActiveFn
	Log    *slog.Logger

	// Version is the llmpilot build this daemon process is running. It goes
	// on the wire because the RUNNING process is the only thing that knows
	// it: after an in-place update the binary on disk is the new one while
	// this process is still the old one, and nothing else can tell them
	// apart. The menu bar app compares it against its own bundle to notice
	// it is talking to a pre-update daemon.
	Version string

	// Pinned reports whether an account lives in its own config dir. Pinned
	// accounts are never swap targets (Swap refuses them — installing one
	// into the global slot clones its refresh-token lineage), so autopilot
	// must not nominate them. nil = treat every account as swappable.
	Pinned func(acct store.Account) bool

	// Pilot enables threshold rotation (nil = off — free builds and
	// unlicensed official builds leave it nil). NotifyUser is nil-safe.
	Pilot       pilotapi.Policy
	NotifyUser  UserNotifier
	ActiveEmail ActiveEmailFn

	// AutoSwitch is the UNATTENDED counterpart of Switch, used for every
	// autopilot-initiated rotation of a non-stale target. Same swap, same
	// switch-time freshen — but built with a refresh-budget RESERVE, so a
	// rotation the user never asked for can never spend their last 2/24h
	// refresh slot. nil = fall back to Switch (the pre-P4 behaviour), so an
	// engine-absent or partially wired build keeps rotating.
	AutoSwitch Switcher

	// MovedDirs reports which config dirs a move retired AND that still hold
	// no sign-in — the honest input for /v1/detect's `moved` flag. nil falls
	// back to the retirement record alone, which is what a daemon without a
	// switcher (tests, engine-absent builds) can know.
	MovedDirs func(ctx context.Context) (map[string]bool, error)

	// MoveIntoFleet migrates a sign-in out of its own config dir into the
	// swappable fleet and retires the source copy (POST /v1/adopt/move; nil =
	// 501). Injected like Adopt — the daemon never touches the Keychain or a
	// config dir itself.
	MoveIntoFleet MoveFn

	// Revive is the STRICT switch for stale targets (Decision.Revive): it
	// must PROVE a live credential — a forced-lead refresh that actually
	// rotated — before installing anything; a skip or transient failure
	// returns ErrReviveNotProven and the fleet holds. nil = revive unwired;
	// a revive decision then holds rather than falling back to the
	// best-effort Switch (never install a token known to be expired).
	Revive Switcher

	// EntitlementAllowed is the offline action gate. EntitlementDue and
	// Revalidate implement opportunistic weekly status refresh without adding
	// latency to usage polling. All are nil-safe for free/source builds.
	EntitlementAllowed EntitlementAllowed
	EntitlementDue     EntitlementDue
	Revalidate         EntitlementRevalidator

	// License wires the in-app purchase + entitlement surface (GET/POST
	// /v1/license*). nil on builds and tests that do not sell Pro — those
	// handlers answer 501. The daemon is the SOLE writer of the entitlement
	// Keychain item (advisor verdict 2026-07-12; see license.go).
	License *LicenseGate

	// WakeSync re-arms the pmset wake for the earliest scheduled trigger
	// (nil = wake arming off; degraded mode inside is a designed no-op).
	WakeSync func(ctx context.Context, now time.Time) error

	// TriggerSync mirrors the full schedule set into launchd. The schedule
	// API calls it BEFORE persisting: a failed bootstrap must not leave a
	// saved-but-never-loaded schedule. nil = off — sandboxed daemons must
	// never bootstrap real agents. Without this a cockpit-created schedule
	// saved and wake-armed but its launchd job never existed, so it never
	// fired.
	TriggerSync func(ctx context.Context, scheds []store.Schedule) error

	// Freshen re-captures the ACTIVE account's live credential into backups
	// after each of its polls (nil = off). Refresh-token rotation + bare
	// /login clobbers make un-freshened backups die silently.
	Freshen func(ctx context.Context, acct store.Account) (bool, error)

	// StartupSweep runs once when Serve starts (nil = off): the one-time
	// migration of legacy unmatched-* backup items into the stash. Failure
	// is logged, never fatal — the sweep retries on the next daemon start.
	StartupSweep func(ctx context.Context) error

	// Stash* wire the foreign-credential stash (all nil = 501, stash not
	// wired — sandboxed daemon tests inject fakes like every other
	// Keychain-touching field). List feeds /v1/state; Adopt and Discard back
	// the requireAuth-guarded mutation endpoints. The daemon refuses adopt
	// on a quarantined (dead) fingerprint BEFORE calling StashAdopt.
	StashList    func(ctx context.Context) ([]pilotapi.StashEntry, error)
	StashAdopt   func(ctx context.Context, fingerprint, label string) (store.Account, error)
	StashDiscard func(ctx context.Context, fingerprint string) error

	// WebFS is the embedded cockpit (web.Dist()); nil = API only.
	WebFS fs.FS

	// NowFn overrides the daemon's clock (nil = time.Now): the statusline
	// preview render and the login-attempt TTL read it, so a test can pin
	// time deterministically without sleeping.
	NowFn func() time.Time

	// DoctorReaders supplies the health sweep's filesystem/Keychain readers
	// (GET /v1/doctor). Zero value = those checks report NOT CHECKED rather
	// than passing; the daemon itself never scans a config dir or a Keychain.
	DoctorReaders DoctorLocal

	// Detect lists config dirs with a logged-in account for GET /v1/detect
	// (nil = 501, detect not wired). Adopt registers one of those dirs for
	// POST /v1/adopt (nil = 501). Both injected — like every other
	// filesystem/Keychain-touching field — so daemon tests never scan or
	// mutate the real machine's Claude Code state.
	Detect DetectFn
	Adopt  AdoptFn

	// SignedInDirs reports, keyed by config dir, which detected dirs still
	// hold a usable sign-in. A dir keeps its identity in .claude.json after
	// the credential is gone, so detection alone cannot tell a live folder
	// from a spent one — without this the cockpit offers Add/Move on folders
	// where both refuse. Batched because both surfaces poll /v1/detect and
	// the underlying probe enumerates the whole keychain. nil, or a dir
	// missing from the result, reads as present (never hide a real account
	// over a missing probe).
	SignedInDirs func(ctx context.Context, ds []detect.Detected) map[string]bool

	// LoginMint/LoginURL/LoginComplete wire the in-app sign-in (POST
	// /v1/login/*; all nil = 501). See login.go — the PKCE verifier lives only
	// in this process, keyed by CSRF state in loginAttempts.
	LoginMint     LoginMintFn
	LoginURL      LoginURLFn
	LoginComplete LoginCompleteFn

	// PollInterval is clamped up to DefaultPollInterval unless AllowFastPoll
	// (tests only) is set.
	PollInterval  time.Duration
	AllowFastPoll bool

	// schedMu serializes schedule mutations (read set → launchd sync → save):
	// two concurrent cockpit writes would otherwise lose one caller's change
	// after launchd already synced both views (Greptile P1, 2026-07-11).
	// Separate from mu — launchctl execs must not block the poll path.
	// NOTE: this covers the daemon's own handlers only; a CLI `llmpilot
	// schedule` write racing a live daemon is a separate-process race the
	// mutex cannot see (accepted for a single-user tool; the daemon re-reads
	// schedules.json fresh on every State call either way).
	schedMu sync.Mutex

	mu         sync.Mutex
	nextPoll   map[string]time.Time
	lastPolled map[string]time.Time
	// pollTimes is the per-account rolling window of usage-GET timestamps
	// backing HourlyPollBudget (attempts count — a 429'd GET spent budget
	// too). In-memory only: a restart forgets the window, and the steady
	// cadence re-fills it far below the ceiling.
	pollTimes  map[string][]time.Time
	tokenNotes map[string]string
	// quarantine marks accounts with a provably dead refresh-token lineage
	// (accountID → dead lineage fingerprint). Phase 1 never populates it —
	// dead lineages are only discoverable by an activation attempt (the
	// switch path), which repopulates it in Phase 2. The poll skip and the
	// autopilot target filter keep honoring it meanwhile.
	quarantine map[string]string
	// stale marks accounts whose stored token expired (or 401'd): their
	// last-known snapshot is served with this honest flag, and no network
	// call runs for them until the stored credential CHANGES (the user uses
	// or switches to the account). The value is the stored expiry observed
	// when the account went stale — the clear condition is the expiry moving
	// forward, never "the expiry looks valid" (a 401 arrives precisely when
	// it looks valid, and clearing on looks would flap and re-hammer).
	stale map[string]time.Time
	// knownStash tracks stash fingerprints already surfaced (or present at
	// start) so each preserved credential events exactly once.
	knownStash map[string]bool
	// quarantinePersistMu serializes the quarantine snapshot+rename so two
	// concurrent persists cannot commit out of order (see persistQuarantine).
	quarantinePersistMu sync.Mutex
	lastSwitch          time.Time            // last rotation ATTEMPT — cooldown covers failures too
	lastActive          string               // last observed active account (fast-poll on change)
	lastUnknown         string               // last unregistered email surfaced (once per email)
	lastRotateFail      string               // last failure event text — repeats log, not spam
	lastHold            string               // last autopilot_hold text — one event per distinct reason
	licenseStatus       string               // last online status projection; no token/id/PII
	licenseError        string               // last terminal licensing refusal code, "" when none
	cooldown            map[string]coolState // per-account 429 gate (usage+refresh share Anthropic's limit)

	// history is the in-memory burn-rate ring per (account, bucket kind+
	// scope) — GET /v1/history. Deliberately NOT persisted: a restart is an
	// honestly empty sparkline, never a fabricated one.
	history map[string][]HistorySample

	// loginResults tracks each browser-flow attempt's outcome (keyed by the
	// same CSRF state the attempt table uses — the client already receives
	// it inside authorize_url, so returning it as the attempt id exposes
	// nothing new). GET /v1/login/browser/status reads it, so the cockpit
	// ties completion to ITS attempt instead of inferring from fleet size.
	loginResults map[string]loginResult

	// loginMu guards loginAttempts (state → pending sign-in), separate from
	// mu — a login mutation must never contend with the poll path.
	loginMu       sync.Mutex
	loginAttempts map[string]loginAttempt

	events       *broadcaster
	once         sync.Once
	revalidateCh chan struct{}

	// authToken guards license reveal/mutation (see auth.go). Set once in
	// init, read-only afterwards — no lock needed.
	authToken string
}

// historyCap bounds the in-memory burn-rate ring per bucket key.
const historyCap = 600

// HistorySample is one burn-rate observation for a bucket, served by
// GET /v1/history.
type HistorySample struct {
	At      time.Time `json:"at"`
	Percent float64   `json:"percent"`
}

func (d *Daemon) init() {
	d.once.Do(func() {
		d.nextPoll = map[string]time.Time{}
		d.lastPolled = map[string]time.Time{}
		d.pollTimes = map[string][]time.Time{}
		d.tokenNotes = map[string]string{}
		d.quarantine = map[string]string{}
		d.stale = map[string]time.Time{}
		d.cooldown = map[string]coolState{}
		d.loginAttempts = map[string]loginAttempt{}
		d.loginResults = map[string]loginResult{}
		d.history = map[string][]HistorySample{}
		d.events = newBroadcaster()
		d.revalidateCh = make(chan struct{}, 1)
		if d.Log == nil {
			d.Log = slog.Default()
		}
		d.loadQuarantine()
		if tok, err := newAuthToken(); err == nil {
			d.authToken = tok
		} else {
			// Fail closed twice over: an empty token never matches, so guarded
			// license routes answer 401 on a bare Handler(), and Serve()
			// refuses to start at all rather than run without a token file.
			d.Log.Error("auth token generation failed — license actions disabled", "err", err)
		}
		if d.PollInterval < DefaultPollInterval && !d.AllowFastPoll {
			d.PollInterval = DefaultPollInterval
		}
	})
}

// AccountState is one account plus its latest cached snapshot. TokenNote is
// a human-readable warning surfaced honestly, never papered over. Stale
// means the account's stored token has expired while idle: Snapshot is the
// last-known truth, frozen until the user wakes the account — surfaces
// render it with an explicit stale badge, never as live data.
type AccountState struct {
	store.Account
	Snapshot  *store.UsageSnapshot `json:"snapshot,omitempty"`
	TokenNote string               `json:"token_note,omitempty"`
	Stale     bool                 `json:"stale,omitempty"`
}

// State is the full document served at GET /v1/state and pushed over SSE.
// Events is the recent tail of the autopilot event log, oldest first.
// Schedules is never null — an empty fleet still renders an empty array on
// every surface that decodes this JSON.
type State struct {
	Accounts []AccountState `json:"accounts"`
	ActiveID string         `json:"active_id,omitempty"`
	Events   []store.Event  `json:"events,omitempty"`
	// Stash is never null — the empty case must decode on every surface
	// (the accounts:null wire kill).
	Stash     []pilotapi.StashEntry `json:"stash"`
	Schedules []store.Schedule      `json:"schedules"`
	License   string                `json:"license_status,omitempty"`
	// LicenseError is the last terminal licensing refusal code
	// (seat_limit_reached, trial_email_used, ...) — a machine code only.
	LicenseError string `json:"license_error,omitempty"`
	// Version is the build of the daemon PROCESS answering this request.
	Version string    `json:"version,omitempty"`
	AsOf    time.Time `json:"as_of"`
}

// State assembles the current state from the store's caches.
func (d *Daemon) State(ctx context.Context) (State, error) {
	d.init()
	accs, err := d.Store.Accounts()
	if err != nil {
		return State{}, err
	}
	// Accounts is never null either — a FRESH install (zero accounts) must
	// decode on every surface; a nil slice marshals as JSON null and killed
	// the whole menu-bar state decode (found by the first-run e2e).
	st := State{Accounts: []AccountState{}, Version: d.Version, AsOf: time.Now().UTC()}
	d.mu.Lock()
	st.License = d.licenseStatus
	st.LicenseError = d.licenseError
	d.mu.Unlock()
	for _, a := range accs {
		// A bad cache file degrades ONE account's display, never the whole
		// state (and never SSE, which rides on State) — the account still
		// lists, snapshot-less, and the next poll rewrites the file.
		snap, err := d.Store.Snapshot(a.ID)
		if err != nil {
			d.Log.Warn("read snapshot", "account", a.ID, "err", err)
			snap = nil
		}
		d.mu.Lock()
		note := d.tokenNotes[a.ID]
		_, stale := d.stale[a.ID]
		d.mu.Unlock()
		// Pinned is DERIVED here, never read from the registry file: an
		// account is pinned when it lives in its own config dir, which is the
		// engine's own rule (Swap refuses such a target). Nothing writes the
		// stored field for real accounts, so a surface that gated its switch
		// verb on it would offer a verb the engine refuses. `a` is a loop
		// copy — this never writes back to accounts.json.
		if d.Pinned != nil && d.Pinned(a) {
			a.Pinned = true
		}
		st.Accounts = append(st.Accounts, AccountState{Account: a, Snapshot: snap, TokenNote: note, Stale: stale})
	}
	if d.Active != nil {
		st.ActiveID = d.Active(ctx)
	}
	// Stash: metadata only, [] when empty or unwired, dead lineages flagged
	// so surfaces can say "needs a fresh sign-in" before an adopt attempt.
	st.Stash = []pilotapi.StashEntry{}
	if d.StashList != nil {
		entries, err := d.StashList(ctx)
		if err != nil {
			d.Log.Warn("read stash", "err", err)
		}
		for _, e := range entries {
			e.Dead = d.IsLineageDead(e.Fingerprint)
			st.Stash = append(st.Stash, e)
		}
	}
	// Events are auxiliary: an unreadable log degrades state, never kills it.
	evs, err := d.Store.Events(20)
	if err != nil {
		d.Log.Warn("read events", "err", err)
	}
	st.Events = evs
	// Read fresh every call (no daemon-side cache of schedules.json): a CLI
	// edit (`llmpilot schedule add/remove`) surfaces on the very next notify
	// or state fetch with no separate file watcher needed.
	scheds, err := d.Store.Schedules()
	if err != nil {
		d.Log.Warn("read schedules", "err", err)
	}
	if scheds == nil {
		scheds = []store.Schedule{}
	}
	st.Schedules = scheds
	return st, nil
}

// Run drives the poll loop until ctx is done.
func (d *Daemon) Run(ctx context.Context) error {
	d.init()
	if d.Revalidate != nil {
		go d.entitlementLoop(ctx)
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	var wakeTick <-chan time.Time
	if d.WakeSync != nil {
		wt := time.NewTicker(time.Minute)
		defer wt.Stop()
		wakeTick = wt.C
		d.wakeSync(ctx)
	}
	// One immediate pass so a fresh daemon serves data promptly.
	d.pollDue(ctx)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick.C:
			d.pollDue(ctx)
		case <-wakeTick:
			d.wakeSync(ctx)
		}
	}
}

func (d *Daemon) wakeSync(ctx context.Context) {
	if d.EntitlementAllowed != nil && !d.EntitlementAllowed("wake", time.Now()) {
		return
	}
	if err := d.WakeSync(ctx, time.Now()); err != nil {
		d.Log.Warn("wake sync", "err", err)
	}
}

// pollDue fetches every account whose next-poll time has arrived.
func (d *Daemon) pollDue(ctx context.Context) {
	if d.Fetch == nil {
		return
	}
	accs, err := d.Store.Accounts()
	if err != nil {
		d.Log.Error("load accounts", "err", err)
		return
	}
	now := time.Now()
	d.fastPollOnSwitch(ctx, now)
	d.checkUnregistered(ctx, accs)
	active := ""
	if d.Active != nil {
		active = d.Active(ctx)
	}
	for _, a := range accs {
		if a.ID == active {
			// Claude Code refreshes the active credential on use, so an
			// observed-active account cannot have a dead lineage: lift any
			// quarantine (and its note) here — the one lift that needs no
			// switch or re-poll (a user recovering a quarantined account by
			// re-logging-in makes it active, and nothing else may touch it).
			d.mu.Lock()
			_, wasQuarantined := d.quarantine[a.ID]
			delete(d.quarantine, a.ID)
			if wasQuarantined && d.tokenNotes[a.ID] == deadLineageNote {
				delete(d.tokenNotes, a.ID)
			}
			d.mu.Unlock()
			if wasQuarantined {
				d.persistQuarantine() // the lift must survive a restart too
				d.notify(ctx)
			}
		}
		d.mu.Lock()
		// The 429 cooldown is per-account: a throttled account skips its own
		// poll but never silences the rest of the fleet.
		cooling := d.cooling(a.ID, now)
		due := now.After(d.nextPoll[a.ID]) || d.nextPoll[a.ID].IsZero()
		// A quarantined account has a provably dead refresh token: polling it
		// only draws a 401 every pass. Skip it — the dashboard already shows
		// the honest note; the lift above runs when the user re-logs-in.
		_, quarantined := d.quarantine[a.ID]
		d.mu.Unlock()
		if cooling || !due || quarantined {
			continue
		}
		if d.staleIdle(ctx, a, now) {
			continue
		}
		// The rolling budget is the last gate before the network: a spent
		// window pushes this account's next poll to when a slot frees up.
		d.mu.Lock()
		wait := d.budgetWait(a.ID, now)
		if wait > 0 {
			if until := now.Add(wait); d.nextPoll[a.ID].Before(until) {
				d.nextPoll[a.ID] = until
			}
		}
		d.mu.Unlock()
		if wait > 0 {
			d.Log.Warn("usage poll budget spent — waiting for a slot", "account", a.ID, "wait", wait.Round(time.Second))
			continue
		}
		d.pollOne(ctx, a)
	}
}

// budgetWait reports how long account id must wait before its next usage GET
// under HourlyPollBudget (0 = a slot is free). Caller holds d.mu.
func (d *Daemon) budgetWait(id string, now time.Time) time.Duration {
	times := d.pollTimes[id]
	cut := now.Add(-time.Hour)
	for len(times) > 0 && !times[0].After(cut) {
		times = times[1:]
	}
	if len(times) < HourlyPollBudget {
		return 0
	}
	return times[len(times)-HourlyPollBudget].Add(time.Hour).Sub(now)
}

// recordPoll notes one usage GET in the rolling budget window, pruning aged
// entries. Caller holds d.mu.
func (d *Daemon) recordPoll(id string, now time.Time) {
	times := d.pollTimes[id]
	cut := now.Add(-time.Hour)
	kept := times[:0]
	for _, t := range times {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	d.pollTimes[id] = append(kept, now)
}

// pollGap is the per-account floor between two usage GETs: MinPollGap in
// production, the configured interval when a test runs faster than that.
func (d *Daemon) pollGap() time.Duration {
	if d.AllowFastPoll && d.PollInterval < MinPollGap {
		return d.PollInterval
	}
	return MinPollGap
}

// resetPull returns the post-reset poll time when some bucket resets in the
// future: a beat after the earliest reset, jittered so a fleet sharing a
// reset instant doesn't stampede the endpoint, floored at pollGap from now.
func (d *Daemon) resetPull(buckets []store.Bucket, now time.Time) (time.Time, bool) {
	var earliest time.Time
	for _, b := range buckets {
		if b.ResetsAt == nil || !b.ResetsAt.After(now) {
			continue
		}
		if earliest.IsZero() || b.ResetsAt.Before(earliest) {
			earliest = *b.ResetsAt
		}
	}
	if earliest.IsZero() {
		return time.Time{}, false
	}
	pull := earliest.Add(10*time.Second + time.Duration(rand.Int63n(int64(20*time.Second)))) //nolint:gosec // schedule jitter, not crypto
	if floor := now.Add(d.pollGap()); pull.Before(floor) {
		pull = floor
	}
	return pull, true
}

// staleIdle is the read-only stale gate, run only when a poll is due (at most
// once per PollInterval per account — Expiry reads the locally stored
// credential, no network). A stored token past expiry means a poll would only
// 401, and a background refresh would arm Anthropic's refresh throttle
// (#38248) — so the account goes stale instead: last-known snapshot, honest
// badge, zero network. The stored expiry moving forward — the user used or
// switched to the account, so Claude Code refreshed it — reopens the gate on
// the next due pass. Applies to the active account too: an all-night-idle
// active account is just as expired, and gating it beats 401-hammering.
// The autopilot's strict revive is the one sanctioned waker besides the
// user: a single budget-governed, proven refresh at switch time (P3) —
// still never a periodic refresh loop.
func (d *Daemon) staleIdle(ctx context.Context, a store.Account, now time.Time) bool {
	if d.Expiry == nil {
		return false
	}
	exp, err := d.Expiry(ctx, a)
	if err != nil || exp.IsZero() {
		return false // expiry unknown — poll and let the server answer
	}
	d.mu.Lock()
	recorded, isStale := d.stale[a.ID]
	d.mu.Unlock()
	if isStale {
		if !exp.Equal(recorded) {
			// The stored credential CHANGED since the account went stale —
			// the user woke it. Any change counts, not just a later expiry:
			// a re-login can mint a token expiring EARLIER than the old
			// recorded timestamp, and gating on "later" would freeze that
			// recovered account forever. Reopen; the next poll proves it.
			if d.clearStale(a.ID) {
				d.notify(ctx)
			}
			return false
		}
		// Same credential as when it went stale (whether it expired locally
		// or the server 401'd a valid-looking one): hold, zero network.
		// "Expiry looks valid" is NOT a clear condition — a 401 arrives
		// precisely then, and clearing on looks would flap and re-hammer.
		d.mu.Lock()
		d.nextPoll[a.ID] = now.Add(d.PollInterval) // re-check at poll cadence
		d.mu.Unlock()
		return true
	}
	if !now.After(exp) {
		return false
	}
	d.mu.Lock()
	d.nextPoll[a.ID] = now.Add(d.PollInterval) // re-check the expiry at poll cadence
	d.mu.Unlock()
	if d.markStale(a.ID, exp) {
		d.Log.Info("account went stale — token expired while idle", "account", a.ID)
		d.notify(ctx)
	}
	return true
}

// markStale flags an account stale with the honest note, recording the
// stored expiry observed at mark time (zero = unknown) so staleIdle can
// detect the credential actually changing. Reports whether visible state
// changed.
func (d *Daemon) markStale(id string, exp time.Time) bool {
	d.mu.Lock()
	prev, was := d.stale[id]
	if was && exp.IsZero() && !prev.IsZero() {
		// A failed expiry re-read must never clobber a known baseline: zero
		// would make the next successful read look like a credential change
		// and re-open the flap the baseline exists to prevent.
		exp = prev
	}
	d.stale[id] = exp
	d.mu.Unlock()
	noteChanged := d.setTokenNote(id, staleNote)
	return !was || noteChanged
}

// clearStale lifts the stale flag and its note (never another path's note),
// reporting whether visible state changed.
func (d *Daemon) clearStale(id string) bool {
	d.mu.Lock()
	_, was := d.stale[id]
	delete(d.stale, id)
	changed := was
	if d.tokenNotes[id] == staleNote {
		delete(d.tokenNotes, id)
		changed = true
	}
	d.mu.Unlock()
	return changed
}

// fastPollOnSwitch notices the active account changing (a manual /login, our
// own rotation) and pulls that account's next poll to the earliest instant
// per-account etiquette allows — a switch renders live on every surface in
// seconds, not minutes. The per-account interval floor still holds.
func (d *Daemon) fastPollOnSwitch(ctx context.Context, now time.Time) {
	if d.Active == nil {
		return
	}
	cur := d.Active(ctx)
	d.mu.Lock()
	defer d.mu.Unlock()
	if cur == "" || cur == d.lastActive {
		return
	}
	first := d.lastActive == "" // daemon start: observe, don't fast-poll
	d.lastActive = cur
	if first {
		return
	}
	earliest := d.lastPolled[cur].Add(d.pollGap())
	if earliest.Before(now) {
		// already past the floor — make it due THIS pass (the due check is
		// a strict now.After).
		earliest = now.Add(-time.Nanosecond)
	}
	if earliest.Before(d.nextPoll[cur]) {
		d.nextPoll[cur] = earliest
	}
}

// checkUnregistered surfaces an account that is logged in but absent from
// the registry (a manual /login to a new account): one event + notification
// per distinct email — honest surfacing with a one-command adopt, never a
// silent auto-registration (the daemon must not start polling an account
// the user never told it about).
func (d *Daemon) checkUnregistered(ctx context.Context, accs []store.Account) {
	if d.ActiveEmail == nil {
		return
	}
	email := d.ActiveEmail(ctx)
	registered := email == "" // no login at all is not "unregistered"
	for _, a := range accs {
		if a.Email == email {
			registered = true
			break
		}
	}
	d.mu.Lock()
	fire := !registered && d.lastUnknown != email
	if registered {
		d.lastUnknown = ""
	} else {
		d.lastUnknown = email
	}
	d.mu.Unlock()
	if !fire {
		return
	}
	// The dedup above is in-memory; a daemon restart would re-notify the
	// same email forever (review P2-4). The event log is the durable memory:
	// an unregistered event for this email in the last day stays silent.
	if evs, err := d.Store.Events(50); err == nil {
		for _, e := range evs {
			if e.Kind == "unregistered" && strings.HasPrefix(e.Message, email+" ") &&
				time.Since(e.At) < 24*time.Hour {
				return
			}
		}
	}
	// The GUIs can adopt this now (P4 made adopt resolve by identity, so a
	// new sign-in in the global dir is adoptable there) — the old copy sent
	// the user to a terminal because the cockpit's adopt used to 409.
	msg := email + " is signed in but not in the fleet — add it from Add account in the cockpit"
	if err := d.Store.AppendEvent(store.Event{Kind: "unregistered", Message: msg}); err != nil {
		d.Log.Error("append event", "err", err)
	}
	d.notify(ctx)
	if d.NotifyUser != nil {
		d.NotifyUser(ctx, "llmpilot", msg)
	}
	d.Log.Info("unregistered active account", "email", email)
}

func (d *Daemon) pollOne(ctx context.Context, a store.Account) {
	buckets, err := d.Fetch(ctx, a)
	now := time.Now()

	d.mu.Lock()
	d.lastPolled[a.ID] = now
	d.recordPoll(a.ID, now)
	// jitter ±10% so a fleet of accounts doesn't fire in lockstep.
	jitter := time.Duration(rand.Int63n(int64(d.PollInterval) / 5)) //nolint:gosec // schedule jitter, not crypto
	next := now.Add(d.PollInterval - d.PollInterval/10 + jitter)
	// Reset-aware pull-in: when a bucket resets sooner than the steady
	// cadence, poll just after the reset so the freed headroom shows up
	// promptly instead of a stale near-limit reading lingering a full
	// interval. Only ever pulls EARLIER; the budget and pollGap still floor it.
	if err == nil {
		if pull, ok := d.resetPull(buckets, now); ok && pull.Before(next) {
			next = pull
		}
	}
	d.nextPoll[a.ID] = next
	if err != nil {
		var se *anthropic.StatusError
		unauthorized := false
		rateLimited := false
		switch {
		case errors.As(err, &se) && se.StatusCode == 429:
			until := d.noteRateLimited(a.ID, se.RetryAfter, now)
			rateLimited = true
			d.Log.Warn("usage poll rate-limited — cooling down", "account", a.ID, "until", until)
		case errors.As(err, &se) && se.StatusCode >= 500:
			d.noteServerError(a.ID, now)
			d.Log.Warn("usage poll backing off", "account", a.ID, "status", se.StatusCode)
		case errors.As(err, &se) && se.StatusCode == 401:
			// The token lapsed under us (the stored expiry looked fine, the
			// server disagreed). Same honest treatment as the local stale
			// gate: freeze at last-known, no background refresh — the account
			// wakes when the user uses or switches to it.
			unauthorized = true
			d.Log.Warn("usage poll unauthorized — marking stale", "account", a.ID)
		default:
			d.Log.Error("usage poll", "account", a.ID, "err", err)
		}
		d.mu.Unlock()
		// setTokenNote/markStale lock d.mu themselves — apply AFTER the
		// unlock above, never double-lock.
		if rateLimited {
			d.setTokenNote(a.ID, rateLimitedNote)
		}
		if unauthorized {
			// Record the stored expiry as-of the 401 so staleIdle only
			// reopens the gate when the credential actually changes (an
			// unknown expiry records zero: any learned expiry counts as
			// change, and polls keep probing at cadence meanwhile).
			var exp time.Time
			if d.Expiry != nil {
				if e, eerr := d.Expiry(ctx, a); eerr == nil {
					exp = e
				}
			}
			if d.markStale(a.ID, exp) {
				d.notify(ctx)
			}
		}
		return
	}
	d.clearCooldown(a.ID) // a proven success clears THIS account's 429 gate
	d.mu.Unlock()         // released before store I/O and notify (State re-locks)
	d.enqueueEntitlementCheck(now)

	prev, _ := d.Store.Snapshot(a.ID)
	snap := &store.UsageSnapshot{AccountID: a.ID, AsOf: now.UTC(), Buckets: buckets}
	if err := d.Store.SaveSnapshot(snap); err != nil {
		d.Log.Error("save snapshot", "account", a.ID, "err", err)
		return
	}
	for _, b := range snap.Buckets {
		d.appendHistory(historyKey(a.ID, b.Kind, b.Scope), HistorySample{At: now.UTC(), Percent: b.Percent})
	}
	d.checkThresholds(ctx, a, prev, snap)
	// A proven success is live data: any stale flag or note (rate-limit,
	// stale) is over — nothing else clears them for an idle account.
	staleCleared := d.clearStale(a.ID)
	noteCleared := d.setTokenNote(a.ID, "")
	if prev == nil || !reflect.DeepEqual(prev.Buckets, snap.Buckets) || staleCleared || noteCleared {
		d.notify(ctx)
	}
	d.mu.Lock()
	cooling := d.cooling(a.ID, now)
	d.mu.Unlock()
	if !cooling && d.Freshen != nil && d.Active != nil && d.Active(ctx) == a.ID {
		if changed, err := d.Freshen(ctx, a); err != nil {
			d.Log.Warn("freshen backup", "account", a.ID, "err", err)
		} else if changed {
			d.Log.Info("backup freshened", "account", a.ID)
		}
	}
	d.maybeRotate(ctx)
}

// enqueueEntitlementCheck piggybacks on proven successful network activity.
// The buffered size-one channel coalesces a fleet's simultaneous polls and
// the non-blocking send keeps entitlement outages off the usage critical path.
func (d *Daemon) enqueueEntitlementCheck(now time.Time) {
	if d.Revalidate == nil || d.EntitlementDue == nil || !d.EntitlementDue(now) {
		return
	}
	select {
	case d.revalidateCh <- struct{}{}:
	default:
	}
}

func (d *Daemon) entitlementLoop(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-d.revalidateCh:
			result, err := d.Revalidate(ctx)
			if err != nil {
				d.Log.Warn("entitlement revalidation deferred", "err", err)
				continue
			}
			d.mu.Lock()
			changed := d.licenseStatus != result.Status
			d.licenseStatus = result.Status
			d.mu.Unlock()
			if changed {
				if result.Status == "revoked" {
					if err := d.Store.AppendEvent(store.Event{Kind: "license_revoked", Message: "Pro paused — the purchase was refunded or disputed; contact support@llmpilot.dev if this looks wrong"}); err != nil {
						d.Log.Error("append event", "err", err)
					}
				}
				d.notify(ctx)
			}
		}
	}
}

// rateLimitedNote is the honest surface for a SHORT-transient usage-poll 429:
// the read-only usage GET is throttled but the stored token is still valid, so
// the next poll self-clears — no user action needed. Rendered by the menu bar
// and cockpit.
const rateLimitedNote = "rate-limited by Anthropic — llmpilot will refresh it automatically once the limit clears"

// staleNote is the honest surface for a stale account: its stored token
// expired while idle, and a background refresh would arm Anthropic's refresh
// throttle (issue #38248) — so the data is frozen at last-known until the
// account is woken. Wakers: the user (open/switch), or the autopilot's
// strict revive — one budget-governed, proven refresh at switch time, never
// a periodic loop (P3). Rendered by the menu bar and cockpit.
const staleNote = "usage may be out of date — open this account in Claude Code, or switch to it here, to refresh"

// deadLineageNote is the honest surface for a provably dead refresh-token
// lineage (the token endpoint rejected the grant at switch time): a re-login
// is the only recovery. Rendered by the menu bar and cockpit.
const deadLineageNote = "sign-in expired — log in to this account again to recover it"

// QuarantineDeadLineage marks an account's refresh-token lineage provably
// dead. Only an activation attempt can discover this (the switch-time
// freshen or the autopilot revive getting invalid_grant — the daemon still
// runs no periodic refresh); both writers funnel through this method. The
// poll loop skips the account, autopilot stops nominating it, and the
// quarantine lifts when the account is next observed ACTIVE (the user
// re-logged-in; see pollDue).
func (d *Daemon) QuarantineDeadLineage(ctx context.Context, id, fingerprint string) {
	d.init()
	d.mu.Lock()
	d.quarantine[id] = fingerprint
	d.mu.Unlock()
	d.persistQuarantine() // survives a daemon restart (see quarantine.go)
	d.setTokenNote(id, deadLineageNote)
	d.Log.Warn("refresh-token lineage dead — quarantined until re-login", "account", id)
	d.notify(ctx)
}

// coolState is one account's rate-limit gate: no usage poll runs for the
// account before until; attempt ratchets the backoff.
type coolState struct {
	until   time.Time
	attempt int
}

// cooling reports whether account id is inside its rate-limit cooldown.
// Caller holds d.mu.
func (d *Daemon) cooling(id string, now time.Time) bool { return now.Before(d.cooldown[id].until) }

// noteRateLimited records a 429 for id (retryAfter from the header, 0 if none)
// and returns the new cool-until. Caller holds d.mu.
func (d *Daemon) noteRateLimited(id string, retryAfter time.Duration, now time.Time) time.Time {
	cs := d.cooldown[id]
	cs.until = now.Add(anthropic.RateLimitBackoff(cs.attempt, retryAfter))
	cs.attempt++
	d.cooldown[id] = cs
	return cs.until
}

// noteServerError records a transient 5xx (short backoff, same per-account
// gate). Caller holds d.mu.
func (d *Daemon) noteServerError(id string, now time.Time) {
	cs := d.cooldown[id]
	cs.until = now.Add(anthropic.Backoff(cs.attempt))
	cs.attempt++
	d.cooldown[id] = cs
}

// clearCooldown resets id's gate after a proven success (only THIS account).
// Caller holds d.mu.
func (d *Daemon) clearCooldown(id string) { delete(d.cooldown, id) }

// setTokenNote records a token warning and reports whether it changed.
func (d *Daemon) setTokenNote(id, note string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.tokenNotes[id] == note {
		return false
	}
	if note == "" {
		delete(d.tokenNotes, id)
	} else {
		d.tokenNotes[id] = note
	}
	return true
}

// notify pushes the current state to every SSE subscriber.
func (d *Daemon) notify(ctx context.Context) {
	st, err := d.State(ctx)
	if err != nil {
		d.Log.Error("assemble state", "err", err)
		return
	}
	d.events.publish(st)
}

// historyKey identifies one burn-rate ring: an account's one bucket kind at
// one scope (scope is "" for unscoped buckets like session/weekly_all).
func historyKey(accountID, kind, scope string) string {
	return accountID + "\x00" + kind + "\x00" + scope
}

// appendHistory records one burn-rate sample, dropping the oldest once the
// ring exceeds historyCap. In-memory only (see Daemon.history doc).
func (d *Daemon) appendHistory(key string, sample HistorySample) {
	d.mu.Lock()
	defer d.mu.Unlock()
	h := append(d.history[key], sample)
	if len(h) > historyCap {
		h = h[len(h)-historyCap:]
	}
	d.history[key] = h
}

// History returns a copy of one bucket's burn-rate ring, oldest first.
func (d *Daemon) History(accountID, kind, scope string) []HistorySample {
	d.mu.Lock()
	defer d.mu.Unlock()
	h := d.history[historyKey(accountID, kind, scope)]
	out := make([]HistorySample, len(h))
	copy(out, h)
	return out
}
