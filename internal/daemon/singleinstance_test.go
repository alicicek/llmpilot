package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// shortLockHome returns a home short enough for macOS's 104-byte
// sockaddr_un cap — t.TempDir() plus these test names blows past it.
func shortLockHome(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "lpw11")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func waitPortFile(t *testing.T, home string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(PortFilePath(home)); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("daemon never wrote daemon.port")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func socketGetState(home string) error {
	c := http.Client{
		Timeout: 2 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", SocketPath(home))
			},
		},
	}
	resp, err := c.Get("http://llmpilot/v1/state")
	if err != nil {
		return err
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("state status %d", resp.StatusCode)
	}
	return nil
}

// TestServeSecondInstanceRefusesWithoutStealingSocket is the already-live
// class: a second Serve against the same home must return ErrAlreadyRunning
// and must NOT remove or rebind the live daemon's socket.
func TestServeSecondInstanceRefusesWithoutStealingSocket(t *testing.T) {
	home := shortLockHome(t)
	d1 := &Daemon{Store: store.At(home), PollInterval: time.Hour}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- d1.Serve(ctx) }()
	waitPortFile(t, home)
	if err := socketGetState(home); err != nil {
		t.Fatalf("first daemon not serving: %v", err)
	}

	d2 := &Daemon{Store: store.At(home), PollInterval: time.Hour}
	start := time.Now()
	err := d2.Serve(context.Background())
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("second Serve = %v, want ErrAlreadyRunning", err)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("second Serve took %v — must refuse immediately, not block", elapsed)
	}

	// The first daemon's socket survived the second start attempt.
	if err := socketGetState(home); err != nil {
		t.Fatalf("first daemon lost its socket to the second start: %v", err)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("first daemon exited with error: %v", err)
	}
}

// TestHelperServeDaemon is not a test: it is the child process body for the
// concurrent cold-start race below. It mirrors the CLI's exit-code contract —
// ErrAlreadyRunning exits 0, real errors exit 1.
func TestHelperServeDaemon(t *testing.T) {
	home := os.Getenv("LLMPILOT_HELPER_SERVE_HOME")
	if home == "" {
		t.Skip("helper process body")
	}
	d := &Daemon{Store: store.At(home), PollInterval: time.Hour}
	err := d.Serve(context.Background()) // killed by the parent if it wins
	if errors.Is(err, ErrAlreadyRunning) {
		fmt.Println("daemon already running — nothing to do")
		os.Exit(0)
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

// TestConcurrentColdStartsExactlyOneBinds races N real daemon processes from
// cold against one home: exactly one must take the flock and serve; the rest
// must exit 0 without disturbing it. A probe cannot serialize this — only the
// lock can.
func TestConcurrentColdStartsExactlyOneBinds(t *testing.T) {
	home := shortLockHome(t)
	const n = 6
	procs := make([]*exec.Cmd, 0, n)
	for i := 0; i < n; i++ {
		cmd := exec.Command(os.Args[0], "-test.run=TestHelperServeDaemon$", "-test.v")
		cmd.Env = append(os.Environ(),
			"LLMPILOT_HELPER_SERVE_HOME="+home,
			"LLMPILOT_TEST=1",
		)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		procs = append(procs, cmd)
	}

	waitPortFile(t, home)
	if err := socketGetState(home); err != nil {
		t.Fatalf("winner not serving: %v", err)
	}

	// Exactly one process holds the flock: our own attempt must fail now.
	lf, err := os.OpenFile(LockFilePath(home), os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lf.Close() //nolint:errcheck // test
	if flockErr := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); flockErr == nil {
		t.Fatal("flock acquired while a daemon should hold it")
	}

	// n-1 losers exit 0 promptly; one winner keeps serving until killed.
	exited := 0
	winner := -1
	deadline := time.Now().Add(15 * time.Second)
	states := make([]*os.ProcessState, n)
	for time.Now().Before(deadline) && exited < n-1 {
		exited = 0
		for i, p := range procs {
			if states[i] != nil {
				exited++
				continue
			}
			var ws syscall.WaitStatus
			pid, _ := syscall.Wait4(p.Process.Pid, &ws, syscall.WNOHANG, nil)
			if pid == p.Process.Pid {
				if !ws.Exited() || ws.ExitStatus() != 0 {
					t.Fatalf("loser %d exited %d, want 0", i, ws.ExitStatus())
				}
				states[i] = &os.ProcessState{}
				exited++
			} else {
				winner = i
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if exited != n-1 {
		t.Fatalf("%d processes exited, want %d losers", exited, n-1)
	}
	if winner < 0 {
		t.Fatal("no winner still running")
	}
	t.Logf("concurrent cold start: 1 winner serving, %d losers exited 0", exited)

	// Kill the winner: the kernel drops the flock with it — no stale window.
	if err := procs[winner].Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	_ = procs[winner].Wait()
	lockFreeBy := time.Now().Add(2 * time.Second)
	for syscall.Flock(int(lf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		if time.Now().After(lockFreeBy) {
			t.Fatal("flock not released after winner death")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.HasPrefix(filepath.Base(LockFilePath(home)), "daemon.lock") {
		t.Fatal("lock path drifted")
	}
}
