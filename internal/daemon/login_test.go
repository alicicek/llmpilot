package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

type loginStub struct {
	completes   atomic.Int32
	failWith    error
	mu          sync.Mutex
	gotCode     string
	gotVerif    string
	gotRedirect string
	lastURLReq  string // redirectURI passed to url()
}

func (s *loginStub) mint() (string, string, string, error) {
	return "st-1", "verif-SECRET", "chal-1", nil
}

func (s *loginStub) url(_ /*challenge*/, state, redirectURI string) (string, error) {
	s.mu.Lock()
	s.lastURLReq = redirectURI
	s.mu.Unlock()
	return "https://claude.com/cai/oauth/authorize?state=" + state, nil
}

func (s *loginStub) complete(_ context.Context, code, _ /*state*/, verifier, redirectURI string) (store.Account, error) {
	s.completes.Add(1)
	s.mu.Lock()
	s.gotCode, s.gotVerif, s.gotRedirect = code, verifier, redirectURI
	s.mu.Unlock()
	if s.failWith != nil {
		return store.Account{}, s.failWith
	}
	return store.Account{ID: "acct-new", Label: "new", Email: "new@example.dev"}, nil
}

func loginDaemon(t *testing.T, stub *loginStub, now *time.Time) *Daemon {
	t.Helper()
	d := &Daemon{Store: store.At(t.TempDir()), NowFn: func() time.Time { return *now }}
	if stub != nil {
		d.LoginMint = stub.mint
		d.LoginURL = stub.url
		d.LoginComplete = stub.complete
	}
	return d
}

func TestLoginStartAndCompleteHappyPath(t *testing.T) {
	stub := &loginStub{}
	now := time.Date(2026, 7, 23, 12, 0, 0, 0, time.UTC)
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/start", `{}`, d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start = %d (%s)", resp.StatusCode, body)
	}
	var start map[string]string
	if err := json.Unmarshal([]byte(body), &start); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(start["authorize_url"], "https://claude.com/cai/oauth/authorize") || start["state"] != "st-1" {
		t.Fatalf("start body = %s", body)
	}
	// The hosted flow passes an empty redirect ("" = hosted) to LoginURL.
	stub.mu.Lock()
	hostedReq := stub.lastURLReq
	stub.mu.Unlock()
	if hostedReq != "" {
		t.Fatalf("start passed redirect %q, want empty (hosted)", hostedReq)
	}
	// The PKCE verifier never leaves the daemon.
	if strings.Contains(body, "verif-SECRET") {
		t.Fatalf("start response leaked the verifier: %s", body)
	}

	resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/login/complete",
		`{"code":"the-code","state":"st-1"}`, d.authToken)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("complete = %d (%s)", resp.StatusCode, body)
	}
	if stub.gotCode != "the-code" || stub.gotVerif != "verif-SECRET" {
		t.Fatalf("complete passed code=%q verifier=%q", stub.gotCode, stub.gotVerif)
	}
	if !strings.Contains(body, "acct-new") {
		t.Fatalf("complete body = %s", body)
	}
}

func TestLoginCompleteUnknownStateFailsClosed(t *testing.T) {
	stub := &loginStub{}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/complete",
		`{"code":"c","state":"forged-state"}`, d.authToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("forged state = %d (%s), want 400", resp.StatusCode, body)
	}
	if stub.completes.Load() != 0 {
		t.Fatal("exchange ran for a forged state")
	}
}

// TestLoginStateIsSingleUse pins the fail-closed replay rule: the state is
// consumed on the FIRST complete — success or failure — so an again-clicked
// code can never trigger a second exchange.
func TestLoginStateIsSingleUse(t *testing.T) {
	now := time.Now()
	for _, failFirst := range []bool{false, true} {
		stub := &loginStub{}
		if failFirst {
			stub.failWith = errors.New("code exchange returned HTTP 401")
		}
		d := loginDaemon(t, stub, &now)
		srv := httptest.NewServer(d.Handler())

		if resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/start", `{}`, d.authToken); resp.StatusCode != http.StatusOK {
			t.Fatalf("start = %d (%s)", resp.StatusCode, body)
		}
		resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/complete",
			`{"code":"c","state":"st-1"}`, d.authToken)
		wantFirst := http.StatusCreated
		if failFirst {
			wantFirst = http.StatusBadGateway
		}
		if resp.StatusCode != wantFirst {
			t.Fatalf("first complete (failFirst=%v) = %d (%s)", failFirst, resp.StatusCode, body)
		}
		resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/login/complete",
			`{"code":"c","state":"st-1"}`, d.authToken)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("replayed complete (failFirst=%v) = %d (%s), want 400", failFirst, resp.StatusCode, body)
		}
		if got := stub.completes.Load(); got != 1 {
			t.Fatalf("exchange ran %d times (failFirst=%v), want exactly 1", got, failFirst)
		}
		srv.Close()
	}
}

