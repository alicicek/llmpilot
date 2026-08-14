package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// noticesDaemon builds a bare daemon and starts it behind httptest, exactly
// like the SSE test in daemon_test.go — Handler() runs d.init() synchronously
// before returning, so d.authToken and d.notices are both ready the moment
// this returns.
func noticesDaemon(t *testing.T) (*Daemon, *httptest.Server) {
	t.Helper()
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	return d, srv
}

func connectNotices(t *testing.T, srv *httptest.Server, token string) (*http.Response, *bufio.Reader) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, srv.URL+"/v1/notices", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp, bufio.NewReader(resp.Body)
}

func readNotice(t *testing.T, rd *bufio.Reader) Notice {
	t.Helper()
	var data string
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			t.Fatalf("read notice SSE: %v", err)
		}
		line = strings.TrimRight(line, "\n")
		if strings.HasPrefix(line, "data: ") {
			data = strings.TrimPrefix(line, "data: ")
		}
		if line == "" && data != "" {
			var n Notice
			if err := json.Unmarshal([]byte(data), &n); err != nil {
				t.Fatalf("bad notice payload: %v", err)
			}
			return n
		}
	}
}

// TestNoticesRequireAuth pins the /v1/notices auth boundary — same
// requireAuth guard as the license/login/stash routes (auth_test.go), just
// exercised here since it isn't a license route.
func TestNoticesRequireAuth(t *testing.T) {
	d, srv := noticesDaemon(t)
	defer srv.Close()

	for _, tok := range []string{"", "not-the-token"} {
		resp, body := doAuthed(t, http.MethodGet, srv.URL+"/v1/notices", "", tok)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("token %q: status = %d, want 401", tok, resp.StatusCode)
		}
		var got map[string]string
		_ = json.Unmarshal([]byte(body), &got)
		if got["code"] != "auth_required" {
			t.Fatalf("token %q: code = %q, want auth_required", tok, got["code"])
		}
	}

	resp, rd := connectNotices(t, srv, d.authToken)
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("authed connect status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content-type = %q", ct)
	}
	_ = rd
}

// TestNoticeDispatchToSubscriber proves a connected subscriber receives a
// dispatched notice, and that the wrapped fallback notifier is NOT invoked
// while a subscriber is connected.
func TestNoticeDispatchToSubscriber(t *testing.T) {
	d, srv := noticesDaemon(t)
	defer srv.Close()

	var mu sync.Mutex
	fallbackCalls := 0
	notify := d.NoticeDispatcher(func(_ context.Context, _, _ string) {
		mu.Lock()
		fallbackCalls++
		mu.Unlock()
	})

	// The handler subscribes BEFORE writing response headers, and Do() only
	// returns once headers arrive — so the subscription is already in the
	// bus by the time this call returns. No sleep/poll needed.
	resp, rd := connectNotices(t, srv, d.authToken)
	defer resp.Body.Close() //nolint:errcheck // test

	notify(context.Background(), "llmpilot", "a at 80% — resets 15:04")

	n := readNotice(t, rd)
	if n.Title != "llmpilot" || n.Body != "a at 80% — resets 15:04" {
		t.Fatalf("notice = %+v", n)
	}
	if n.ID == "" {
		t.Fatal("notice id is empty")
	}

	mu.Lock()
	defer mu.Unlock()
	if fallbackCalls != 0 {
		t.Fatalf("fallback called %d times, want 0 — a subscriber was connected", fallbackCalls)
	}
}

// TestNoticeFallbackWithNoSubscriber proves the wrapped legacy notifier
// fires when nobody is connected to /v1/notices at dispatch time — the
// headless-CLI / no-app-running path.
func TestNoticeFallbackWithNoSubscriber(t *testing.T) {
	d, _ := noticesDaemon(t)

	var mu sync.Mutex
	var got []string
	notify := d.NoticeDispatcher(func(_ context.Context, title, body string) {
		mu.Lock()
		got = append(got, title+"|"+body)
		mu.Unlock()
	})

	notify(context.Background(), "llmpilot", "no one is listening")

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0] != "llmpilot|no one is listening" {
		t.Fatalf("fallback calls = %v, want exactly one", got)
	}
}

// TestNoticeSubscriberDisconnectReturnsToFallback proves the bus is
// stateless: once the only subscriber disconnects, a LATER dispatch takes
// the fallback path again — "was ever subscribed" must not stick.
func TestNoticeSubscriberDisconnectReturnsToFallback(t *testing.T) {
	d, srv := noticesDaemon(t)
	defer srv.Close()

	var mu sync.Mutex
	fallbackCalls := 0
	notify := d.NoticeDispatcher(func(_ context.Context, _, _ string) {
		mu.Lock()
		fallbackCalls++
		mu.Unlock()
	})

	resp, rd := connectNotices(t, srv, d.authToken)
	notify(context.Background(), "llmpilot", "first")
	_ = readNotice(t, rd)
	if err := resp.Body.Close(); err != nil {
		t.Fatal(err)
	}

	// The server's unsubscribe runs off the client closing the connection —
	// asynchronous with respect to this goroutine. Retry the dispatch until
	// the fallback observes the now-empty subscriber set; bounded, so a real
	// regression (fallback never firing) still fails the test.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		notify(context.Background(), "llmpilot", "second")
		mu.Lock()
		calls := fallbackCalls
		mu.Unlock()
		if calls >= 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	if fallbackCalls < 1 {
		t.Fatal("fallback never fired after the only subscriber disconnected")
	}
}
