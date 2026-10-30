package daemon

// In-app sign-in, run by Claude Code itself. llmpilot never handles a
// password, an authorization code exchange or a sign-in page of its own:
// the daemon starts `claude auth login` in a private staging folder (see
// internal/signin), Claude Code opens the browser and finishes the sign-in
// the way it always does, and the daemon files the result into the fleet.
//
//	POST /v1/login/browser          {"email"?}            → {"attempt_id"}
//	GET  /v1/login/browser/status   ?attempt=<id>          → status, outcome, manual_url
//	POST /v1/login/browser/code     {"attempt_id","code"}  → hands a pasted code to Claude Code
//	POST /v1/login/browser/cancel   {"attempt_id"}         → stops the sign-in
//
// One sign-in runs at a time: starting another stops the first. Every route
// requires the install token (auth.go).

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// SignInAttempt is one running Claude Code sign-in (internal/signin).
type SignInAttempt interface {
	// ManualURL is the sign-in link for a browser that didn't open; "" until
	// Claude Code prints it.
	ManualURL() string
	// SubmitCode hands Claude Code the code the sign-in page showed.
	SubmitCode(code string) error
	// Done is closed when the sign-in process exits.
	Done() <-chan struct{}
	// Finish files a finished sign-in into the fleet; call after Done. The
	// staging copy is removed whatever the outcome.
	Finish(ctx context.Context) (switcher.ImportResult, error)
	// Abort stops the sign-in and removes the staging copy. Idempotent.
	Abort()
}

// SignInStartFn starts Claude Code's sign-in; email pre-fills the page.
type SignInStartFn func(ctx context.Context, email string) (SignInAttempt, error)

// loginAttemptTTL bounds one sign-in: a browser left open longer than this
// is an abandoned attempt, and its process is stopped.
var loginAttemptTTL = 10 * time.Minute

// Failure codes on the wire. Clients key behavior off these, never the prose.
const (
	LoginCodeClaudeMissing = "claude_missing" // Claude Code isn't installed
	LoginCodeTimedOut      = "timed_out"
	LoginCodeCancelled     = "cancelled"
	LoginCodeReplaced      = "replaced" // a newer sign-in took over
)

// loginResult is one attempt's outcome for the status route. Never carries
// a code or a token.
type loginResult struct {
	status    string // "pending" | "done" | "failed"
	errText   string
	code      string
	accountID string
	email     string
	outcome   string // switcher.ImportOutcome on done
	existing  bool   // the fleet already had this account before the sign-in
	note      string // one more thing the user needs to know, "" when nothing
	at        time.Time
}

// signInRun is the one live attempt.
type signInRun struct {
	id   string
	att  SignInAttempt
	stop chan string // receives the failure code that ends the attempt
}

var errUnknownAttempt = errors.New("this sign-in is unknown or already finished — start it again")

func newAttemptID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// setLoginResult records an attempt's outcome. A finished outcome is never
// overwritten — the timeout and cancel paths race the success path.
func (d *Daemon) setLoginResult(id string, r loginResult) {
	d.loginMu.Lock()
	defer d.loginMu.Unlock()
	if cur, ok := d.loginResults[id]; ok && cur.status != "pending" {
		return
	}
	r.at = d.now()
	d.loginResults[id] = r
}

// pruneLoginResultsLocked drops results nobody has asked about for a whole
// attempt lifetime. Caller holds loginMu.
func (d *Daemon) pruneLoginResultsLocked(now time.Time) {
	for id, r := range d.loginResults {
		if r.status != "pending" && now.Sub(r.at) > loginAttemptTTL {
			delete(d.loginResults, id)
		}
	}
}

// validSignInEmail accepts a plain address to pre-fill — it becomes an
// argument to Claude Code, so nothing that could read as a flag or carry
// more than one address gets through.
func validSignInEmail(e string) bool {
	if e == "" {
		return true
	}
	if len(e) > 254 || strings.HasPrefix(e, "-") || strings.ContainsAny(e, " \t\r\n<>,;\"") {
		return false
	}
	a, err := mail.ParseAddress(e)
	return err == nil && a.Address == e
}

