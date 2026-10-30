package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// fakeAttempt stands in for a running Claude Code sign-in.
type fakeAttempt struct {
	mu         sync.Mutex
	manual     string
	codes      []string
	codeErr    error
	done       chan struct{}
	once       sync.Once
	res        switcher.ImportResult
	finishErr  error
	finishGate chan struct{} // when set, Finish waits for it
	finished   atomic.Int32
	aborted    atomic.Int32
}

func newFakeAttempt() *fakeAttempt {
	return &fakeAttempt{
		manual: "https://claude.com/cai/oauth/authorize?code=true",
		done:   make(chan struct{}),
		res: switcher.ImportResult{
			Account: store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"},
			Outcome: switcher.ImportAdded,
		},
	}
}

func (f *fakeAttempt) ManualURL() string { return f.manual }
func (f *fakeAttempt) SubmitCode(c string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.codeErr != nil {
		return f.codeErr
	}
	f.codes = append(f.codes, c)
	return nil
}
func (f *fakeAttempt) Done() <-chan struct{} { return f.done }
func (f *fakeAttempt) exit()                 { f.once.Do(func() { close(f.done) }) }
func (f *fakeAttempt) Finish(context.Context) (switcher.ImportResult, error) {
	f.finished.Add(1)
	if f.finishGate != nil {
		<-f.finishGate
	}
	return f.res, f.finishErr
}
func (f *fakeAttempt) Abort() {
	f.aborted.Add(1)
	f.exit()
}

type signInHarness struct {
	d        *Daemon
	srv      *httptest.Server
	mu       sync.Mutex
	emails   []string
	attempts []*fakeAttempt
	startErr error
}

func newSignInHarness(t *testing.T) *signInHarness {
	t.Helper()
	h := &signInHarness{}
	h.d = &Daemon{Store: store.At(t.TempDir())}
	h.d.SignIn = func(_ context.Context, email string) (SignInAttempt, error) {
		h.mu.Lock()
		defer h.mu.Unlock()
		if h.startErr != nil {
			return nil, h.startErr
		}
		h.emails = append(h.emails, email)
		a := newFakeAttempt()
		h.attempts = append(h.attempts, a)
		return a, nil
	}
	h.srv = httptest.NewServer(h.d.Handler())
	t.Cleanup(h.srv.Close)
	t.Cleanup(h.d.stopSignIn)
	return h
}

func (h *signInHarness) attempt(i int) *fakeAttempt {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.attempts[i]
}

func (h *signInHarness) start(t *testing.T, body string) string {
	t.Helper()
	resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser", body, h.d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start = %d (%s)", resp.StatusCode, raw)
	}
	var out map[string]string
	if err := json.Unmarshal([]byte(raw), &out); err != nil || len(out["attempt_id"]) != 32 {
		t.Fatalf("start body = %s", raw)
	}
	return out["attempt_id"]
}

