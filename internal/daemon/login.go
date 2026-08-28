package daemon

// In-app sign-in endpoints. The daemon owns the whole OAuth attempt: the PKCE
// code_verifier never leaves this process, and the daemon's state table is the
// CSRF check — an unknown, expired, or already-used state fails closed with no
// exchange and no write. Three flows share that machinery:
//
//   - /v1/login/start + /v1/login/complete — HOSTED-callback flow. The client
//     opens the authorize URL (in-app webview or browser), grabs code+state
//     from the intercepted callback URL or the pasted "<code>#<state>", and
//     posts them back to /complete.
//   - /v1/login/browser — ZERO-PASTE browser flow. The daemon starts an
//     ephemeral loopback listener, hands the client an authorize URL whose
//     redirect is that listener, and completes the exchange+install itself
//     when the browser redirects back. No paste, no code copying; the client
//     just opens the URL and watches the fleet for the new account.
//
// The JSON routes require the install token (auth.go). The loopback /callback
// is unauthenticated by necessity (a browser redirect carries no token) but is
// bound to 127.0.0.1, single-use, and gated by the 256-bit CSRF state that
// only ever rode the authorize URL — the RFC 8252 loopback model.

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// LoginMintFn mints one attempt's PKCE + CSRF state; the verifier never leaves
// the daemon. nil = login not wired.
type LoginMintFn func() (state, verifier, challenge string, err error)

// LoginURLFn builds the authorize URL for (challenge, state) against
// redirectURI. An empty redirectURI means the hosted callback (webview /
// browser+paste); a loopback URI is the zero-paste browser flow.
type LoginURLFn func(challenge, state, redirectURI string) (string, error)

// LoginCompleteFn exchanges the code and installs the credential (exchange →
// identity fetch → lock-first install + registration). redirectURI MUST match
// the one the authorize URL used (empty = hosted). Exactly one exchange POST;
// a timed-out exchange is surfaced, never retried in-pass (the rotation
// hazard).
type LoginCompleteFn func(ctx context.Context, code, state, verifier, redirectURI string) (store.Account, error)

// loginAttemptTTL bounds how long a started sign-in stays completable;
// authorization codes are short-lived anyway.
const loginAttemptTTL = 10 * time.Minute

// loginAttemptCap bounds the pending table; the oldest attempt is evicted over
// the cap. Sixteen concurrent sign-ins on one machine is already absurd.
const loginAttemptCap = 16

type loginAttempt struct {
	verifier    string
	redirectURI string // "" = hosted callback; else the loopback URI
	started     time.Time
	cancel      context.CancelFunc // browser flow: stops the listener on eviction/expiry; nil otherwise
}

// loginResult is one browser-flow attempt's outcome, served by
// GET /v1/login/browser/status so the client ties completion to ITS attempt
// (fleet-size inference never completes on a re-login and false-positives on
// a concurrent add). Never carries a code, token, or verifier.
type loginResult struct {
	status    string // "pending" | "done" | "failed"
	errText   string // sanitized human copy on failed, "" otherwise
	code      string // machine-readable failure class ("rate_limited" or ""); clients match THIS, never the prose
	accountID string // set on done
	at        time.Time
}

// LoginCodeRateLimited is the stable failure code for a rate-limited code
// exchange (ErrSignInRateLimited). The status endpoint serves it so the
// sign-in sheet can key its explicit Try-again state off a constant instead
// of the human sentence (copy changes must not silently break clients).
const LoginCodeRateLimited = "rate_limited"

// loginFailureCode classifies a terminal login failure for the wire.
func loginFailureCode(err error) string {
	if errors.Is(err, ErrSignInRateLimited) {
		return LoginCodeRateLimited
	}
	return ""
}

// setLoginResult records an attempt's outcome. A terminal outcome (done or
// failed) never regresses to pending or gets overwritten by a later failure —
// the TTL cleanup races the success path and must not repaint it.
func (d *Daemon) setLoginResult(id, status, errText, accountID string) {
	d.setLoginResultCoded(id, status, errText, "", accountID)
}

