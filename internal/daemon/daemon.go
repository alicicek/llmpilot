// Package daemon is llmpilot's always-on brain: it polls every registered
// account's usage buckets, keeps snapshots cached under $LLMPILOT_HOME,
// proactively refreshes idle tokens before they expire, and serves state to
// every surface over a unix socket and 127.0.0.1.
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

// MinPollInterval is the endpoint-etiquette floor: never more than one usage
// GET per account per 300s.
const MinPollInterval = 300 * time.Second

// DefaultRefreshLead is how long before token expiry the idle refresh kicks
// in. Claude Code's own refresh fires near expiry; leading by an hour keeps
// idle accounts warm without racing it.
const DefaultRefreshLead = time.Hour

// Fetcher fetches one account's current buckets.
type Fetcher func(ctx context.Context, acct store.Account) ([]store.Bucket, error)

// Switcher performs a full account swap to the target account ID.
type Switcher func(ctx context.Context, targetID string) error

// Refresher refreshes one account's token by delegation to `claude auth
// status` under the account's CLAUDE_CONFIG_DIR. It is the FALLBACK path when
// the direct keep-warm refresh fails transiently (verified read-only in CC
// 2.1.211 — refreshIdle checks whether the expiry actually moved).
type Refresher func(ctx context.Context, acct store.Account) error

// KeepWarmStatus reports the outcome of one direct keep-warm refresh.
// Fingerprint is the credential's refresh-token lineage identity; the daemon
// keys its quarantine on it so a re-login (new lineage) auto-clears.
type KeepWarmStatus struct {
	Rotated     bool
	Dead        bool // the token endpoint permanently rejected the grant
	Fingerprint string
	Expiry      time.Time
}

// KeepWarmer refreshes one idle account's token directly against the OAuth
// endpoint (internal/switcher keep-warm engine). A permanent invalid_grant
// comes back as Dead=true with a nil error; transient failures return an
// error. nil = keep-warm off (delegation-only).
type KeepWarmer func(ctx context.Context, acct store.Account) (KeepWarmStatus, error)

// Fingerprinter returns the refresh-token lineage fingerprint of an account's
// stored credential — no network. The daemon uses it to notice a quarantined
// account was re-logged-in (its lineage changed) so it can retry.
type Fingerprinter func(ctx context.Context, acct store.Account) (string, error)

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

// AdoptFn registers the account at a detected config dir exactly like
// `llmpilot init` (same ID/label derivation) and returns the registered
// account (POST /v1/adopt).
type AdoptFn func(ctx context.Context, d detect.Detected, label string) (store.Account, error)

