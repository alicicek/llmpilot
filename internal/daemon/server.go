package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alicicek/llmpilot/internal/analytics"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// SocketPath is the unix socket under one llmpilot home.
func SocketPath(home string) string { return filepath.Join(home, "daemon.sock") }

// LockFilePath is the single-instance flock file under one llmpilot home.
// The file is created once and never unlinked — removing a locked path would
// let a later starter lock a fresh inode and serve alongside the holder.
func LockFilePath(home string) string { return filepath.Join(home, "daemon.lock") }

// ErrAlreadyRunning reports a start against a home whose exclusive lock a
// live daemon already holds. Callers treat it as success (exit 0): the
// launchd KeepAlive SuccessfulExit=false contract must not respawn-loop a
// second copy, and both the app-bundled agent and `daemon install` funnel
// through this same guard.
var ErrAlreadyRunning = errors.New("daemon already running")

// PortFilePath is where the daemon persists its 127.0.0.1 port.
func PortFilePath(home string) string { return filepath.Join(home, "daemon.port") }

// Handler is the daemon's HTTP API, served identically on the unix socket
// and the loopback listener.
func (d *Daemon) Handler() http.Handler {
	d.init()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/state", d.handleState)
	mux.HandleFunc("GET /v1/events", d.handleEvents)
	mux.HandleFunc("POST /v1/switch", d.handleSwitch)
	mux.HandleFunc("GET /v1/schedules", d.handleSchedulesList)
	mux.HandleFunc("POST /v1/schedules", d.handleScheduleCreate)
	mux.HandleFunc("PUT /v1/schedules/{id}", d.handleScheduleUpdate)
	mux.HandleFunc("DELETE /v1/schedules/{id}", d.handleScheduleDelete)
	mux.HandleFunc("GET /v1/doctor", d.handleDoctor)
	mux.HandleFunc("GET /v1/detect", d.handleDetect)
	mux.HandleFunc("POST /v1/adopt", d.handleAdopt)
	mux.HandleFunc("POST /v1/adopt/move", d.handleAdoptMove)
	mux.HandleFunc("POST /v1/stash/adopt", d.handleStashAdopt)
	mux.HandleFunc("POST /v1/stash/discard", d.handleStashDiscard)
	mux.HandleFunc("POST /v1/login/start", d.handleLoginStart)
	mux.HandleFunc("POST /v1/login/complete", d.handleLoginComplete)
	mux.HandleFunc("POST /v1/login/browser", d.handleLoginBrowser)
	mux.HandleFunc("GET /v1/login/browser/status", d.handleLoginBrowserStatus)
	mux.HandleFunc("GET /v1/config", d.handleConfigGet)
	mux.HandleFunc("PUT /v1/config", d.handleConfigPut)
	mux.HandleFunc("GET /v1/history", d.handleHistory)
	mux.HandleFunc("GET /v1/analytics", d.handleAnalytics)
	mux.HandleFunc("GET /v1/statusline/preview", d.handleStatuslinePreview)
	mux.HandleFunc("GET /v1/statusline/config", d.handleStatuslineConfigGet)
	mux.HandleFunc("PUT /v1/statusline/config", d.handleStatuslineConfigPut)
	mux.HandleFunc("GET /v1/statusline/segments", d.handleStatuslineSegments)
	mux.HandleFunc("GET /v1/license", d.handleLicenseGet)
	mux.HandleFunc("GET /v1/license/quote", d.handleLicenseQuote)
	mux.HandleFunc("POST /v1/license/checkout", d.handleLicenseCheckout)
	mux.HandleFunc("POST /v1/license/cancel", d.handleLicenseCancel)
	mux.HandleFunc("POST /v1/license/recover", d.handleLicenseRecover)
	mux.HandleFunc("POST /v1/license/recover/claim", d.handleLicenseClaim)
	mux.HandleFunc("POST /v1/license/marker", d.handleLicenseMarker)
	if d.WebFS != nil {
		mux.Handle("GET /", webHandler(d.WebFS))
	}
	return checkHost(mux)
}