func TestLoginAttemptExpires(t *testing.T) {
	stub := &loginStub{}
	now := time.Date(2026, 7, 23, 12, 0, 0, 0, time.UTC)
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/start", `{}`, d.authToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("start = %d (%s)", resp.StatusCode, body)
	}
	now = now.Add(loginAttemptTTL + time.Minute)
	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/complete",
		`{"code":"c","state":"st-1"}`, d.authToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expired complete = %d (%s), want 400", resp.StatusCode, body)
	}
	if stub.completes.Load() != 0 {
		t.Fatal("exchange ran for an expired attempt")
	}
}

// TestLoginBrowserLoopbackCompletes drives the zero-paste flow end to end: the
// daemon stands up a loopback listener, and a GET to /callback (as the browser
// redirect would do) runs the one-shot exchange+install with the loopback
// redirect — no paste, no code in the response, no state/verifier leaked.
func TestLoginBrowserLoopbackCompletes(t *testing.T) {
	stub := &loginStub{}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("browser start = %d (%s)", resp.StatusCode, body)
	}
	// The authorize URL and the attempt id come back — never the verifier.
	// attempt_id is the CSRF state, which already rides inside authorize_url
	// to this same authenticated caller, so it exposes nothing new.
	var br map[string]string
	if err := json.Unmarshal([]byte(body), &br); err != nil {
		t.Fatal(err)
	}
	if br["attempt_id"] == "" {
		t.Fatalf("browser response missing attempt_id: %s", body)
	}
	if strings.Contains(body, "verif-SECRET") {
		t.Fatalf("browser response leaked the verifier: %s", body)
	}
	// Status is tied to THIS attempt: pending before the callback…
	if resp, sb := doAuthed(t, http.MethodGet, srv.URL+"/v1/login/browser/status?attempt="+br["attempt_id"], "", d.authToken); resp.StatusCode != http.StatusOK || !strings.Contains(sb, `"pending"`) {
		t.Fatalf("pre-callback status = %d (%s), want 200 pending", resp.StatusCode, sb)
	}
	stub.mu.Lock()
	redirect := stub.lastURLReq
	stub.mu.Unlock()
	if !strings.HasPrefix(redirect, "http://localhost:") || !strings.HasSuffix(redirect, "/callback") {
		t.Fatalf("loopback redirect = %q", redirect)
	}
	u, err := url.Parse(redirect)
	if err != nil {
		t.Fatal(err)
	}
	cbResp, err := http.Get("http://127.0.0.1:" + u.Port() + "/callback?code=the-code&state=st-1")
	if err != nil {
		t.Fatal(err)
	}
	cbBody, _ := io.ReadAll(cbResp.Body)
	_ = cbResp.Body.Close()
	if cbResp.StatusCode != http.StatusOK {
		t.Fatalf("callback = %d (%s)", cbResp.StatusCode, cbBody)
	}
	if strings.Contains(string(cbBody), "the-code") {
		t.Fatalf("callback page leaked the code")
	}
	if stub.completes.Load() != 1 || stub.gotCode != "the-code" {
		t.Fatalf("exchange ran %d times, code=%q", stub.completes.Load(), stub.gotCode)
	}
	stub.mu.Lock()
	gotRedirect := stub.gotRedirect
	stub.mu.Unlock()
	if gotRedirect != redirect {
		t.Fatalf("exchange redirect = %q, want the loopback %q", gotRedirect, redirect)
	}
	// …and done (with the account) after it — the completion signal the
	// dialog polls, so a re-login to an EXISTING account still completes.
	if resp, sb := doAuthed(t, http.MethodGet, srv.URL+"/v1/login/browser/status?attempt="+br["attempt_id"], "", d.authToken); resp.StatusCode != http.StatusOK || !strings.Contains(sb, `"done"`) || !strings.Contains(sb, "acct-new") {
		t.Fatalf("post-callback status = %d (%s), want 200 done + account id", resp.StatusCode, sb)
	}
}

