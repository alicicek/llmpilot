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