// checkHost rejects requests whose Host is not a loopback name. A DNS-rebound
// page reaches the loopback listener with the attacker's hostname in Host; no
// legitimate client does. "llmpilot" is the placeholder Host the CLI and
// statusline send over the unix socket (internal/cli).
func checkHost(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		switch host {
		case "127.0.0.1", "::1", "localhost", "llmpilot":
			next.ServeHTTP(w, r)
		default:
			httpError(w, http.StatusForbidden, errors.New("unrecognized Host"))
		}
	})
}

// requireJSON enforces the anti-CSRF preflight trick (see handleSwitch's
// original comment): a JSON Content-Type on any state-changing request is
// not a CORS "simple" request, so the browser must preflight it — killing
// the no-preflight CSRF vector against the loopback listener. Every mutating
// handler in this file calls this first.
func requireJSON(w http.ResponseWriter, r *http.Request) bool {
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		httpError(w, http.StatusUnsupportedMediaType, errors.New("Content-Type must be application/json"))
		return false
	}
	// Bound the request body: every JSON body this daemon accepts is small
	// (an id, a fingerprint, a schedule). 64KiB is generous headroom without
	// letting a local caller stream an unbounded body into a Decode (review
	// note: the daemon had no MaxBytesReader anywhere). Loopback + token
	// guarded, so this is defense-in-depth, not a security boundary.
	r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
	return true
}

func (d *Daemon) handleState(w http.ResponseWriter, r *http.Request) {
	st, err := d.State(r.Context())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	writeJSON(w, http.StatusOK, st)
}

func (d *Daemon) handleEvents(w http.ResponseWriter, r *http.Request) {
	fl, ok := w.(http.Flusher)
	if !ok {
		httpError(w, http.StatusInternalServerError, errors.New("streaming unsupported"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)

	// Subscribe BEFORE sending the initial snapshot: a state change published
	// in the window between the snapshot and the subscribe would otherwise be
	// dropped (no subscriber registered yet), and the client would block
	// forever waiting for an event that already fired. The channel is buffered
	// and coalesces to the latest state, so the worst case is a harmless
	// duplicate of the initial render, never a lost update.
	ch := d.events.subscribe()
	defer d.events.unsubscribe(ch)

	// Send the current state immediately so a new subscriber renders at once.
	if st, err := d.State(r.Context()); err == nil {
		writeSSE(w, st)
		fl.Flush()
	}
	for {
		select {
		case <-r.Context().Done():
			return
		case st := <-ch:
			writeSSE(w, st)
			fl.Flush()
		}
	}
}

func writeSSE(w http.ResponseWriter, st State) {
	data, err := json.Marshal(st)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "event: state\ndata: %s\n\n", data)
}

func (d *Daemon) handleSwitch(w http.ResponseWriter, r *http.Request) {
	if d.Switch == nil {
		httpError(w, http.StatusNotImplemented, errors.New("switching not wired"))
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		AccountID string `json:"account_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AccountID == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"account_id": "<id>"}`))
		return
	}
	// Refuse a pinned target HERE, before d.Switch runs its switch-time
	// freshen: the swap is provably doomed (Swap refuses pinned accounts
	// outright), and a doomed action must spend no refresh budget and take no
	// config-dir lock. The copy states what the account is for — keeping an
	// account in its own folder is a choice, not a mistake.
	if d.Pinned != nil {
		if acct, ok := d.accountByID(req.AccountID); ok && d.Pinned(acct) {
			httpError(w, http.StatusConflict, fmt.Errorf(
				"%s signs in from its own folder (%s), so llmpilot watches it instead of switching to it — move it into the fleet to make it switchable",
				acct.Label, acct.ConfigDir))
			return
		}
	}
	if err := d.Switch(r.Context(), req.AccountID); err != nil {
		httpError(w, http.StatusConflict, err)
		return
	}
	// A swap may have preserved an unknown credential — surface it as an
	// event before the state push carries the new stash entry.
	d.noteNewStashEntries(r.Context())
	d.notify(r.Context())
	writeJSON(w, http.StatusOK, map[string]string{"switched_to": req.AccountID})
}

// accountByID looks one registered account up by ID.
func (d *Daemon) accountByID(id string) (store.Account, bool) {
	accs, err := d.Store.Accounts()
	if err != nil {
		d.Log.Warn("load accounts", "err", err)
		return store.Account{}, false
	}
	for _, a := range accs {
		if a.ID == id {
			return a, true
		}
	}
	return store.Account{}, false
}