// TestLoginBrowserStatusFailedOnExchangeError: an exchange failure surfaces as
// a terminal "failed" status with the sanitized reason — the dialog stops
// polling and shows it instead of timing out blind.
func TestLoginBrowserStatusFailedOnExchangeError(t *testing.T) {
	stub := &loginStub{failWith: ErrSignInRateLimited}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("browser start = %d (%s)", resp.StatusCode, body)
	}
	var br map[string]string
	if err := json.Unmarshal([]byte(body), &br); err != nil {
		t.Fatal(err)
	}
	stub.mu.Lock()
	redirect := stub.lastURLReq
	stub.mu.Unlock()
	u, err := url.Parse(redirect)
	if err != nil {
		t.Fatal(err)
	}
	cbResp, err := http.Get("http://127.0.0.1:" + u.Port() + "/callback?code=the-code&state=st-1")
	if err != nil {
		t.Fatal(err)
	}
	pageBytes, _ := io.ReadAll(cbResp.Body)
	_ = cbResp.Body.Close()
	// F8 (fresh-user audit 2026-08-16): the tab is a dead end after a 429 —
	// it must say what happened, name the retry in the app, and release the
	// tab; the doubled "try again … and try again" copy is gone.
	page := string(pageBytes)
	// ("won't" arrives HTML-escaped, so the pin stops at "work again".)
	for _, want := range []string{"rate-limited", "Try again in llmpilot", "You can close this tab", "fresh sign-in", "work again"} {
		if !strings.Contains(page, want) {
			t.Errorf("429 callback page lacks %q:\n%s", want, page)
		}
	}
	if strings.Contains(page, "Return to llmpilot and try again") {
		t.Errorf("429 callback page still carries the doubled retry copy:\n%s", page)
	}
	if resp, sb := doAuthed(t, http.MethodGet, srv.URL+"/v1/login/browser/status?attempt="+br["attempt_id"], "", d.authToken); resp.StatusCode != http.StatusOK || !strings.Contains(sb, `"failed"`) || !strings.Contains(sb, "rate-limited") || !strings.Contains(sb, `"code":"rate_limited"`) {
		t.Fatalf("failed-exchange status = %d (%s), want 200 failed + reason + code rate_limited", resp.StatusCode, sb)
	}
}

// TestLoginBrowserCallbackPageOtherErrorReleasesTab: a non-429 exchange
// failure keeps its own reason and still tells the user the tab can go.
func TestLoginBrowserCallbackPageOtherErrorReleasesTab(t *testing.T) {
	stub := &loginStub{failWith: errors.New("the sign-in came back with a code the server rejected")}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("browser start = %d (%s)", resp.StatusCode, body)
	}
	stub.mu.Lock()
	redirect := stub.lastURLReq
	stub.mu.Unlock()
	u, err := url.Parse(redirect)
	if err != nil {
		t.Fatal(err)
	}
	cbResp, err := http.Get("http://127.0.0.1:" + u.Port() + "/callback?code=the-code&state=st-1")
	if err != nil {
		t.Fatal(err)
	}
	pageBytes, _ := io.ReadAll(cbResp.Body)
	_ = cbResp.Body.Close()
	page := string(pageBytes)
	if !strings.Contains(page, "code the server rejected") || !strings.Contains(page, "You can close this tab") || strings.Contains(page, "Try again in llmpilot") {
		t.Errorf("non-429 callback page wrong:\n%s", page)
	}
	// FAIL CASE for the wire code: this non-429 failure carries an EMPTY
	// code on the status endpoint — the sheet must not offer the
	// rate-limited Try-again state for it.
	var br map[string]string
	if err := json.Unmarshal([]byte(body), &br); err != nil {
		t.Fatal(err)
	}
	if resp, sb := doAuthed(t, http.MethodGet, srv.URL+"/v1/login/browser/status?attempt="+br["attempt_id"], "", d.authToken); resp.StatusCode != http.StatusOK || !strings.Contains(sb, `"status":"failed"`) || !strings.Contains(sb, `"code":""`) {
		t.Errorf("non-429 failure must be failed with an empty code: %d (%s)", resp.StatusCode, sb)
	}
}