// Daemon owns the poll loop, the refresh loop, and the state served to
// surfaces. Zero-value fields get safe defaults in Run.
type Daemon struct {
	Store   *store.Store
	Fetch   Fetcher
	Switch  Switcher
	Refresh Refresher
	Expiry  ExpiryFn
	Active  ActiveFn
	Log     *slog.Logger

	// KeepWarm is the direct OAuth refresh for idle accounts (the Wave 8.3
	// pillar). Fingerprint reads an account's lineage identity for the
	// quarantine self-heal. Both nil = keep-warm off; refreshIdle falls back
	// to the Refresh delegation alone.
	KeepWarm    KeepWarmer
	Fingerprint Fingerprinter

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

	// WebFS is the embedded cockpit (web.Dist()); nil = API only.
	WebFS fs.FS

	// NowFn overrides the daemon's clock (nil = time.Now): the statusline
	// preview render AND the refresh loop's expiry/backoff math read it, so a
	// test can pin token expiry deterministically without sleeping.
	NowFn func() time.Time

	// Detect lists config dirs with a logged-in account for GET /v1/detect
	// (nil = 501, detect not wired). Adopt registers one of those dirs for
	// POST /v1/adopt (nil = 501). Both injected — like every other
	// filesystem/Keychain-touching field — so daemon tests never scan or
	// mutate the real machine's Claude Code state.
	Detect DetectFn
	Adopt  AdoptFn

	// PollInterval is clamped up to MinPollInterval unless AllowFastPoll
	// (tests only) is set.
	PollInterval  time.Duration
	AllowFastPoll bool
	RefreshLead   time.Duration
	RefreshCheck  time.Duration // how often the refresh loop scans

	// schedMu serializes schedule mutations (read set → launchd sync → save):
	// two concurrent cockpit writes would otherwise lose one caller's change
	// after launchd already synced both views (Greptile P1, 2026-07-11).
	// Separate from mu — launchctl execs must not block the poll path.
	// NOTE: this covers the daemon's own handlers only; a CLI `llmpilot
	// schedule` write racing a live daemon is a separate-process race the
	// mutex cannot see (accepted for a single-user tool; the daemon re-reads
	// schedules.json fresh on every State call either way).
	schedMu sync.Mutex

	mu             sync.Mutex
	nextPoll       map[string]time.Time
	lastPolled     map[string]time.Time
	tokenNotes     map[string]string
	quarantine     map[string]string // accountID → dead lineage fingerprint
	lastSwitch     time.Time         // last rotation ATTEMPT — cooldown covers failures too
	lastActive     string            // last observed active account (fast-poll on change)
	lastUnknown    string            // last unregistered email surfaced (once per email)
	lastRotateFail string            // last failure event text — repeats log, not spam
	licenseStatus  string            // last online status projection; no token/id/PII
	licenseError   string            // last terminal licensing refusal code, "" when none
	// shared 429 backoff: no account polls before this instant.
	pausedUntil time.Time
	attempt     int
	// shared OAuth-refresh-endpoint 429 backoff (separate budget from usage).
	refreshPausedUntil time.Time
	refreshAttempt     int

	// history is the in-memory burn-rate ring per (account, bucket kind+
	// scope) — GET /v1/history. Deliberately NOT persisted: a restart is an
	// honestly empty sparkline, never a fabricated one.
	history map[string][]HistorySample

	events       *broadcaster
	once         sync.Once
	revalidateCh chan struct{}
	// refreshNudge coalesces a "refresh now" request from the poll path (an
	// idle account 401'd — its token lapsed between refresh passes) so the
	// refresh loop heals it in seconds instead of at the next 10-minute tick.
	refreshNudge chan struct{}

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
		d.tokenNotes = map[string]string{}
		d.quarantine = map[string]string{}
		d.history = map[string][]HistorySample{}
		d.events = newBroadcaster()
		d.revalidateCh = make(chan struct{}, 1)
		d.refreshNudge = make(chan struct{}, 1)
		if d.Log == nil {
			d.Log = slog.Default()
		}
		if tok, err := newAuthToken(); err == nil {
			d.authToken = tok
		} else {
			// Fail closed twice over: an empty token never matches, so guarded
			// license routes answer 401 on a bare Handler(), and Serve()
			// refuses to start at all rather than run without a token file.
			d.Log.Error("auth token generation failed — license actions disabled", "err", err)
		}
		if d.PollInterval < MinPollInterval && !d.AllowFastPoll {
			d.PollInterval = MinPollInterval
		}
		if d.RefreshLead == 0 {
			d.RefreshLead = DefaultRefreshLead
		}
		if d.RefreshCheck == 0 {
			d.RefreshCheck = 10 * time.Minute
		}
	})
}

// AccountState is one account plus its latest cached snapshot. TokenNote is
// a human-readable warning when the stored token is expiring and the
// delegated refresh had no effect — surfaced honestly, never papered over
// (`claude auth status` is read-only in CC 2.1.205).
type AccountState struct {
	store.Account
	Snapshot  *store.UsageSnapshot `json:"snapshot,omitempty"`
	TokenNote string               `json:"token_note,omitempty"`
}

