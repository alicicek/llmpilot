package statusline

// Floor-vs-identity guard (P1 carry-over, closed in P2): stdin rate_limits
// are per-SESSION, but the identity a render attributes them to is the
// config dir's CURRENT oauthAccount — and a global swap changes the latter
// while old sessions keep running (and keep emitting the OLD account's
// windows). Unguarded, a swap pins the outgoing account's live floor onto
// the new identity's row.
//
// The §2b receipt (strings on the 2.1.220 binary + the current docs) found
// stdin DOES carry a session field — `session_id`, stable per session — so
// per the wave decision the guard binds on it and the swap-instant-marker
// leg is dropped. Each session is bound, write-once, to the identity its
// dir held when the session was FIRST seen; a floor is attributed only
// while the binding matches the dir's current identity. Consequences:
//   - an old session's floor is never attributed to the new identity — for
//     any duration, not a grace window;
//   - a session started after the swap binds to the new identity and its
//     floor is valid immediately;
//   - swapping BACK revalidates the old session's floor (binding matches
//     again);
//   - pinned-dir sessions bind to the pinned identity, which a global swap
//     never changes — their floors are never suppressed.
//
// RESIDUAL (accepted, stated honestly): a session that was never rendered
// before a swap binds, at its first post-swap render, to the then-current
// identity — nothing in the payload carries the ACCOUNT, so a first
// sighting cannot know who the session belonged to. This is strictly
// narrower than the pre-P2 hazard (every old session) and the alternative
// marker design (a fixed grace window with the same blind spot).
//
// Bindings are one tiny write-once file per session under $LLMPILOT_HOME
// (shared by CLI and daemon per the home-split lesson) — read cost is one
// small file open per render, far inside the 50ms budget; O_EXCL creation
// makes the first writer win with no read-modify-write race.

import (
	"os"
	"path/filepath"
	"strings"
	"time"
)

// sessionBindingsDirName holds the per-session identity bindings.
const sessionBindingsDirName = "session-identities"

// sessionBindingTTL prunes bindings whose file mtime is older than this.
// The mtime is refreshed on every render of a live session (see
// floorAllowed), so a binding only ages out after the session has been
// GONE this long — pruning never deletes a live session's binding. Pruning
// runs only on the rare first-sight bind, never on the per-render read path.
const sessionBindingTTL = 14 * 24 * time.Hour

// floorAllowed reports whether stdin rate_limits may be attributed to the
// dir's current identity. Resolved once per render.
func (c *Ctx) floorAllowed() bool {
	if c.floorChecked {
		return c.floorOK
	}
	c.floorChecked = true
	c.floorOK = true
	if c.In.SessionID == "" || c.Store == nil {
		// No session key to bind (older CC, the daemon preview) or no home
		// to persist bindings in: no registered-account row exists to
		// misattribute against in the latter case; render as before.
		return c.floorOK
	}
	c.resolve()
	dir := filepath.Join(c.Store.Home(), sessionBindingsDirName)
	path := filepath.Join(dir, sanitizeSessionID(c.In.SessionID))
	if data, err := os.ReadFile(path); err == nil {
		bound := strings.TrimSpace(string(data))
		c.floorOK = bound == c.email
		// Touch the binding so its mtime tracks LAST render, not first sight:
		// otherwise pruneSessionBindings (TTL) could delete a still-live
		// long-running session's binding, and its next render would re-bind
		// to the then-current identity — re-opening the swap window the guard
		// closes (review P2, 2026-07-25). Best-effort; a failure only risks
		// the residual, never a wrong attribution.
		_ = os.Chtimes(path, c.Now, c.Now)
		return c.floorOK
	}
	// First sight: bind this session to the dir's current identity,
	// write-once (O_EXCL — a concurrent first render wins the create and
	// both read the same value next time).
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return c.floorOK
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		if os.IsExist(err) {
			if data, rerr := os.ReadFile(path); rerr == nil {
				c.floorOK = strings.TrimSpace(string(data)) == c.email
			}
		}
		return c.floorOK
	}
	_, _ = f.WriteString(c.email + "\n")
	_ = f.Close()
	pruneSessionBindings(dir, c.Now)
	return c.floorOK
}

// sanitizeSessionID keeps binding filenames safe: allowlisted bytes only,
// bounded length (session ids are UUIDs; anything else is degraded, not
// trusted with path characters).
func sanitizeSessionID(id string) string {
	var b strings.Builder
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
		if b.Len() >= 80 {
			break
		}
	}
	if b.Len() == 0 {
		return "_"
	}
	return b.String()
}

// pruneSessionBindings drops bindings older than the TTL. Runs only on a
// first-sight bind — never on the per-render read path.
func pruneSessionBindings(dir string, now time.Time) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			continue
		}
		if now.Sub(info.ModTime()) > sessionBindingTTL {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}