// TestLoginBrowserRejectsForgedState pins the CSRF guard on the loopback
// listener: a callback whose state does not match fails closed with no
// exchange.
func TestLoginBrowserRejectsForgedState(t *testing.T) {
	stub := &loginStub{}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	// The forged hit correctly leaves the listener serving; cancel the
	// attempt on the way out so the test doesn't strand the goroutine and
	// port until the 10-minute TTL.
	t.Cleanup(func() {
		d.loginMu.Lock()
		for s, a := range d.loginAttempts {
			d.dropAttemptLocked(s, a)
		}
		d.loginMu.Unlock()
	})

	if resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("browser start = %d (%s)", resp.StatusCode, body)
	}
	stub.mu.Lock()
	redirect := stub.lastURLReq
	stub.mu.Unlock()
	u, err := url.Parse(redirect)
	if err != nil {
		t.Fatal(err)
	}
	cbResp, err := http.Get("http://127.0.0.1:" + u.Port() + "/callback?code=c&state=FORGED")
	if err != nil {
		t.Fatal(err)
	}
	_ = cbResp.Body.Close()
	if cbResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("forged-state callback = %d, want 400", cbResp.StatusCode)
	}
	if stub.completes.Load() != 0 {
		t.Fatal("exchange ran for a forged loopback state")
	}
}

// TestLoginBrowserStrayHitDoesNotKillListener pins the P1 fix: a foreign hit
// to the loopback /callback (wrong state — a port scanner or hostile local
// process) fails closed AND keeps the listener alive, so the real redirect
// still completes the sign-in.
func TestLoginBrowserStrayHitDoesNotKillListener(t *testing.T) {
	stub := &loginStub{}
	now := time.Now()
	d := loginDaemon(t, stub, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken); resp.StatusCode != http.StatusOK {
		t.Fatalf("browser start = %d (%s)", resp.StatusCode, body)
	}
	stub.mu.Lock()
	redirect := stub.lastURLReq
	stub.mu.Unlock()
	u, err := url.Parse(redirect)
	if err != nil {
		t.Fatal(err)
	}
	base := "http://127.0.0.1:" + u.Port() + "/callback"

	// Foreign/stray hit (wrong state): fails closed, no exchange, no teardown.
	strayResp, err := http.Get(base + "?code=x&state=WRONG")
	if err != nil {
		t.Fatal(err)
	}
	_ = strayResp.Body.Close()
	if strayResp.StatusCode != http.StatusBadRequest {
		t.Fatalf("stray hit = %d, want 400", strayResp.StatusCode)
	}
	if stub.completes.Load() != 0 {
		t.Fatal("stray hit triggered an exchange")
	}

	// The real redirect still completes — the stray hit did not kill it.
	realResp, err := http.Get(base + "?code=the-code&state=st-1")
	if err != nil {
		t.Fatalf("listener died after a stray hit: %v", err)
	}
	_ = realResp.Body.Close()
	if realResp.StatusCode != http.StatusOK {
		t.Fatalf("real callback = %d, want 200", realResp.StatusCode)
	}
	if stub.completes.Load() != 1 || stub.gotCode != "the-code" {
		t.Fatalf("real callback did not complete: completes=%d", stub.completes.Load())
	}
}

func TestLoginUnwiredIs501WithAuth(t *testing.T) {
	now := time.Now()
	d := loginDaemon(t, nil, &now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	for _, path := range []string{"/v1/login/start", "/v1/login/complete", "/v1/login/browser"} {
		resp, body := doAuthed(t, http.MethodPost, srv.URL+path, `{"code":"c","state":"s"}`, d.authToken)
		if resp.StatusCode != http.StatusNotImplemented {
			t.Errorf("%s unwired = %d (%s), want 501", path, resp.StatusCode, body)
		}
	}
}