// setLoginResultCoded is setLoginResult with a machine-readable failure
// class (loginFailureCode) riding along for the status endpoint.
func (d *Daemon) setLoginResultCoded(id, status, errText, code, accountID string) {
	d.loginMu.Lock()
	defer d.loginMu.Unlock()
	if cur, ok := d.loginResults[id]; ok && cur.status != "pending" {
		return
	}
	d.loginResults[id] = loginResult{status: status, errText: errText, code: code, accountID: accountID, at: d.now()}
}

// pruneLoginResultsLocked drops results older than the attempt TTL (a client
// that hasn't polled in 10 minutes abandoned the dialog). Caller holds loginMu.
func (d *Daemon) pruneLoginResultsLocked(now time.Time) {
	for id, r := range d.loginResults {
		if now.Sub(r.at) > loginAttemptTTL {
			delete(d.loginResults, id)
		}
	}
}

var (
	errLoginNotWired   = errors.New("in-app sign-in not wired")
	errUnknownAttempt  = errors.New("this sign-in attempt is unknown, expired, or already used — start the sign-in again")
	errLoginBadRequest = errors.New(`body must be {"code": "<code>", "state": "<state>"}`)
)

func (d *Daemon) loginWired() bool {
	return d.LoginMint != nil && d.LoginURL != nil && d.LoginComplete != nil
}

// recordAttempt stores a started attempt, evicting expired entries and, over
// the cap, the oldest.
func (d *Daemon) recordAttempt(state string, att loginAttempt) {
	now := d.now()
	d.loginMu.Lock()
	defer d.loginMu.Unlock()
	for s, a := range d.loginAttempts {
		if now.Sub(a.started) > loginAttemptTTL {
			d.dropAttemptLocked(s, a)
		}
	}
	for len(d.loginAttempts) >= loginAttemptCap {
		// Seed from the first ranged key so a real key is always chosen — a
		// now-seeded comparison would leave oldest=="" under a backward clock
		// jump with a full table, making delete a no-op and this loop spin.
		oldest := ""
		var oldestAt time.Time
		for s, a := range d.loginAttempts {
			if oldest == "" || a.started.Before(oldestAt) {
				oldest, oldestAt = s, a.started
			}
		}
		d.dropAttemptLocked(oldest, d.loginAttempts[oldest])
	}
	d.loginAttempts[state] = att
}

// dropAttemptLocked removes an attempt and, for a browser flow, stops its
// loopback listener (so an evicted/expired attempt can't strand a live port +
// goroutine). Caller holds loginMu. cancel is idempotent, so a later consume/
// TTL that also cancels is safe.
func (d *Daemon) dropAttemptLocked(state string, att loginAttempt) {
	delete(d.loginAttempts, state)
	if att.cancel != nil {
		att.cancel()
	}
}

// consumeAttempt removes and returns the attempt for state (single-use). ok is
// false when unknown or expired — so a replayed callback can never re-exchange.
func (d *Daemon) consumeAttempt(state string) (loginAttempt, bool) {
	d.loginMu.Lock()
	att, ok := d.loginAttempts[state]
	delete(d.loginAttempts, state)
	d.loginMu.Unlock()
	if !ok || d.now().Sub(att.started) > loginAttemptTTL {
		return loginAttempt{}, false
	}
	return att, true
}

// finishLogin consumes the attempt for state (single-use, fail-closed) and
// runs the one-shot exchange+install. Shared by the paste handler and the
// loopback callback so both get identical CSRF + rotation guarantees.
func (d *Daemon) finishLogin(ctx context.Context, code, state string) (store.Account, error) {
	att, ok := d.consumeAttempt(state)
	if !ok {
		return store.Account{}, errUnknownAttempt
	}
	return d.LoginComplete(ctx, code, state, att.verifier, att.redirectURI)
}

func (d *Daemon) handleLoginStart(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !d.loginWired() {
		httpError(w, http.StatusNotImplemented, errLoginNotWired)
		return
	}
	if !requireJSON(w, r) {
		return
	}
	state, verifier, challenge, err := d.LoginMint()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	authURL, err := d.LoginURL(challenge, state, "") // "" = hosted callback
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	d.recordAttempt(state, loginAttempt{verifier: verifier, started: d.now()})
	writeJSON(w, http.StatusOK, map[string]string{"authorize_url": authURL, "state": state})
}