// baselineStash records the current stash fingerprints WITHOUT events —
// entries that already existed when the daemon started are not news.
func (d *Daemon) baselineStash(ctx context.Context) {
	if d.StashList == nil {
		return
	}
	entries, err := d.StashList(ctx)
	if err != nil {
		return
	}
	d.mu.Lock()
	d.knownStash = map[string]bool{}
	for _, e := range entries {
		d.knownStash[e.Fingerprint] = true
	}
	d.mu.Unlock()
}

// noteNewStashEntries appends one event per stash entry not seen before
// (kind=stash) and refreshes the known set. Runs after a switch and after
// the startup sweep — the two stash producers.
func (d *Daemon) noteNewStashEntries(ctx context.Context) {
	if d.StashList == nil {
		return
	}
	entries, err := d.StashList(ctx)
	if err != nil {
		d.Log.Warn("read stash", "err", err)
		return
	}
	d.mu.Lock()
	if d.knownStash == nil {
		d.knownStash = map[string]bool{}
	}
	var fresh []pilotapi.StashEntry
	seen := map[string]bool{}
	for _, e := range entries {
		seen[e.Fingerprint] = true
		if !d.knownStash[e.Fingerprint] {
			fresh = append(fresh, e)
		}
	}
	d.knownStash = seen
	d.mu.Unlock()
	for _, e := range fresh {
		who := e.Label
		if who == "" {
			who = "an unknown account"
		}
		msg := fmt.Sprintf("Preserved %s's sign-in from the switched-away slot — adopt or discard it in the cockpit.", who)
		if err := d.Store.AppendEvent(store.Event{Kind: "stash", Message: msg}); err != nil {
			d.Log.Warn("append stash event", "err", err)
		}
	}
}

// handleStashAdopt registers a stashed credential as a switchable account.
// Auth-guarded: a mutation of the fleet from the loopback port needs the
// session token. A quarantined (dead) lineage is refused HERE — adopt must
// surface "needs a fresh sign-in", never silently resurrect.
func (d *Daemon) handleStashAdopt(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if d.StashAdopt == nil {
		httpError(w, http.StatusNotImplemented, errors.New("stash not wired"))
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Fingerprint string `json:"fingerprint"`
		Label       string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Fingerprint == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"fingerprint": "<fp>", "label": "<optional>"}`))
		return
	}
	if len(req.Label) > 200 { // a label is an email-scale display string, not free storage
		httpError(w, http.StatusBadRequest, errors.New("label too long"))
		return
	}
	if d.IsLineageDead(req.Fingerprint) {
		httpError(w, http.StatusConflict, errors.New("this sign-in has expired (dead — needs login) — log in to the account again, then add it"))
		return
	}
	acct, err := d.StashAdopt(r.Context(), req.Fingerprint, req.Label)
	if err != nil {
		// Conflict (the account already holds a newer lineage — review P0)
		// is the caller's decision to make, not a server fault.
		if errors.Is(err, pilotapi.ErrStashConflict) {
			httpError(w, http.StatusConflict, err)
			return
		}
		if errors.Is(err, switcher.ErrNotFound) {
			httpError(w, http.StatusNotFound, errors.New("no stashed sign-in with that fingerprint"))
			return
		}
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.mu.Lock()
	delete(d.knownStash, req.Fingerprint)
	d.mu.Unlock()
	if err := d.Store.AppendEvent(store.Event{Kind: "stash_adopt", AccountID: acct.ID,
		Message: fmt.Sprintf("Adopted %s from the stash — it is switchable now.", acct.Label)}); err != nil {
		d.Log.Warn("append adopt event", "err", err)
	}
	d.notify(r.Context())
	writeJSON(w, http.StatusCreated, acct)
}

// handleStashDiscard removes a stash entry — payload and index. The
// user-visible way out of append-only retention.
func (d *Daemon) handleStashDiscard(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if d.StashDiscard == nil {
		httpError(w, http.StatusNotImplemented, errors.New("stash not wired"))
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Fingerprint string `json:"fingerprint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Fingerprint == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"fingerprint": "<fp>"}`))
		return
	}
	if err := d.StashDiscard(r.Context(), req.Fingerprint); err != nil {
		if errors.Is(err, switcher.ErrNotFound) {
			httpError(w, http.StatusNotFound, errors.New("no stashed sign-in with that fingerprint"))
			return
		}
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.mu.Lock()
	delete(d.knownStash, req.Fingerprint)
	d.mu.Unlock()
	if err := d.Store.AppendEvent(store.Event{Kind: "stash_discard",
		Message: "Discarded a stashed sign-in — its stored credential is deleted."}); err != nil {
		d.Log.Warn("append discard event", "err", err)
	}
	d.notify(r.Context())
	writeJSON(w, http.StatusOK, map[string]string{"discarded": req.Fingerprint})
}

