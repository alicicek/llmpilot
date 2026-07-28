package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

func testStore(t *testing.T) *store.Store {
	t.Helper()
	st := store.At(t.TempDir())
	accs := []store.Account{
		{ID: "a", Label: "a", Email: "a@example.dev"},
		{ID: "b", Label: "b", Email: "b@example.dev"},
	}
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestStateServesAccountsAndSnapshots(t *testing.T) {
	st := testStore(t)
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "a",
		AsOf:      time.Now().UTC(),
		Buckets:   []store.Bucket{{Kind: "five_hour", Percent: 23}},
	}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st, Active: func(context.Context) string { return "a" }}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != 200 {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var got State
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if len(got.Accounts) != 2 || got.ActiveID != "a" {
		t.Fatalf("state = %+v", got)
	}
	if got.Accounts[0].Snapshot == nil || got.Accounts[0].Snapshot.Buckets[0].Kind != "five_hour" {
		t.Fatalf("snapshot missing: %+v", got.Accounts[0])
	}
	if got.Accounts[1].Snapshot != nil {
		t.Fatalf("account b should have no snapshot")
	}
}

// TestSSEEventOnCacheChange proves a poll that changes the cache pushes a
// state event to an already-connected SSE subscriber.
func TestSSEEventOnCacheChange(t *testing.T) {
	st := testStore(t)
	percent := 10.0
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour, // poll only when the test calls pollOne
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: percent}}, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("content-type = %q", ct)
	}
	rd := bufio.NewReader(resp.Body)
	readEvent := func() State {
		t.Helper()
		var data string
		for {
			line, err := rd.ReadString('\n')
			if err != nil {
				t.Fatalf("read SSE: %v", err)
			}
			line = strings.TrimRight(line, "\n")
			if strings.HasPrefix(line, "data: ") {
				data = strings.TrimPrefix(line, "data: ")
			}
			if line == "" && data != "" {
				var s State
				if err := json.Unmarshal([]byte(data), &s); err != nil {
					t.Fatalf("bad SSE payload: %v", err)
				}
				return s
			}
		}
	}

	_ = readEvent() // initial snapshot-on-connect
	percent = 42
	accs, _ := st.Accounts()
	d.pollOne(context.Background(), accs[0])
	got := readEvent()
	if got.Accounts[0].Snapshot == nil || got.Accounts[0].Snapshot.Buckets[0].Percent != 42 {
		t.Fatalf("SSE state after change = %+v", got.Accounts[0])
	}
}

func TestPerAccount429Cooldown(t *testing.T) {
	st := testStore(t)
	calls := map[string]int{}
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Millisecond,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			calls[a.ID]++
			return nil, &anthropic.StatusError{StatusCode: 429}
		},
	}
	d.init()
	// A 429 cools ONLY the offending account: both accounts still get their
	// own poll in the first pass (no fleet-global silence).
	d.pollDue(context.Background())
	if calls["a"] != 1 || calls["b"] != 1 {
		t.Fatalf("first pass calls = %v, want each account polled once (per-account, not fleet-global)", calls)
	}
	// Second pass: both are now cooling → neither re-polls.
	d.pollDue(context.Background())
	if calls["a"] != 1 || calls["b"] != 1 {
		t.Fatalf("cooling pass calls = %v, want no re-polls", calls)
	}
	d.mu.Lock()
	until := time.Until(d.cooldown["a"].until)
	d.mu.Unlock()
	if until < 9*time.Minute || until > 10*time.Minute {
		t.Fatalf("cooldown[a] = %v from now, want ~10m (RateLimitBackoff(0,0))", until)
	}
	stt, _ := d.State(context.Background())
	for _, acc := range stt.Accounts {
		if acc.TokenNote != rateLimitedNote {
			t.Fatalf("account %s note = %q, want rateLimitedNote", acc.ID, acc.TokenNote)
		}
	}
}

func TestSwitchEndpoint(t *testing.T) {
	st := testStore(t)
	var switchedTo string
	d := &Daemon{
		Store:  st,
		Switch: func(_ context.Context, id string) error { switchedTo = id; return nil },
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/switch", "application/json", strings.NewReader(`{"account_id":"b"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != 200 || switchedTo != "b" {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, switchedTo = %q, body = %s", resp.StatusCode, switchedTo, body)
	}

	bad, err := http.Post(srv.URL+"/v1/switch", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Body.Close() //nolint:errcheck // test
	if bad.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty body status = %d, want 400", bad.StatusCode)
	}
}

// TestServeSocketAndPortFile proves Serve exposes the API on a 0600 unix
// socket and a loopback port persisted to daemon.port, and cleans both up.
func TestServeSocketAndPortFile(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st, AllowFastPoll: true, PollInterval: time.Hour}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- d.Serve(ctx) }()

	home := st.Home()
	sock := SocketPath(home)
	portFile := PortFilePath(home)
	tokenFile := TokenFilePath(home)
	var port int
	deadline := time.Now().Add(5 * time.Second)
	for {
		if b, err := os.ReadFile(portFile); err == nil {
			port, err = strconv.Atoi(strings.TrimSpace(string(b)))
			if err != nil {
				t.Fatalf("port file contents: %v", err)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("daemon never wrote daemon.port")
		}
		time.Sleep(10 * time.Millisecond)
	}

	fi, err := os.Stat(sock)
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("socket perms = %o, want 600", perm)
	}

	// The auth token is readable (0600) the moment the port file exists —
	// clients treat the port file as the readiness signal.
	tfi, err := os.Stat(tokenFile)
	if err != nil {
		t.Fatalf("token file missing when port file exists: %v", err)
	}
	if perm := tfi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("token file perms = %o, want 600", perm)
	}
	tok, err := os.ReadFile(tokenFile)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(tok)); got != d.authToken || got == "" {
		t.Fatal("token file does not match the daemon's token")
	}

	// API answers on the unix socket…
	uc := http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", sock)
		},
	}}
	// "llmpilot" is the placeholder Host the real CLI sends over the socket;
	// checkHost admits it.
	resp, err := uc.Get("http://llmpilot/v1/state")
	if err != nil {
		t.Fatalf("unix socket GET: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("unix socket status = %d", resp.StatusCode)
	}
	// …and on loopback.
	resp2, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/v1/state", port))
	if err != nil {
		t.Fatalf("loopback GET: %v", err)
	}
	_ = resp2.Body.Close()
	if resp2.StatusCode != 200 {
		t.Fatalf("loopback status = %d", resp2.StatusCode)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Serve returned %v", err)
	}
	if _, err := os.Stat(sock); !os.IsNotExist(err) {
		t.Fatalf("socket not cleaned up: %v", err)
	}
	if _, err := os.Stat(portFile); !os.IsNotExist(err) {
		t.Fatalf("port file not cleaned up: %v", err)
	}
	if _, err := os.Stat(tokenFile); !os.IsNotExist(err) {
		t.Fatalf("token file not cleaned up: %v", err)
	}
}

// A fresh install serves zero accounts — the arrays must marshal as [] and
// never as null, or every state decoder on the fleet surfaces dies exactly
// on first run (the menu bar's did).
func TestStateEmptyFleetMarshalsArraysNotNull(t *testing.T) {
	d := &Daemon{Store: store.At(t.TempDir())}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/v1/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), `"accounts":[]`) {
		t.Fatalf("empty fleet must serve accounts:[] — got: %s", body)
	}
	if strings.Contains(string(body), `"accounts":null`) || strings.Contains(string(body), `"schedules":null`) {
		t.Fatalf("null arrays in fresh-install state: %s", body)
	}
}