func (d *Daemon) handleLoginComplete(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !d.loginWired() {
		httpError(w, http.StatusNotImplemented, errLoginNotWired)
		return
	}
	if !requireJSON(w, r) {
		return
	}
	var req struct {
		Code  string `json:"code"`
		State string `json:"state"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Code == "" || req.State == "" {
		httpError(w, http.StatusBadRequest, errLoginBadRequest)
		return
	}
	acct, err := d.finishLogin(r.Context(), req.Code, req.State)
	if errors.Is(err, errUnknownAttempt) {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	if err != nil {
		httpError(w, http.StatusBadGateway, err)
		return
	}
	d.notify(r.Context())
	writeJSON(w, http.StatusCreated, acct)
}

// handleLoginBrowser begins the zero-paste browser flow. It returns only the
// authorize URL — no state to the client, because the daemon's own loopback
// listener is the one that catches the callback.
func (d *Daemon) handleLoginBrowser(w http.ResponseWriter, r *http.Request) {
	if !d.requireAuth(w, r) {
		return
	}
	if !d.loginWired() {
		httpError(w, http.StatusNotImplemented, errLoginNotWired)
		return
	}
	if !requireJSON(w, r) {
		return
	}
	state, verifier, challenge, err := d.LoginMint()
	if err != nil {
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// Ephemeral loopback listener: localhost-only, one sign-in, then closed.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		httpError(w, http.StatusInternalServerError, fmt.Errorf("loopback listener: %w", err))
		return
	}
	port := ln.Addr().(*net.TCPAddr).Port
	redirectURI := fmt.Sprintf("http://localhost:%d/callback", port)
	authURL, err := d.LoginURL(challenge, state, redirectURI)
	if err != nil {
		_ = ln.Close()
		httpError(w, http.StatusInternalServerError, err)
		return
	}
	// The listener's lifetime is the attempt's: the TTL bounds an abandoned
	// sign-in, and eviction (dropAttemptLocked) cancels it early.
	ctx, cancel := context.WithTimeout(context.Background(), loginAttemptTTL)
	d.recordAttempt(state, loginAttempt{verifier: verifier, redirectURI: redirectURI, started: d.now(), cancel: cancel})
	d.loginMu.Lock()
	d.pruneLoginResultsLocked(d.now())
	d.loginResults[state] = loginResult{status: "pending", at: d.now()}
	d.loginMu.Unlock()
	go d.serveLoginCallback(ctx, cancel, ln, state)
	// attempt_id is the CSRF state — already visible to this authenticated
	// caller inside authorize_url, so this exposes nothing new.
	writeJSON(w, http.StatusOK, map[string]string{"authorize_url": authURL, "attempt_id": state})
}

// handleLoginBrowserStatus reports one browser-flow attempt's outcome so the
// client completes on ITS attempt, not on fleet-size inference.
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
	d.loginMu.Unlock()
	if !ok {
		httpError(w, http.StatusNotFound, errUnknownAttempt)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status": res.status, "error": res.errText, "code": res.code, "account_id": res.accountID,
	})
}

// serveLoginCallback runs the ephemeral loopback server for one browser sign-
// in. It stays up — despite stray probes of its localhost port — until OUR
// redirect (a state-matched request) is handled, or the attempt is evicted /
// times out (ctx). A request whose state does NOT match is a foreign hit
// (port scanner, browser prefetch, a hostile local process): it gets a
// neutral page and the listener KEEPS SERVING, so it cannot DoS the sign-in.
func (d *Daemon) serveLoginCallback(ctx context.Context, cancel context.CancelFunc, ln net.Listener, state string) {
	defer cancel() // release the TTL timer once we exit
	handled := make(chan struct{})
	var once sync.Once

	mux := http.NewServeMux()
	mux.HandleFunc("/callback", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		// Constant-time state check FIRST: only our own redirect may end the
		// listener, and comparing in constant time keeps the 256-bit state off
		// any timing oracle now that a bad hit no longer tears the server down.
		if subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(state)) != 1 {
			loginCallbackPage(w, false, "This sign-in link is invalid or has expired. You can close this tab.")
			return
		}
		// This is our callback — tear the listener down once the handler returns.
		defer once.Do(func() { close(handled) })
		if e := q.Get("error"); e != "" {
			d.setLoginResult(state, "failed", "Claude declined the sign-in — try again", "")
			loginCallbackPage(w, false, "Claude declined the sign-in. You can close this tab and try again in llmpilot.")
			return
		}
		code := q.Get("code")
		if code == "" {
			d.setLoginResult(state, "failed", "the sign-in came back without a code — try again", "")
			loginCallbackPage(w, false, "The sign-in came back without a code. You can close this tab and try again.")
			return
		}
		ectx, ecancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer ecancel()
		acct, err := d.finishLogin(ectx, code, state)
		if err != nil {
			// Login errors never carry secrets (sanitized OAuth code + HTTP
			// status only), so surface the reason — a 429 is a transient rate
			// limit worth retrying, not a broken flow.
			d.Log.Warn("browser login: exchange/install failed", "err", err)
			d.setLoginResultCoded(state, "failed", err.Error(), loginFailureCode(err), "")
			// The tab is a dead end after this — say what happened, what to
			// do next in ONE place (the app), and that the tab can go
			// (fresh-user audit 2026-08-16, F8).
			if errors.Is(err, ErrSignInRateLimited) {
				loginCallbackPage(w, false, "The sign-in server is rate-limited right now. Wait a minute, then press Try again in llmpilot — that starts a fresh sign-in; this tab's code is used and won't work again. You can close this tab.")
			} else {
				loginCallbackPage(w, false, "Sign-in couldn't be completed: "+err.Error()+". Try again from llmpilot. You can close this tab.")
			}
			return
		}
		d.setLoginResult(state, "done", "", acct.ID)
		loginCallbackPage(w, true, "You're signed in. You can close this tab — llmpilot is adding your account.")
		d.notify(context.Background())
	})

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	select {
	case <-handled:
	case <-ctx.Done(): // TTL fired or the attempt was evicted
	}
	// Clean up a still-pending attempt (the TTL/evict path; a completed sign-in
	// already consumed it under the lock — delete is idempotent). A result
	// still pending here means the sign-in never finished: say so honestly
	// (setLoginResult never repaints a terminal outcome).
	d.setLoginResult(state, "failed", "the sign-in timed out — try again", "")
	d.loginMu.Lock()
	delete(d.loginAttempts, state)
	d.loginMu.Unlock()
	shutCtx, shutCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer shutCancel()
	_ = srv.Shutdown(shutCtx)
}

// ErrSignInRateLimited is the token endpoint rate-limiting the code
// exchange (HTTP 429): transient, not a bad code — but the code from THIS
// attempt was consumed by the failed exchange, so the retry is a fresh
// sign-in, never a replay (P2 copy fix, wave S12). The daemon's login
// wiring returns it so the browser page and the login result can say so
// instead of a raw status. The text is what the sign-in sheet shows
// verbatim — keep it a plain sentence.
var ErrSignInRateLimited = errors.New("the sign-in server is rate-limited right now — wait a minute, then start a fresh sign-in; this attempt's code is used and won't work again")

// loginCallbackPage renders the minimal page the browser lands on after the
// redirect. It carries no code or token — only a human status line.
func loginCallbackPage(w http.ResponseWriter, ok bool, message string) {
	// Headers must be set BEFORE WriteHeader commits them.
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	title := "Signed in"
	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		title = "Sign-in problem"
	}
	fmt.Fprintf(w, `<!doctype html><html><head><meta charset="utf-8"><title>%s</title>`+
		`<style>body{font:15px -apple-system,system-ui,sans-serif;background:#0b0b0b;color:#e8e8e8;`+
		`display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}`+
		`div{max-width:420px;text-align:center;padding:24px}h1{font-size:17px;margin:0 0 8px}`+
		`p{color:#9a9a9a;line-height:1.5}</style></head><body><div><h1>%s</h1><p>%s</p></div></body></html>`,
		html.EscapeString(title), html.EscapeString(title), html.EscapeString(message))
}