// syncTriggers mirrors scheds into launchd before they are persisted; a
// failure aborts the mutation so disk and launchd never disagree.
func (d *Daemon) syncTriggers(ctx context.Context, scheds []store.Schedule) error {
	if d.TriggerSync == nil {
		return nil
	}
	return d.TriggerSync(ctx, scheds)
}

// afterScheduleMutation is the one place every schedule write ends: re-arm
// the earliest pmset wake for the new set, then push fresh state (which now
// carries schedules) to every SSE subscriber. A WakeSync failure is logged,
// never turned into a failed request — the schedule itself is already saved.
func (d *Daemon) afterScheduleMutation(ctx context.Context) {
	if d.WakeSync != nil {
		if err := d.WakeSync(ctx, time.Now()); err != nil {
			d.Log.Warn("wake sync after schedule mutation", "err", err)
		}
	}
	d.notify(ctx)
}

func (d *Daemon) handleSchedulesList(w http.ResponseWriter, r *http.Request) {
	scheds, err := d.Store.Schedules()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	if scheds == nil {
		scheds = []store.Schedule{}
	}
	writeJSON(w, http.StatusOK, scheds)
}

func (d *Daemon) handleScheduleCreate(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	d.schedMu.Lock()
	defer d.schedMu.Unlock()
	var req struct {
		AccountID string `json:"account_id"`
		Hour      int    `json:"hour"`
		Minute    int    `json:"minute"`
		Model     string `json:"model,omitempty"`
		Effort    string `json:"effort,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"account_id","hour","minute","model?","effort?"}`))
		return
	}
	accs, err := d.Store.Accounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	var acct *store.Account
	for i := range accs {
		if accs[i].ID == req.AccountID {
			acct = &accs[i]
			break
		}
	}
	if acct == nil {
		httpError(w, http.StatusNotFound, fmt.Errorf("no account %q", req.AccountID))
		return
	}
	scheds, err := d.Store.Schedules()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	sched := store.Schedule{
		ID:        store.UniqueScheduleID(scheds, acct.ID, acct.Label, req.Hour, req.Minute),
		AccountID: acct.ID,
		Hour:      req.Hour,
		Minute:    req.Minute,
		Model:     req.Model,
		Effort:    req.Effort,
	}
	if err := sched.Validate(); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	for _, sc := range scheds {
		if sc.ID == sched.ID {
			httpError(w, http.StatusConflict, fmt.Errorf("already scheduled: %s", sc.ID))
			return
		}
	}
	next := append(scheds, sched)
	if err := d.syncTriggers(r.Context(), next); err != nil {
		httpError(w, http.StatusBadGateway, fmt.Errorf("launchd sync failed — schedule not saved: %w", err))
		return
	}
	if err := d.Store.SaveSchedules(next); err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.afterScheduleMutation(r.Context())
	writeJSON(w, http.StatusCreated, sched)
}

func (d *Daemon) handleScheduleUpdate(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	d.schedMu.Lock()
	defer d.schedMu.Unlock()
	id := r.PathValue("id")
	var req struct {
		Hour   int `json:"hour"`
		Minute int `json:"minute"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"hour","minute"}`))
		return
	}
	scheds, err := d.Store.Schedules()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	idx := -1
	for i, sc := range scheds {
		if sc.ID == id {
			idx = i
			break
		}
	}
	if idx == -1 {
		httpError(w, http.StatusNotFound, fmt.Errorf("no schedule %q", id))
		return
	}
	updated := scheds[idx]
	updated.Hour = req.Hour
	updated.Minute = req.Minute
	if err := updated.Validate(); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	scheds[idx] = updated
	if err := d.syncTriggers(r.Context(), scheds); err != nil {
		httpError(w, http.StatusBadGateway, fmt.Errorf("launchd sync failed — schedule not moved: %w", err))
		return
	}
	if err := d.Store.SaveSchedules(scheds); err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.afterScheduleMutation(r.Context())
	writeJSON(w, http.StatusOK, updated)
}

