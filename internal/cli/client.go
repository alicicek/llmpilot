// Package cli is the terminal surface's logic: the daemon API client, fleet
// rendering, the statusline, and config-dir detection for init. Commands in
// cmd/llmpilot stay thin wrappers over this package so every behavior is
// testable without a TTY.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
)

// ErrDaemonDown means no daemon answered on the socket or the loopback port.
// Callers degrade to cached data and tell the user how to start one.
var ErrDaemonDown = errors.New("daemon not running — llmpilot daemon install (or foreground: llmpilot daemon run)")

// Client talks to the daemon API for one llmpilot home.
type Client struct {
	Home    string
	Timeout time.Duration // per-attempt; default 700ms
}

func (c *Client) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 700 * time.Millisecond
}

// State fetches GET /v1/state, trying the unix socket first and the persisted
// 127.0.0.1 port second. Any transport failure is ErrDaemonDown.
func (c *Client) State(ctx context.Context) (*daemon.State, error) {
	if sock := daemon.SocketPath(c.Home); fileExists(sock) {
		hc := &http.Client{
			Timeout: c.timeout(),
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					return d.DialContext(ctx, "unix", sock)
				},
			},
		}
		// Host is a placeholder; the transport always dials the socket.
		if st, err := c.get(ctx, hc, "http://llmpilot/v1/state"); err == nil {
			return st, nil
		}
	}
	raw, err := os.ReadFile(daemon.PortFilePath(c.Home))
	if err != nil {
		return nil, ErrDaemonDown
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || port <= 0 || port > 65535 {
		return nil, ErrDaemonDown
	}
	st, err := c.get(ctx, &http.Client{Timeout: c.timeout()},
		"http://127.0.0.1:"+strconv.Itoa(port)+"/v1/state")
	if err != nil {
		return nil, ErrDaemonDown
	}
	return st, nil
}

// LoopbackURL returns the daemon's browser-reachable base URL, verified by a
// live GET /v1/state on the loopback port (the unix socket is no use to a
// browser). ErrDaemonDown when nothing answers.
func (c *Client) LoopbackURL(ctx context.Context) (string, error) {
	raw, err := os.ReadFile(daemon.PortFilePath(c.Home))
	if err != nil {
		return "", ErrDaemonDown
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || port <= 0 || port > 65535 {
		return "", ErrDaemonDown
	}
	base := "http://127.0.0.1:" + strconv.Itoa(port)
	if _, err := c.get(ctx, &http.Client{Timeout: c.timeout()}, base+"/v1/state"); err != nil {
		return "", ErrDaemonDown
	}
	return base, nil
}

// CockpitURL is LoopbackURL plus the install token as a URL fragment — the
// cockpit needs it for license reveal/cancel, and a fragment never rides a
// request or Referer. A missing token file degrades to the bare URL: the
// cockpit still renders, license actions answer 401 with reopen copy.
func (c *Client) CockpitURL(ctx context.Context) (string, error) {
	base, err := c.LoopbackURL(ctx)
	if err != nil {
		return "", err
	}
	raw, err := os.ReadFile(daemon.TokenFilePath(c.Home))
	if err != nil {
		return base, nil
	}
	tok := strings.TrimSpace(string(raw))
	if tok == "" {
		return base, nil
	}
	return base + "/#token=" + tok, nil
}

func (c *Client) get(ctx context.Context, hc *http.Client, url string) (*daemon.State, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("daemon answered %d", resp.StatusCode)
	}
	var st daemon.State
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		return nil, err
	}
	return &st, nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
