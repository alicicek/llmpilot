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
	"time"

	"github.com/alicicek/llmpilot/internal/analytics"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
)

// SocketPath is the unix socket under one llmpilot home.
func SocketPath(home string) string { return filepath.Join(home, "daemon.sock") }

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
	mux.HandleFunc("GET /v1/detect", d.handleDetect)
	mux.HandleFunc("POST /v1/adopt", d.handleAdopt)
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
	if err := d.Switch(r.Context(), req.AccountID); err != nil {
		httpError(w, http.StatusConflict, err)
		return
	}
	d.notify(r.Context())
	writeJSON(w, http.StatusOK, map[string]string{"switched_to": req.AccountID})
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

// alreadyRegistered reports whether a detected config dir is already
// registered — matched by config dir OR email, since either one identifies
// the same real-world account.
func alreadyRegistered(det detect.Detected, existing []store.Account) bool {
	for _, a := range existing {
		if a.ConfigDir == det.Dir.Path() || a.Email == det.Account.EmailAddress {
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
	type detectedOut struct {
		ConfigDir  string `json:"config_dir"`
		Email      string `json:"email"`
		Registered bool   `json:"registered"`
	}
	out := make([]detectedOut, 0, len(detected))
	for _, det := range detected {
		out = append(out, detectedOut{
			ConfigDir:  det.Dir.Path(),
			Email:      det.Account.EmailAddress,
			Registered: alreadyRegistered(det, existing),
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

	sock := SocketPath(home)
	_ = os.Remove(sock) // stale socket from a dead daemon
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