func (h *signInHarness) status(t *testing.T, id string) map[string]string {
	t.Helper()
	resp, raw := doAuthed(t, http.MethodGet, h.srv.URL+"/v1/login/browser/status?attempt="+id, "", h.d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d (%s)", resp.StatusCode, raw)
	}
	var out map[string]string
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func (h *signInHarness) waitStatus(t *testing.T, id, want string) map[string]string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		s := h.status(t, id)
		if s["status"] == want {
			return s
		}
		if time.Now().After(deadline) {
			t.Fatalf("status = %v, want %s", s, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestSignInHappyPath(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	s := h.status(t, id)
	if s["status"] != "pending" || s["manual_url"] != "https://claude.com/cai/oauth/authorize?code=true" {
		t.Fatalf("pending status = %v", s)
	}
	h.attempt(0).exit() // Claude Code finished
	s = h.waitStatus(t, id, "done")
	if s["account_id"] != "acct-b" || s["email"] != "b@example.dev" || s["outcome"] != "added" || s["manual_url"] != "" {
		t.Fatalf("done status = %v", s)
	}
	if n := h.attempt(0).finished.Load(); n != 1 {
		t.Fatalf("Finish called %d times", n)
	}
}

func TestSignInPrefillsEmail(t *testing.T) {
	h := newSignInHarness(t)
	h.start(t, `{"email":" b@example.dev "}`)
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.emails) != 1 || h.emails[0] != "b@example.dev" {
		t.Fatalf("emails = %v", h.emails)
	}
}

func TestSignInRefusesUnsafeEmail(t *testing.T) {
	h := newSignInHarness(t)
	for _, e := range []string{"--console", "-x@example.dev", "a b@example.dev", "a@example.dev, c@example.dev",
		"<a@example.dev>", "Bob <a@example.dev>", "nobody", strings.Repeat("a", 250) + "@example.dev"} {
		body, _ := json.Marshal(map[string]string{"email": e})
		resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser", string(body), h.d.authToken)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("email %q = %d (%s), want 400", e, resp.StatusCode, raw)
		}
	}
	if len(h.attempts) != 0 {
		t.Fatalf("Claude Code started for an unsafe email: %d", len(h.attempts))
	}
}

func TestSignInWithoutClaudeCode(t *testing.T) {
	h := newSignInHarness(t)
	h.startErr = claudecfg.ErrCLINotFound
	resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser", `{}`, h.d.authToken)
	var out map[string]string
	_ = json.Unmarshal([]byte(raw), &out)
	if resp.StatusCode != http.StatusConflict || out["code"] != LoginCodeClaudeMissing {
		t.Fatalf("= %d %s, want 409 claude_missing", resp.StatusCode, raw)
	}
}

func TestSignInPastedCode(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser/code",
		`{"attempt_id":"`+id+`","code":"abcdefgh#statestate"}`, h.d.authToken)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("code = %d (%s)", resp.StatusCode, raw)
	}
	a := h.attempt(0)
	a.mu.Lock()
	got := append([]string{}, a.codes...)
	a.mu.Unlock()
	if len(got) != 1 || got[0] != "abcdefgh#statestate" {
		t.Fatalf("codes = %v", got)
	}
	// The code never comes back out of the status route.
	if s := h.status(t, id); strings.Contains(strings.Join([]string{s["error"], s["manual_url"]}, " "), "statestate") {
		t.Fatalf("status echoed the code: %v", s)
	}

	a.mu.Lock()
	a.codeErr = claudecfg.ErrBadCode
	a.mu.Unlock()
	resp, _ = doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser/code",
		`{"attempt_id":"`+id+`","code":"nope"}`, h.d.authToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad code = %d, want 400", resp.StatusCode)
	}
	resp, _ = doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser/code",
		`{"attempt_id":"someone-elses","code":"abcdefgh#statestate"}`, h.d.authToken)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown attempt = %d, want 404", resp.StatusCode)
	}
}

func TestSignInCancel(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser/cancel", `{"attempt_id":"`+id+`"}`, h.d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("cancel = %d (%s)", resp.StatusCode, raw)
	}
	s := h.waitStatus(t, id, "failed")
	if s["code"] != LoginCodeCancelled {
		t.Fatalf("status = %v", s)
	}
	a := h.attempt(0)
	if a.aborted.Load() == 0 || a.finished.Load() != 0 {
		t.Fatalf("aborted=%d finished=%d", a.aborted.Load(), a.finished.Load())
	}
	// Cancelling again is harmless.
	resp, _ = doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser/cancel", `{"attempt_id":"`+id+`"}`, h.d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("second cancel = %d", resp.StatusCode)
	}
}

func TestSignInNewerReplacesOlder(t *testing.T) {
	h := newSignInHarness(t)
	first := h.start(t, `{}`)
	second := h.start(t, `{}`)
	if s := h.waitStatus(t, first, "failed"); s["code"] != LoginCodeReplaced {
		t.Fatalf("first = %v", s)
	}
	if h.attempt(0).aborted.Load() == 0 {
		t.Fatal("the replaced sign-in kept running")
	}
	if s := h.status(t, second); s["status"] != "pending" {
		t.Fatalf("second = %v", s)
	}
}

func TestSignInTimesOut(t *testing.T) {
	old := loginAttemptTTL
	loginAttemptTTL = 50 * time.Millisecond
	t.Cleanup(func() { loginAttemptTTL = old })
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	if s := h.waitStatus(t, id, "failed"); s["code"] != LoginCodeTimedOut {
		t.Fatalf("status = %v", s)
	}
	if h.attempt(0).aborted.Load() == 0 {
		t.Fatal("timed-out sign-in kept running")
	}
}

func TestSignInFinishFailure(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	a := h.attempt(0)
	a.finishErr = errors.New("the Claude Code sign-in ended without finishing: OAuth error: access_denied")
	a.exit()
	s := h.waitStatus(t, id, "failed")
	if !strings.Contains(s["error"], "access_denied") || s["account_id"] != "" {
		t.Fatalf("status = %v", s)
	}
}

