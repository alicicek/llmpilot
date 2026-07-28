package cli

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/store"
)

func seededHome(t *testing.T) (string, *store.Store) {
	t.Helper()
	home := t.TempDir()
	st := store.At(home)
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-1", Label: "keep", Email: "a@example.dev"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-1", AsOf: now,
		Buckets: []store.Bucket{{Kind: "session", Percent: 23}},
	}); err != nil {
		t.Fatal(err)
	}
	return home, st
}

// shortHome makes a home whose daemon.sock stays under the macOS 104-byte
// sockaddr_un limit — t.TempDir() paths (TMPDIR + test name) routinely blow
// past it and bind fails with EINVAL.
func shortHome(t *testing.T) string {
	t.Helper()
	home, err := os.MkdirTemp("/tmp", "llp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	if len(daemon.SocketPath(home)) >= 104 {
		t.Fatalf("socket path still too long: %s", daemon.SocketPath(home))
	}
	return home
}

func TestClientStateOverUnixSocket(t *testing.T) {
	home := shortHome(t)
	st := store.At(home)
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-1", Label: "keep", Email: "a@example.dev"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-1", AsOf: now,
		Buckets: []store.Bucket{{Kind: "session", Percent: 23}},
	}); err != nil {
		t.Fatal(err)
	}
	d := &daemon.Daemon{Store: st}

	sock := daemon.SocketPath(home)
	ul, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("unix listen: %v", err)
	}
	srv := &http.Server{Handler: d.Handler(), ReadHeaderTimeout: time.Second}
	go func() { _ = srv.Serve(ul) }()
	t.Cleanup(func() { _ = srv.Close() })

	c := &Client{Home: home}
	got, err := c.State(context.Background())
	if err != nil {
		t.Fatalf("State over socket: %v", err)
	}
	if len(got.Accounts) != 1 || got.Accounts[0].Snapshot == nil ||
		got.Accounts[0].Snapshot.Buckets[0].Percent != 23 {
		t.Errorf("state = %+v", got)
	}
}

func TestClientFallsBackToLoopbackPort(t *testing.T) {
	home, st := seededHome(t)
	d := &daemon.Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	t.Cleanup(srv.Close)

	port := strings.TrimPrefix(srv.URL, "http://127.0.0.1:")
	if _, err := strconv.Atoi(port); err != nil {
		t.Fatalf("unexpected httptest addr %s", srv.URL)
	}
	if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// No socket exists — the client must fall through to the port file.
	c := &Client{Home: home}
	got, err := c.State(context.Background())
	if err != nil {
		t.Fatalf("State over loopback: %v", err)
	}
	if len(got.Accounts) != 1 {
		t.Errorf("state = %+v", got)
	}
}