func (d *Daemon) handleLoginBrowser(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if d.SignIn == nil {
		httpError(w, http.StatusNotImplemented, errors.New("in-app sign-in not wired"))
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {} or {"email": "<address>"}`))
		return
	}
	req.Email = strings.TrimSpace(req.Email)
	if !validSignInEmail(req.Email) {
		httpError(w, http.StatusBadRequest, errors.New("that email address can't be used to start a sign-in"))
		return
	}
	id, err := newAttemptID()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// Finding Claude Code can take a moment the first time; a client that
	// hangs up must not leave a half-started process behind.
	att, err := d.SignIn(context.WithoutCancel(r.Context()), req.Email)
	if err != nil {
		if errors.Is(err, claudecfg.ErrCLINotFound) {
			writeJSON(w, http.StatusConflict, map[string]string{
				"error": "llmpilot signs you in through Claude Code, and Claude Code isn't installed on this Mac. Install it, then try again.",
				"code":  LoginCodeClaudeMissing,
			})
			return
		}
		d.Log.Warn("sign-in: could not start Claude Code", "err", err)
		httpError(w, http.StatusInternalServerError, errors.New("the Claude Code sign-in couldn't start — try again"))
		return
	}
	run := &signInRun{id: id, att: att, stop: make(chan string, 1)}
	d.loginMu.Lock()
	if d.loginClosing {
		// The daemon began shutting down while Claude Code was starting.
		d.loginMu.Unlock()
		att.Abort()
		httpError(w, http.StatusServiceUnavailable, errors.New("llmpilot is restarting — try again in a moment"))
		return
	}
	d.pruneLoginResultsLocked(d.now())
	prev := d.loginRun
	d.loginRun = run
	// Counted while the lock still excludes stopSignIn, so shutdown waits
	// for this supervisor — and for a replaced one still importing.
	d.loginWG.Add(1)
	d.loginResults[id] = loginResult{status: "pending", at: d.now()}
	d.loginMu.Unlock()
	if prev != nil {
		prev.end(LoginCodeReplaced)
	}
	go d.superviseSignIn(run)
	writeJSON(w, http.StatusOK, map[string]string{"attempt_id": id})
}

// end asks the supervisor to stop this attempt (first reason wins).
func (r *signInRun) end(code string) {
	select {
	case r.stop <- code:
	default:
	}
}

var failureText = map[string]string{
	LoginCodeTimedOut:  "the sign-in timed out — start it again",
	LoginCodeCancelled: "sign-in cancelled",
	LoginCodeReplaced:  "a newer sign-in took over",
}

// superviseSignIn owns one attempt from start to cleanup.
func (d *Daemon) superviseSignIn(run *signInRun) {
	defer d.loginWG.Done()
	timer := time.NewTimer(loginAttemptTTL)
	defer timer.Stop()
	defer func() {
		d.loginMu.Lock()
		if d.loginRun == run {
			d.loginRun = nil
		}
		d.loginMu.Unlock()
	}()
	select {
	case <-run.att.Done():
	case code := <-run.stop:
		run.att.Abort()
		d.setLoginResult(run.id, loginResult{status: "failed", errText: failureText[code], code: code})
		return
	case <-timer.C:
		run.att.Abort()
		d.setLoginResult(run.id, loginResult{status: "failed", errText: failureText[LoginCodeTimedOut], code: LoginCodeTimedOut})
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	res, err := run.att.Finish(ctx)
	if err != nil {
		d.Log.Warn("sign-in did not finish", "err", err)
		d.setLoginResult(run.id, loginResult{status: "failed", errText: signInFailureText(err)})
		return
	}
	d.freshSignIn(ctx, res.Account.ID)
	d.setLoginResult(run.id, loginResult{
		status: "done", accountID: res.Account.ID, email: res.Account.Email,
		outcome: string(res.Outcome), existing: res.Existed, note: res.Note,
	})
	d.notify(ctx)
}

// signInFailureText is what the sign-in sheet shows: Claude Code's own
// reason when it gave one, the fleet's refusal when filing failed.
func signInFailureText(err error) string {
	if errors.Is(err, switcher.ErrSignInIncomplete) || errors.Is(err, switcher.ErrStashConflict) {
		return err.Error()
	}
	msg := err.Error()
	if strings.HasPrefix(msg, "the Claude Code sign-in") {
		return msg
	}
	return "the sign-in finished, but llmpilot couldn't add the account: " + msg
}

// freshSignIn clears what a dead sign-in left on an account: a fresh grant
// is a new lineage, so the dead-lineage quarantine no longer applies, and
// the account is polled right away instead of on its old schedule.
func (d *Daemon) freshSignIn(ctx context.Context, accountID string) {
	if accountID == "" {
		return
	}
	d.mu.Lock()
	_, wasQuarantined := d.quarantine[accountID]
	delete(d.quarantine, accountID)
	if wasQuarantined && d.tokenNotes[accountID] == deadLineageNote {
		delete(d.tokenNotes, accountID)
	}
	delete(d.nextPoll, accountID)
	d.mu.Unlock()
	if wasQuarantined {
		d.persistQuarantine()
	}
}

// handleLoginBrowserStatus reports one attempt's progress and outcome.
func (d *Daemon) handleLoginBrowserStatus(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	id := r.URL.Query().Get("attempt")
	if id == "" {
		httpError(w, http.StatusBadRequest, errors.New("attempt query parameter required"))
		return
	}
	d.loginMu.Lock()
	res, ok := d.loginResults[id]
	var att SignInAttempt
	if d.loginRun != nil && d.loginRun.id == id {
		att = d.loginRun.att
	}
	d.loginMu.Unlock()
	if !ok {
		httpError(w, http.StatusNotFound, errUnknownAttempt)
		return
	}
	manual := ""
	if att != nil && res.status == "pending" {
		manual = att.ManualURL()
	}
	existing := ""
	if res.existing {
		existing = "true"
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status":     res.status,
		"error":      res.errText,
		"code":       res.code,
		"account_id": res.accountID,
		"email":      res.email,
		"outcome":    res.outcome,
		"existing":   existing,
		"note":       res.note,
		"manual_url": manual,
	})
}

// liveRun returns the running attempt with this id, or nil.
func (d *Daemon) liveRun(id string) *signInRun {
	d.loginMu.Lock()
	defer d.loginMu.Unlock()
	if d.loginRun != nil && d.loginRun.id == id {
		return d.loginRun
	}
	return nil
}

// handleLoginBrowserCode hands a code pasted from the sign-in page to the
// running Claude Code sign-in.
func (d *Daemon) handleLoginBrowserCode(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		AttemptID string `json:"attempt_id"`
		Code      string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AttemptID == "" || req.Code == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"attempt_id": "<id>", "code": "<code>"}`))
		return
	}
	run := d.liveRun(req.AttemptID)
	if run == nil {
		httpError(w, http.StatusNotFound, errUnknownAttempt)
		return
	}
	if err := run.att.SubmitCode(req.Code); err != nil {
		if errors.Is(err, claudecfg.ErrBadCode) {
			httpError(w, http.StatusBadRequest, err)
			return
		}
		httpError(w, http.StatusConflict, err)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"status": "pending"})
}

// handleLoginBrowserCancel stops a running sign-in. Cancelling one that
// already ended is not an error.
func (d *Daemon) handleLoginBrowserCancel(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		AttemptID string `json:"attempt_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.AttemptID == "" {
		httpError(w, http.StatusBadRequest, errors.New(`body must be {"attempt_id": "<id>"}`))
		return
	}
	if run := d.liveRun(req.AttemptID); run != nil {
		run.end(LoginCodeCancelled)
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cancelled"})
}

// stopSignIn ends a running sign-in at daemon shutdown and waits for every
// supervisor still at work — the current attempt's cleanup, and an import
// under way for any attempt, including one a newer sign-in replaced — so no
// Claude Code process, staging copy or half-done credential write outlives
// the daemon. A sign-in that starts after this is refused (loginClosing).
func (d *Daemon) stopSignIn() {
	d.loginMu.Lock()
	d.loginClosing = true
	run := d.loginRun
	d.loginMu.Unlock()
	if run != nil {
		run.end(LoginCodeCancelled)
	}
	finished := make(chan struct{})
	go func() { d.loginWG.Wait(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(3 * time.Minute):
		d.Log.Warn("sign-in: still finishing at shutdown — leaving it to the next start's sweep")
	}
}
