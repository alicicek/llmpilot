package statusline

import (
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// AgeNoteAfter is the honesty window: cache-sourced buckets older than this
// carry a dim age token (a stale cache must never read as live). The native
// rate_limits floor from Claude Code's stdin JSON — live by definition, and
// only present for the active session — always outranks the cache for the
// windows it carries (design: official statusline data over the
// experimental endpoint for the ACTIVE account).
const AgeNoteAfter = 2 * time.Minute

// Sample is one burn-rate observation (mirrors the daemon's history ring —
// defined here too so the engine never imports the daemon).
type Sample struct {
	At      time.Time
	Percent float64
}

// HistoryFn serves burn-rate samples for one bucket. nil = no daemon behind
// this render; daemon-backed segments degrade to hidden.
type HistoryFn func(accountID, kind, scope string) []Sample

// ExecFn runs a custom-command segment's command. nil = execution disabled
// (the daemon preview NEVER executes config-supplied commands — a GET must
// not be a code path into the shell).
type ExecFn func(command string) (string, error)

// Ctx is everything one render reads. Callers fill the data sources they
// have; every segment degrades honestly when its source is nil/empty.
type Ctx struct {
	Now     time.Time
	Loc     *time.Location
	Tier    Tier
	Width   int // terminal columns; 0 = unknown (no collapse)
	In      Payload
	Store   *store.Store  // may be nil (degraded: stdin floor only)
	Dir     claudecfg.Dir // the terminal's config dir (identity resolution)
	Privacy bool          // CLI --privacy override on top of config

	// ActiveID short-circuits identity resolution to a registered account ID.
	// The daemon preview sets it (it knows the active account directly and
	// has no terminal config dir); the binary resolves via Dir.
	ActiveID string

	History  HistoryFn
	Exec     ExecFn
	DaemonUp func() bool // nil = unknown; autopilot segment says so

	// lazily resolved shared state
	resolved   bool
	email      string
	acct       *store.Account
	idx, total int
	accounts   []store.Account
	snap       *store.UsageSnapshot // active account's cached snapshot
	snaps      map[string]*store.UsageSnapshot

	cfgLoaded bool
	pilotCfg  store.Config

	// floor guard memo (see floorguard.go)
	floorChecked bool
	floorOK      bool
}

func (c *Ctx) defaults() {
	if c.Loc == nil {
		c.Loc = time.Local
	}
	if c.Now.IsZero() {
		c.Now = time.Now()
	}
}

// resolve maps the terminal's config dir to a registered account via the
// dir's CURRENT oauthAccount identity (a global swap changes who lives in
// ~/.claude — the registry's config_dir alone would lie right after one).
func (c *Ctx) resolve() {
	if c.resolved {
		return
	}
	c.resolved = true
	if c.ActiveID == "" {
		if oa, err := c.Dir.OAuthAccount(); err == nil && oa != nil {
			c.email = oa.EmailAddress
		}
	}
	if c.Store == nil {
		return
	}
	accs, err := c.Store.Accounts()
	if err != nil {
		return
	}
	c.accounts = accs
	c.total = len(accs)
	for i := range accs {
		match := (c.ActiveID != "" && accs[i].ID == c.ActiveID) ||
			(c.ActiveID == "" && c.email != "" && accs[i].Email == c.email)
		if match {
			c.acct = &accs[i]
			c.email = accs[i].Email
			c.idx = i + 1
			break
		}
	}
	if c.acct != nil {
		c.snap, _ = c.Store.Snapshot(c.acct.ID)
	}
}

// snapshot returns (and caches) any account's usage snapshot.
func (c *Ctx) snapshot(accountID string) *store.UsageSnapshot {
	if c.Store == nil {
		return nil
	}
	if c.snaps == nil {
		c.snaps = map[string]*store.UsageSnapshot{}
	}
	if s, ok := c.snaps[accountID]; ok {
		return s
	}
	s, _ := c.Store.Snapshot(accountID)
	c.snaps[accountID] = s
	return s
}

// pilotConfig lazily loads $LLMPILOT_HOME/config.json for the segments that
// need the autopilot policy.
func (c *Ctx) pilotConfig() store.Config {
	if !c.cfgLoaded {
		c.cfgLoaded = true
		if c.Store != nil {
			c.pilotCfg, _ = c.Store.Config()
		}
	}
	return c.pilotCfg
}

// sessionBucket finds the active account's session-window bucket from the
// freshest source (cache first, stdin floor as fallback).
func (c *Ctx) sessionBucket() *store.Bucket {
	c.resolve()
	if c.snap != nil {
		for i := range c.snap.Buckets {
			b := c.snap.Buckets[i]
			if b.Kind == "session" || b.Kind == "five_hour" {
				return &b
			}
		}
	}
	if w := c.In.RateLimits.FiveHour; w != nil && c.floorAllowed() {
		b := w.Bucket("five_hour", c.Loc)
		return &b
	}
	return nil
}