// State is the full document served at GET /v1/state and pushed over SSE.
// Events is the recent tail of the autopilot event log, oldest first.
// Schedules is never null — an empty fleet still renders an empty array on
// every surface that decodes this JSON.
type State struct {
	Accounts  []AccountState   `json:"accounts"`
	ActiveID  string           `json:"active_id,omitempty"`
	Events    []store.Event    `json:"events,omitempty"`
	Schedules []store.Schedule `json:"schedules"`
	License   string           `json:"license_status,omitempty"`
	// LicenseError is the last terminal licensing refusal code
	// (seat_limit_reached, trial_email_used, ...) — a machine code only.
	LicenseError string    `json:"license_error,omitempty"`
	AsOf         time.Time `json:"as_of"`
}

// State assembles the current state from the store's caches.
func (d *Daemon) State(ctx context.Context) (State, error) {
	d.init()
	accs, err := d.Store.Accounts()
	if err != nil {
		return State{}, err
	}
	st := State{AsOf: time.Now().UTC()}
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
		d.mu.Unlock()
		st.Accounts = append(st.Accounts, AccountState{Account: a, Snapshot: snap, TokenNote: note})
	}
	if d.Active != nil {
		st.ActiveID = d.Active(ctx)
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

// Run drives the poll and refresh loops until ctx is done.
func (d *Daemon) Run(ctx context.Context) error {
	d.init()
	if d.Revalidate != nil {
		go d.entitlementLoop(ctx)
	}
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	// The refresh loop runs on its OWN goroutine, not this select: a keep-warm
	// refresh holds credential locks across an ~8s network POST, and it must
	// never stall usage polling or wake arming.
	if (d.KeepWarm != nil || d.Refresh != nil) && d.Expiry != nil {
		go d.refreshLoop(ctx)
	}
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

// refreshLoop drives the idle-token keep-warm on its own goroutine so a
// lock-holding, network-bound refresh never blocks the poll select. Runs one
// pass immediately (a fresh daemon may inherit already-stale idle tokens),
// then every RefreshCheck. Passes never overlap — the ticker waits out a slow
// pass rather than stacking refreshes on the same account.
func (d *Daemon) refreshLoop(ctx context.Context) {
	t := time.NewTicker(d.RefreshCheck)
	defer t.Stop()
	d.refreshIdle(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.refreshIdle(ctx)
		case <-d.refreshNudge:
			d.refreshIdle(ctx)
		}
	}
}

// nudgeRefresh asks the refresh loop to run a pass now (coalesced). Non-
// blocking: a nudge already queued is enough.
func (d *Daemon) nudgeRefresh() {
	select {
	case d.refreshNudge <- struct{}{}:
	default:
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
	for _, a := range accs {
		d.mu.Lock()
		// The 429 pause is shared: one throttled account silences the whole
		// fleet, including later accounts in the same pass.
		paused := now.Before(d.pausedUntil)
		due := now.After(d.nextPoll[a.ID]) || d.nextPoll[a.ID].IsZero()
		// A quarantined account has a provably dead refresh token: polling it
		// only draws a 401 every pass. Skip it — the dashboard already shows
		// the honest "sign-in expired" note; the refresh loop lifts the
		// quarantine the moment the user re-logs-in.
		_, quarantined := d.quarantine[a.ID]
		d.mu.Unlock()
		if paused {
			return
		}
		if !due || quarantined {
			continue
		}
		d.pollOne(ctx, a)
	}
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
	earliest := d.lastPolled[cur].Add(d.PollInterval)
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
// the owner never told it about).
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
	msg := email + " is logged in but not registered — `llmpilot init` adopts it"
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
	// jitter ±10% so a fleet of accounts doesn't fire in lockstep.
	jitter := time.Duration(rand.Int63n(int64(d.PollInterval) / 5)) //nolint:gosec // schedule jitter, not crypto
	d.nextPoll[a.ID] = now.Add(d.PollInterval - d.PollInterval/10 + jitter)
	if err != nil {
		var se *anthropic.StatusError
		nudge := false
		switch {
		case errors.As(err, &se) && (se.StatusCode == 429 || se.StatusCode >= 500):
			d.pausedUntil = now.Add(anthropic.Backoff(d.attempt))
			d.attempt++
			d.Log.Warn("usage poll backing off", "account", a.ID, "status", se.StatusCode, "until", d.pausedUntil)
		case errors.As(err, &se) && se.StatusCode == 401:
			// The access token lapsed (an idle account whose token expired
			// between refresh passes). Ask the refresh loop to heal it now
			// rather than 401-ing every poll until the next 10-minute tick.
			nudge = true
			d.Log.Warn("usage poll unauthorized — nudging refresh", "account", a.ID)
		default:
			d.Log.Error("usage poll", "account", a.ID, "err", err)
		}
		d.mu.Unlock()
		if nudge {
			d.nudgeRefresh()
		}
		return
	}
	d.attempt = 0
	d.mu.Unlock() // released before store I/O and notify (State re-locks)
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
	if prev == nil || !reflect.DeepEqual(prev.Buckets, snap.Buckets) {
		d.notify(ctx)
	}
	if d.Freshen != nil && d.Active != nil && d.Active(ctx) == a.ID {
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

// quarantineNote is the honest surface for a dead refresh-token lineage: a
// plain re-login is the only recovery (unlike an expiring-but-live token,
// which any claude session refreshes). Rendered by the menu bar and cockpit.
const quarantineNote = "sign-in expired — log in to this account again, then run `llmpilot account add`"

// refreshIdle keeps every idle account's token fresh — the Wave 8.3 pillar.
// For each account within RefreshLead of expiry (and NOT the active account,
// which Claude Code owns), it tries a direct OAuth refresh; a permanent
// invalid_grant quarantines the account with an honest note; a transient
// failure falls back to the `claude auth status` delegation, and if THAT
// didn't move the expiry either, an honest expiring/expired note. A dead
// lineage self-heals: once the user re-logs-in its fingerprint changes and
// the next pass retries.
func (d *Daemon) refreshIdle(ctx context.Context) {
	accs, err := d.Store.Accounts()
	if err != nil {
		d.Log.Error("load accounts", "err", err)
		return
	}
	active := ""
	if d.Active != nil {
		active = d.Active(ctx)
	}
	now := d.now()
	changed := false
	for _, a := range accs {
		if a.ID == active {
			// Claude Code owns the active account's credential (refreshes on
			// use, caches ~30s). Racing it is the clobber hazard — never. But
			// the active account is healthy BY DEFINITION, so clear any stale
			// quarantine/note here: a user who re-logs-in to recover a
			// quarantined account makes it active, and this is the only place
			// that can lift the quarantine once it is (poll skips it, and the
			// idle branches below never run for the active account).
			if d.clearAccountNote(a.ID) {
				changed = true
			}
			continue
		}
		exp, err := d.Expiry(ctx, a)
		if err != nil || exp.IsZero() {
			continue // no expiry known — nothing to lead on
		}
		if exp.Sub(now) > d.RefreshLead {
			if d.clearAccountNote(a.ID) {
				changed = true
			}
			continue
		}
		// Quarantined dead lineage: skip the network entirely until the user
		// re-logs-in (the stored credential's fingerprint then changes).
		if d.quarantined(ctx, a) {
			if d.setTokenNote(a.ID, quarantineNote) {
				changed = true
			}
			continue
		}
		if d.tryKeepWarm(ctx, a, exp, now) {
			changed = true
		}
	}
	if changed {
		d.notify(ctx)
	}
}

// tryKeepWarm runs one refresh attempt for a near-expiry idle account and
// records the resulting note/quarantine. Returns whether visible state
// changed.
func (d *Daemon) tryKeepWarm(ctx context.Context, a store.Account, exp, now time.Time) bool {
	// Re-check the shared refresh-endpoint pause per account (NOT once per
	// pass): a 429 on the first account must stop the rest of the fleet in the
	// same pass, or a fleet of near-expiry accounts hammers the endpoint.
	d.mu.Lock()
	refreshPaused := now.Before(d.refreshPausedUntil)
	d.mu.Unlock()
	if d.KeepWarm != nil && !refreshPaused {
		status, err := d.KeepWarm(ctx, a)
		switch {
		case err == nil && status.Rotated:
			d.Log.Info("idle refresh done", "account", a.ID, "expires", status.Expiry)
			d.mu.Lock()
			d.refreshAttempt = 0 // a success clears the endpoint-backoff ratchet
			d.mu.Unlock()
			return d.clearAccountNote(a.ID)
		case err == nil && status.Dead:
			d.Log.Warn("idle refresh: refresh token dead — quarantined", "account", a.ID)
			d.setQuarantine(a.ID, status.Fingerprint)
			return d.setTokenNote(a.ID, quarantineNote)
		case err != nil:
			d.noteRefreshFailure(err, now)
			d.Log.Warn("idle refresh (direct)", "account", a.ID, "err", err)
			// fall through to the delegation fallback below
		default:
			// The engine skipped (e.g. CC already refreshed under its lock, or
			// no refresh token) — fall through to re-verify expiry honestly.
		}
	}
	// Fallback: the read-only delegation, then verify the expiry actually
	// moved (it usually will not in current Claude Code — hence the note).
	if d.Refresh != nil {
		if err := d.Refresh(ctx, a); err != nil {
			d.Log.Warn("idle refresh (delegated)", "account", a.ID, "err", err)
		}
	}
	after, err := d.Expiry(ctx, a)
	note := ""
	switch {
	case err == nil && after.After(exp):
		d.Log.Info("idle refresh done (delegated)", "account", a.ID, "expires", after)
	case now.After(exp):
		note = "token expired — run any claude session on this account to refresh"
	default:
		note = "token expiring " + exp.Sub(now).Round(time.Minute).String() +
			" — run any claude session on this account to refresh"
	}
	return d.setTokenNote(a.ID, note)
}

// noteRefreshFailure records a shared OAuth-endpoint backoff on a 429 so the
// daemon does not hammer the token endpoint across the fleet.
func (d *Daemon) noteRefreshFailure(err error, now time.Time) {
	var re *anthropic.StatusError
	var rfe *anthropic.RefreshError
	is429 := (errors.As(err, &re) && re.StatusCode == 429) ||
		(errors.As(err, &rfe) && rfe.StatusCode == 429)
	if !is429 {
		return
	}
	d.mu.Lock()
	d.refreshPausedUntil = now.Add(anthropic.Backoff(d.refreshAttempt))
	d.refreshAttempt++
	d.mu.Unlock()
}

// quarantined reports whether an account's lineage is a known-dead one that
// has NOT changed (a re-login would change the fingerprint and lift the
// quarantine). Reads the stored fingerprint (no network).
func (d *Daemon) quarantined(ctx context.Context, a store.Account) bool {
	d.mu.Lock()
	dead := d.quarantine[a.ID]
	d.mu.Unlock()
	if dead == "" {
		return false
	}
	if d.Fingerprint == nil {
		return true // can't check for a re-login; stay quarantined (honest)
	}
	fp, err := d.Fingerprint(ctx, a)
	if err != nil || fp == "" {
		return true
	}
	if fp != dead {
		// Re-login: the lineage changed. Lift the quarantine and let the next
		// step retry the refresh.
		d.mu.Lock()
		delete(d.quarantine, a.ID)
		d.mu.Unlock()
		return false
	}
	return true
}

func (d *Daemon) setQuarantine(id, fingerprint string) {
	d.mu.Lock()
	d.quarantine[id] = fingerprint
	d.mu.Unlock()
}

// clearAccountNote clears any token note AND any quarantine for an account,
// reporting whether visible state changed.
func (d *Daemon) clearAccountNote(id string) bool {
	d.mu.Lock()
	_, wasQuarantined := d.quarantine[id]
	delete(d.quarantine, id)
	d.mu.Unlock()
	noteChanged := d.setTokenNote(id, "")
	return noteChanged || wasQuarantined
}

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