func TestCockpitURLCarriesTokenFragment(t *testing.T) {
	home, st := seededHome(t)
	d := &daemon.Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	t.Cleanup(srv.Close)
	port := strings.TrimPrefix(srv.URL, "http://127.0.0.1:")
	if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &Client{Home: home}

	// No token file yet — the bare URL still opens a read-only cockpit.
	url, err := c.CockpitURL(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if url != srv.URL {
		t.Errorf("tokenless CockpitURL = %q, want %q", url, srv.URL)
	}

	if err := os.WriteFile(daemon.TokenFilePath(home), []byte("cafe01\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	url, err = c.CockpitURL(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if url != srv.URL+"/#token=cafe01" {
		t.Errorf("CockpitURL = %q, want token fragment", url)
	}
}

func TestClientDaemonDown(t *testing.T) {
	c := &Client{Home: t.TempDir(), Timeout: 200 * time.Millisecond}
	_, err := c.State(context.Background())
	if !errors.Is(err, ErrDaemonDown) {
		t.Errorf("err = %v, want ErrDaemonDown", err)
	}
	if !strings.Contains(err.Error(), "llmpilot daemon install") {
		t.Errorf("error must say what to do next: %v", err)
	}
}

func TestClientStaleSocketFallsBackThenDown(t *testing.T) {
	home := t.TempDir()
	// A dead daemon's leftover socket file: connecting fails, no port file.
	if err := os.WriteFile(daemon.SocketPath(home), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	_ = filepath.Join(home) // keep home referenced
	c := &Client{Home: home, Timeout: 200 * time.Millisecond}
	_, err := c.State(context.Background())
	if !errors.Is(err, ErrDaemonDown) {
		t.Errorf("err = %v, want ErrDaemonDown", err)
	}
}

// TestClientTellsSilenceFromARefusal pins the distinction the doctor's copy
// rests on. Nothing listening = ErrDaemonDown, plain. Something listening that
// will not serve the document = ErrDaemonAnswered, which WRAPS ErrDaemonDown so
// every existing degraded path keeps behaving exactly as it did.
func TestClientTellsSilenceFromARefusal(t *testing.T) {
	// A daemon that ACCEPTS and then does not answer in time is a third shape:
	// the health sweep is the daemon's most expensive route, so this is what a
	// busy one looks like — and it must not be diagnosed as a stale one.
	t.Run("accepted but did not answer in time", func(t *testing.T) {
		release := make(chan struct{})
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			select {
			case <-release:
			case <-r.Context().Done():
			}
		}))
		t.Cleanup(func() { close(release); srv.Close() })
		home := t.TempDir()
		port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
		if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		c := &Client{Home: home, Timeout: 120 * time.Millisecond}
		_, err := c.Doctor(context.Background())
		if !errors.Is(err, ErrDaemonSlow) {
			t.Fatalf("err = %v, want ErrDaemonSlow", err)
		}
		// Every wider caller must still degrade rather than hard-fail.
		if !errors.Is(err, ErrDaemonAnswered) || !errors.Is(err, ErrDaemonDown) {
			t.Errorf("ErrDaemonSlow must wrap both: %v", err)
		}
		if !strings.Contains(AnsweredReason(err), "did not answer in time") {
			t.Errorf("reason = %q", AnsweredReason(err))
		}
	})

	// A port file left behind by a dead daemon with NOTHING listening must
	// stay plain silence — otherwise the doctor claims something is there.
	t.Run("a stale port file with nothing behind it", func(t *testing.T) {
		home := t.TempDir()
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := ln.Addr().(*net.TCPAddr).Port
		_ = ln.Close() // free it again: the file now points at nothing
		if err := os.WriteFile(daemon.PortFilePath(home), []byte(strconv.Itoa(port)+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		c := &Client{Home: home, Timeout: 300 * time.Millisecond}
		_, err = c.Doctor(context.Background())
		if !errors.Is(err, ErrDaemonDown) {
			t.Fatalf("err = %v, want ErrDaemonDown", err)
		}
		if errors.Is(err, ErrDaemonAnswered) {
			t.Errorf("a refused connection was reported as something listening: %v", err)
		}
	})

	// The unix socket half of the same rule — the transport `llmpilot doctor`
	// actually reaches first.
	t.Run("the socket accepts and hangs up", func(t *testing.T) {
		// A short root on purpose: a unix socket path is capped near 104 bytes
		// and t.TempDir()'s name blows past it.
		home, err := os.MkdirTemp("/tmp", "llmp")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.RemoveAll(home) })
		ln, err := net.Listen("unix", daemon.SocketPath(home))
		if err != nil {
			t.Fatal(err)
		}
		defer ln.Close() //nolint:errcheck // test
		go func() {
			for {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				_ = conn.Close()
			}
		}()
		c := &Client{Home: home, Timeout: 300 * time.Millisecond}
		_, err = c.Doctor(context.Background())
		if !errors.Is(err, ErrDaemonAnswered) {
			t.Fatalf("err = %v, want ErrDaemonAnswered (something IS listening on the socket)", err)
		}
		// ...and it is described as what it was: nothing ANSWERED.
		if got := AnsweredReason(err); got != "it accepted the connection but sent no usable answer" {
			t.Errorf("AnsweredReason = %q — a hang-up is not an answer", got)
		}
	})

	t.Run("nothing listening", func(t *testing.T) {
		c := &Client{Home: t.TempDir(), Timeout: 200 * time.Millisecond}
		_, err := c.Doctor(context.Background())
		if !errors.Is(err, ErrDaemonDown) {
			t.Fatalf("err = %v, want ErrDaemonDown", err)
		}
		if errors.Is(err, ErrDaemonAnswered) {
			t.Errorf("silence was reported as an answer: %v", err)
		}
	})

	// The shape a daemon OLDER than this binary actually produces: it has no
	// /v1/doctor route, so the embedded cockpit's catch-all answers 200 with
	// index.html. A non-200 never happens for this case, so testing only that
	// would have proven nothing.
	for _, tc := range []struct {
		name       string
		handler    http.HandlerFunc
		wantReason string
	}{
		{"an older daemon serving the cockpit shell", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte("<!doctype html><title>llmpilot</title>"))
		}, "it answered with something that is not the document llmpilot asked for"},
		{"a route that does not exist", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}, "it answered 404"},
		{"a daemon whose sweep is broken", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}, "it answered 500"},
		{"json that is not a health report", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"unrelated":true}`))
		}, "it answered without a single health check"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(tc.handler)
			defer srv.Close()
			home := t.TempDir()
			port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
			if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			c := &Client{Home: home, Timeout: time.Second}
			_, err := c.Doctor(context.Background())
			if !errors.Is(err, ErrDaemonAnswered) {
				t.Fatalf("err = %v, want ErrDaemonAnswered", err)
			}
			// ...and every caller that degrades on ErrDaemonDown still does.
			if !errors.Is(err, ErrDaemonDown) {
				t.Errorf("ErrDaemonAnswered must wrap ErrDaemonDown so `status` keeps degrading: %v", err)
			}
			if errors.Is(err, ErrDaemonSlow) {
				t.Errorf("an answer was misreported as a timeout: %v", err)
			}
			// The OBSERVATION must survive, not a canned sentence: a caller
			// that renders "what llmpilot saw" has to get what it saw.
			if got := AnsweredReason(err); got != tc.wantReason {
				t.Errorf("AnsweredReason = %q, want %q", got, tc.wantReason)
			}
		})
	}
}

// TestClientDialFlagIsRaceFree guards the fix for a race -race could not see:
// the dial flag is written by the transport's goroutine and read by this one
// after Do returns, and only a deadline that fires DURING the dial exposes it.
// Every shipped test uses a timeout long enough to hide it, so this one exists
// to fail under `go test -race` if the flag ever stops being atomic.
func TestClientDialFlagIsRaceFree(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"checks":[{"id":"x","title":"t","state":"ok"}]}`))
	}))
	defer srv.Close()
	home := t.TempDir()
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 400; i++ {
		// Sweep the deadline across the dial/read window.
		c := &Client{Home: home, Timeout: time.Duration(1+i%300) * time.Microsecond}
		_, _ = c.Doctor(context.Background())
	}

	// The socket transport carries its OWN flag, and a home with only a port
	// file never reaches it.
	sockHome, err := os.MkdirTemp("/tmp", "llmp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(sockHome) })
	ln, err := net.Listen("unix", daemon.SocketPath(sockHome))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close() //nolint:errcheck // test
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	for i := 0; i < 400; i++ {
		c := &Client{Home: sockHome, Timeout: time.Duration(1+i%300) * time.Microsecond}
		_, _ = c.Doctor(context.Background())
	}
}