func (d *Daemon) handleScheduleDelete(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	d.schedMu.Lock()
	defer d.schedMu.Unlock()
	id := r.PathValue("id")
	scheds, err := d.Store.Schedules()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	kept := make([]store.Schedule, 0, len(scheds))
	found := false
	for _, sc := range scheds {
		if sc.ID == id {
			found = true
			continue
		}
		kept = append(kept, sc)
	}
	if !found {
		httpError(w, http.StatusNotFound, fmt.Errorf("no schedule %q", id))
		return
	}
	if err := d.syncTriggers(r.Context(), kept); err != nil {
		httpError(w, http.StatusBadGateway, fmt.Errorf("launchd sync failed — schedule not removed: %w", err))
		return
	}
	if err := d.Store.SaveSchedules(kept); err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.afterScheduleMutation(r.Context())
	writeJSON(w, http.StatusOK, map[string]string{"removed": id})
}

// alreadyRegistered reports whether a detected config dir's ACCOUNT is
// already registered. Identity is the email, never the dir.
//
// The dir-match this used to also do was wrong in the swappable model: every
// global-swappable account's ConfigDir IS the global dir, so once ANY account
// was registered the global dir always reported registered — and a NEW
// account signed into ~/.claude could never be adopted from either GUI
// (handleAdopt 409'd), while `llmpilot init` adopted it fine. The daemon's
// own "logged in but not registered" event then told the user to run a
// terminal command BECAUSE the GUI could not do it.
func alreadyRegistered(det detect.Detected, existing []store.Account) bool {
	for _, a := range existing {
		if a.Email != "" {
			if strings.EqualFold(a.Email, det.Account.EmailAddress) {
				return true
			}
			continue
		}
		// A row with NO email carries no identity to compare, so the dir is
		// the only thing that can link it to this account. Adopting over it
		// would fork a second registry row for one account.
		if a.ConfigDir != "" && a.ConfigDir == det.Dir.Path() {
			return true
		}
	}
	return false
}