func TestFreshSignInLiftsQuarantine(t *testing.T) {
	h := newSignInHarness(t)
	h.d.mu.Lock()
	h.d.quarantine["acct-b"] = "sha256:dead"
	h.d.tokenNotes["acct-b"] = deadLineageNote
	h.d.nextPoll["acct-b"] = time.Now().Add(time.Hour)
	h.d.mu.Unlock()
	id := h.start(t, `{}`)
	h.attempt(0).exit()
	h.waitStatus(t, id, "done")
	h.d.mu.Lock()
	defer h.d.mu.Unlock()
	if _, q := h.d.quarantine["acct-b"]; q || h.d.tokenNotes["acct-b"] != "" {
		t.Fatal("a fresh sign-in left the account quarantined")
	}
	if !h.d.nextPoll["acct-b"].IsZero() {
		t.Fatal("the account was not queued for an immediate poll")
	}
}

func TestSignInDoneIsNeverRepainted(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	h.attempt(0).exit()
	h.waitStatus(t, id, "done")
	h.d.setLoginResult(id, loginResult{status: "failed", code: LoginCodeTimedOut})
	if s := h.status(t, id); s["status"] != "done" {
		t.Fatalf("status = %v", s)
	}
}

func TestStopSignInAtShutdown(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	h.d.stopSignIn()
	if h.attempt(0).aborted.Load() == 0 {
		t.Fatal("shutdown left the sign-in running")
	}
	if s := h.waitStatus(t, id, "failed"); s["code"] != LoginCodeCancelled {
		t.Fatalf("status = %v", s)
	}
}

func TestSignInNotWired(t *testing.T) {
	d := &Daemon{Store: store.At(t.TempDir())}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, _ := doAuthed(t, http.MethodPost, srv.URL+"/v1/login/browser", `{}`, d.authToken)
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("= %d, want 501", resp.StatusCode)
	}
}

func TestSignInUnknownStatus(t *testing.T) {
	h := newSignInHarness(t)
	resp, _ := doAuthed(t, http.MethodGet, h.srv.URL+"/v1/login/browser/status?attempt=nope", "", h.d.authToken)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("= %d, want 404", resp.StatusCode)
	}
}

func TestSignInReportsAnAccountTheFleetAlreadyHad(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	a := h.attempt(0)
	a.res.Existed = true
	a.res.Outcome = switcher.ImportUpdated
	a.res.Note = "a note"
	a.exit()
	if s := h.waitStatus(t, id, "done"); s["existing"] != "true" || s["outcome"] != "updated" || s["note"] != "a note" {
		t.Fatalf("status = %v", s)
	}
	id2 := h.start(t, `{}`)
	h.attempt(1).exit()
	if s := h.waitStatus(t, id2, "done"); s["existing"] != "" {
		t.Fatalf("a new account reported as existing: %v", s)
	}
}

func TestSignInRefusedOnceShuttingDown(t *testing.T) {
	h := newSignInHarness(t)
	h.d.stopSignIn()
	resp, raw := doAuthed(t, http.MethodPost, h.srv.URL+"/v1/login/browser", `{}`, h.d.authToken)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("= %d (%s), want 503", resp.StatusCode, raw)
	}
	if h.attempt(0).aborted.Load() == 0 {
		t.Fatal("a sign-in started during shutdown was left running")
	}
}

func TestStopSignInWaitsForAnImportUnderWay(t *testing.T) {
	h := newSignInHarness(t)
	id := h.start(t, `{}`)
	a := h.attempt(0)
	a.finishGate = make(chan struct{})
	a.exit()
	for a.finished.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	stopped := make(chan struct{})
	go func() { h.d.stopSignIn(); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("shutdown did not wait for the import")
	case <-time.After(100 * time.Millisecond):
	}
	close(a.finishGate)
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown never returned")
	}
	if s := h.status(t, id); s["status"] != "done" {
		t.Fatalf("the import under way was not allowed to land: %v", s)
	}
}

// A sign-in replaced by a newer one may already be importing; shutdown must
// wait for it too, not only for the newest attempt.
func TestStopSignInWaitsForAReplacedImportStillRunning(t *testing.T) {
	h := newSignInHarness(t)
	h.start(t, `{}`)
	first := h.attempt(0)
	first.finishGate = make(chan struct{})
	first.exit()
	for first.finished.Load() == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	h.start(t, `{}`) // replaces the first while it imports
	stopped := make(chan struct{})
	go func() { h.d.stopSignIn(); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("shutdown left a replaced import running")
	case <-time.After(100 * time.Millisecond):
	}
	close(first.finishGate)
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("shutdown never returned")
	}
}