// TestClientMidBodyTimeoutIsSlowNotBroken: a deadline can fire AFTER the
// response headers, which arrives as a read failure rather than a transport
// one. Classified as a broken answer it earns a hard kill; classified as what
// it is — a daemon that needed longer — it earns "run this again". The cause
// preserved on answeredError is the only thing that tells them apart.
func TestClientMidBodyTimeoutIsSlowNotBroken(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", "512")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"checks":[{"id":"x",`)) // a real prefix, then nothing
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() { close(release); srv.Close() })
	home := t.TempDir()
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &Client{Home: home, Timeout: 150 * time.Millisecond}
	_, err := c.Doctor(context.Background())
	if !errors.Is(err, ErrDaemonSlow) {
		t.Fatalf("err = %v, want ErrDaemonSlow — a deadline mid-body is still a deadline", err)
	}
	if !strings.Contains(AnsweredReason(err), "did not answer in time") {
		t.Errorf("reason = %q", AnsweredReason(err))
	}
}

// TestClientPrefersTheTimeoutOnATie: one transport hangs up, the other times
// out. The diagnosis must be the timeout — being wrong that way costs a
// re-run; the other way hands a hard kill to a daemon that is merely busy.
func TestClientPrefersTheTimeoutOnATie(t *testing.T) {
	home, err := os.MkdirTemp("/tmp", "llmp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	ln, err := net.Listen("unix", daemon.SocketPath(home))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close() //nolint:errcheck // test
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			_ = conn.Close() // hang up: rank 1, not slow
		}
	}()
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() { close(release); srv.Close() })
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(home), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &Client{Home: home, Timeout: 150 * time.Millisecond}
	_, err = c.Doctor(context.Background())
	if !errors.Is(err, ErrDaemonSlow) {
		t.Fatalf("err = %v — a hang-up on one transport must not outrank a timeout on the other", err)
	}
}