func (d *Daemon) handleDetect(w http.ResponseWriter, r *http.Request) {
	if d.Detect == nil {
		httpError(w, http.StatusNotImplemented, errors.New("detect not wired"))
		return
	}
	detected, err := d.Detect(r.Context())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	existing, err := d.Store.Accounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// A dir whose sign-in was MOVED into the fleet still carries its
	// oauthAccount block (llmpilot never blanks a foreign dir's identity), so
	// it keeps looking logged in. The retirement record is how we tell the
	// truth about it without reading a Keychain item outside the fleet.
	// `moved` is re-verified against CURRENT state, not read from the record:
	// a folder someone signed back into must stop claiming it was moved, or
	// the cockpit says "already moved into the fleet" and offers nothing to
	// resolve the new sign-in while the clone guard pauses that account's
	// refreshes (Codex review P2).
	moved := map[string]bool{}
	if d.MovedDirs != nil {
		if m, err := d.MovedDirs(r.Context()); err == nil {
			moved = m
		} else {
			d.Log.Warn("revalidate retirements", "err", err)
		}
	} else if rec, err := d.Store.Retirements(); err == nil {
		for _, dir := range rec.Dirs {
			if dir.Complete {
				moved[dir.ConfigDir] = true
			}
		}
	} else {
		d.Log.Warn("read retirements", "err", err)
	}
	type detectedOut struct {
		ConfigDir  string `json:"config_dir"`
		Email      string `json:"email"`
		Registered bool   `json:"registered"`
		Moved      bool   `json:"moved"`
	}
	out := make([]detectedOut, 0, len(detected))
	for _, det := range detected {
		out = append(out, detectedOut{
			ConfigDir:  det.Dir.Path(),
			Email:      det.Account.EmailAddress,
			Registered: alreadyRegistered(det, existing),
			Moved:      moved[det.Dir.Path()],
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (d *Daemon) handleAdopt(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	if d.Detect == nil || d.Adopt == nil {
		httpError(w, http.StatusNotImplemented, errors.New("adopt not wired"))
		return
	}
	var req struct {
		ConfigDir string `json:"config_dir"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ConfigDir == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"config_dir": "<path>"}`))
		return
	}
	detected, err := d.Detect(r.Context())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	var match *detect.Detected
	for i := range detected {
		if detected[i].Dir.Path() == req.ConfigDir {
			match = &detected[i]
			break
		}
	}
	if match == nil {
		httpError(w, http.StatusNotFound, fmt.Errorf("no logged-in account at config dir %q", req.ConfigDir))
		return
	}
	existing, err := d.Store.Accounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	if alreadyRegistered(*match, existing) {
		httpError(w, http.StatusConflict, fmt.Errorf("%q is already registered", req.ConfigDir))
		return
	}
	label := detect.SuggestLabel(*match, existing)
	acct, err := d.Adopt(r.Context(), *match, label)
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.notify(r.Context())
	writeJSON(w, http.StatusCreated, acct)
}

// handleAdoptMove migrates a sign-in out of its own config dir into the
// swappable fleet and RETIRES the source copy.
//
// Auth-guarded, unlike POST /v1/adopt: registration is additive, deletion is
// not. Adopt stays open because it is the shipped first-run funnel and a
// cockpit opened without a token must still be able to run it; this endpoint
// deletes a sign-in from a folder outside the fleet, so it takes the session
// token like every other P2 mutation.
func (d *Daemon) handleAdoptMove(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	if d.Detect == nil || d.MoveIntoFleet == nil {
		httpError(w, http.StatusNotImplemented, errors.New("move not wired"))
		return
	}
	var req struct {
		ConfigDir string `json:"config_dir"`
		Label     string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.ConfigDir == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"config_dir": "<path>", "label": "<optional>"}`))
		return
	}
	if len(req.Label) > 200 {
		httpError(w, http.StatusBadRequest, errors.New("label too long"))
		return
	}
	detected, err := d.Detect(r.Context())
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	var match *detect.Detected
	for i := range detected {
		if detected[i].Dir.Path() == req.ConfigDir {
			match = &detected[i]
			break
		}
	}
	if match == nil {
		httpError(w, http.StatusNotFound, fmt.Errorf("no signed-in Claude account at %q", req.ConfigDir))
		return
	}
	res, err := d.MoveIntoFleet(r.Context(), *match, req.Label)
	if err != nil {
		switch {
		// A refusal is a DECISION the user can act on (the fleet's own folder,
		// nothing signed in there, the identity changed under us, a second
		// live sign-in for this account) — 409, never a 500.
		case errors.Is(err, pilotapi.ErrStashConflict), errors.Is(err, switcher.ErrMoveRefused):
			httpError(w, http.StatusConflict, err)
		case errors.Is(err, switcher.ErrNotFound):
			httpError(w, http.StatusNotFound, err)
		default:
			httpError(w, http.StatusInternalServerError, err)
		}
		return
	}
	msg := fmt.Sprintf("Moved %s into the fleet — llmpilot can switch to it now.", res.Account.Label)
	if res.CloneSuspect {
		msg = res.Note
	}
	if err := d.Store.AppendEvent(store.Event{Kind: "adopt_move", AccountID: res.Account.ID, Message: msg}); err != nil {
		d.Log.Warn("append move event", "err", err)
	}
	d.notify(r.Context())
	outcome := "complete"
	if res.CloneSuspect {
		outcome = "clone_suspect"
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"account": res.Account,
		"outcome": outcome,
		"note":    res.Note,
	})
}

func (d *Daemon) handleConfigGet(w http.ResponseWriter, r *http.Request) {
	cfg, err := d.Store.Config()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// Defaults applied VISIBLY: a client reading this response never needs
	// to know DefaultNotificationThresholds exists.
	cfg.Notifications.Thresholds = cfg.Notifications.EffectiveThresholds()
	writeJSON(w, http.StatusOK, cfg)
}

func (d *Daemon) handleConfigPut(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var cfg store.Config
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	if err := d.Store.SaveConfig(cfg); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	d.notify(r.Context())
	cfg.Notifications.Thresholds = cfg.Notifications.EffectiveThresholds()
	writeJSON(w, http.StatusOK, cfg)
}

func (d *Daemon) handleHistory(w http.ResponseWriter, r *http.Request) {
	accountID := r.URL.Query().Get("account_id")
	kind := r.URL.Query().Get("kind")
	if accountID == "" || kind == "" {
		httpError(w, http.StatusBadRequest, errors.New("account_id and kind query params are required"))
		return
	}
	scope := r.URL.Query().Get("scope")
	samples := d.History(accountID, kind, scope)
	if samples == nil {
		samples = []HistorySample{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"samples": samples})
}

// handleAnalytics walks every registered account's local transcripts. See
// analytics.Scan's doc comment for the perf/locking notes (no daemon-global
// lock is held across this — a slow first (cold-cache) call degrades only
// this one request).
//
// Attribution: an account with its own ConfigDir gets its own walk, tagged
// with that account's ID. Account(s) with an empty ConfigDir share the
// machine-global config dir (~/.claude) — walking it once (not once per such
// account) and tagging those cells account_id:"" ("shared" in the UI) is the
// only correct attribution, since which of possibly several accounts drove
// any given historical session in the shared dir is not recoverable from
// local state alone.
func (d *Daemon) handleAnalytics(w http.ResponseWriter, r *http.Request) {
	days := 30
	if v := r.URL.Query().Get("days"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			httpError(w, http.StatusBadRequest, errors.New("days must be an integer"))
			return
		}
		days = n
	}
	switch {
	case days < 1:
		days = 1
	case days > 730:
		days = 730
	}

	accs, err := d.Store.Accounts()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}

	type cellOut struct {
		AccountID string           `json:"account_id"`
		Project   string           `json:"project"`
		Model     string           `json:"model"`
		Day       string           `json:"day"`
		Messages  int64            `json:"messages"`
		Tokens    analytics.Tokens `json:"tokens"`
	}

	cutoff := time.Now().UTC().AddDate(0, 0, -days).Format("2006-01-02")
	cells := []cellOut{}
	var hourWeekday [7][24]int64
	filesTotal, filesParsed, filesReused := 0, 0, 0
	sharedWalked := false

	for _, a := range accs {
		configDir, accountID, cacheID := a.ConfigDir, a.ID, a.ID
		if configDir == "" {
			if sharedWalked {
				continue
			}
			sharedWalked = true
			dir, gerr := claudecfg.GlobalDir()
			if gerr != nil {
				d.Log.Warn("analytics: resolve global dir", "err", gerr)
				continue
			}
			configDir, accountID, cacheID = dir.Path(), "", "shared"
		}
		cachePath, perr := d.Store.AnalyticsCachePath(cacheID)
		if perr != nil {
			d.Log.Warn("analytics: cache path", "account", a.ID, "err", perr)
			continue
		}
		agg, serr := analytics.Scan(configDir, cachePath)
		if serr != nil {
			d.Log.Warn("analytics: scan", "account", a.ID, "err", serr)
			continue
		}
		filesTotal += agg.FilesTotal
		filesParsed += agg.FilesParsed
		filesReused += agg.FilesReused
		for _, c := range agg.Cells {
			if c.Day != "unknown" && c.Day < cutoff {
				continue
			}
			cells = append(cells, cellOut{
				AccountID: accountID, Project: c.Project, Model: c.Model, Day: c.Day,
				Messages: c.Messages, Tokens: c.Tokens,
			})
		}
		for day, grid := range agg.DailyHourWeekday {
			if day < cutoff {
				continue
			}
			for wd := range grid {
				for hr := range grid[wd] {
					hourWeekday[wd][hr] += grid[wd][hr]
				}
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"cells":        cells,
		"hour_weekday": hourWeekday,
		"files_total":  filesTotal,
		"files_parsed": filesParsed,
		"files_reused": filesReused,
		"as_of":        time.Now().UTC(),
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, code int, err error) {
	writeJSON(w, code, map[string]string{"error": err.Error()})
}

// httpWorkerError forwards a worker refusal with its machine code intact
// (same HTTP status, human copy in "error", worker code in "code") so the
// cockpit can render specific copy; a non-typed failure stays a plain 502.
func httpWorkerError(w http.ResponseWriter, err error, human string) {
	var refusal *WorkerError
	if errors.As(err, &refusal) && refusal.Terminal() && refusal.Code != "" {
		writeJSON(w, refusal.HTTPStatus, map[string]string{"error": human, "code": refusal.Code})
		return
	}
	httpError(w, http.StatusBadGateway, errors.New(human))
}

// Serve listens on the unix socket (0600) and 127.0.0.1 (port persisted to
// daemon.port), serves the API on both, and runs the poll/refresh loops
// until ctx is done. It cleans up the socket and port file on exit.
func (d *Daemon) Serve(ctx context.Context) error {
	d.init()
	home := d.Store.Home()
	if err := os.MkdirAll(home, 0o700); err != nil {
		return err
	}

	// Single-instance interlock: an exclusive advisory flock acquired BEFORE
	// any socket work and held for the daemon's lifetime (the kernel releases
	// it on death, so there is no staleness window). Only the lock holder may
	// remove a stale socket and bind — a check-then-act probe alone is TOCTOU
	// and two racing cold starts would both steal the socket and both write
	// credentials, the #1 hazard class.
	lock, err := os.OpenFile(LockFilePath(home), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	if flockErr := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); flockErr != nil {
		_ = lock.Close()
		if errors.Is(flockErr, syscall.EWOULDBLOCK) {
			return ErrAlreadyRunning
		}
		// Any other errno is an environment failure, not a duplicate — a
		// non-zero exit lets launchd's KeepAlive retry it.
		return fmt.Errorf("single-instance lock: %w", flockErr)
	}
	defer func() { _ = lock.Close() }() // close drops the flock

	sock := SocketPath(home)
	_ = os.Remove(sock) // stale socket from a dead daemon; we hold the lock
	ul, err := net.Listen("unix", sock)
	if err != nil {
		return fmt.Errorf("unix socket: %w", err)
	}
	defer func() { _ = os.Remove(sock) }()
	if err := os.Chmod(sock, 0o600); err != nil {
		return err
	}

	// The token file lands BEFORE the port file: clients treat the port file
	// as the readiness signal, so the token must already be readable then.
	if d.authToken == "" {
		return errors.New("auth token missing — refusing to serve license routes unauthenticated")
	}
	tokenFile := TokenFilePath(home)
	if err := os.WriteFile(tokenFile, []byte(d.authToken+"\n"), 0o600); err != nil {
		return err
	}
	defer func() { _ = os.Remove(tokenFile) }()

	tl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("loopback listener: %w", err)
	}
	port := tl.Addr().(*net.TCPAddr).Port
	portFile := PortFilePath(home)
	if err := os.WriteFile(portFile, []byte(strconv.Itoa(port)+"\n"), 0o600); err != nil {
		return err
	}
	defer func() { _ = os.Remove(portFile) }()
	d.Log.Info("daemon listening", "socket", sock, "addr", tl.Addr().String())

	srv := &http.Server{Handler: d.Handler(), ReadHeaderTimeout: 10 * time.Second}
	errc := make(chan error, 2)
	go func() { errc <- srv.Serve(ul) }()
	go func() { errc <- srv.Serve(tl) }()

	// Baseline the stash BEFORE the sweep so entries the sweep migrates are
	// surfaced as events while pre-existing ones stay quiet across restarts.
	d.baselineStash(ctx)
	if d.StartupSweep != nil {
		go func() {
			if err := d.StartupSweep(ctx); err != nil {
				d.Log.Warn("legacy backup sweep failed — will retry next start", "err", err)
				return
			}
			d.noteNewStashEntries(ctx)
			d.notify(ctx)
		}()
	}

	runErr := d.Run(ctx) // blocks until ctx done
	shutCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
	// Both Serve goroutines return after Shutdown; drain both so a real
	// listener error is never silently dropped.
	for range 2 {
		if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	}
	if errors.Is(runErr, context.Canceled) {
		return nil
	}
	return runErr
}
