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
	"sync/atomic"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/doctor"
)

// ErrDaemonDown means no daemon answered on the socket or the loopback port.
// Callers degrade to cached data and tell the user how to start one.
var ErrDaemonDown = errors.New("daemon not running — llmpilot daemon install (or foreground: llmpilot daemon run)")

// ErrDaemonAnswered marks the OTHER failure: something answered where the
// daemon listens, but not with the document that was asked for. Both shapes
// count — a non-200, and a 200 whose body will not decode, which is what an
// OLDER daemon produces for a route it has never heard of (the embedded
// cockpit's catch-all serves index.html with 200). It WRAPS ErrDaemonDown so
// every existing caller keeps degrading exactly as before; callers that would
// otherwise tell the user to start a daemon they are already running check for
// this one first.
var ErrDaemonAnswered = errors.New("something answered where the daemon listens, but not with what was asked for")

// ErrDaemonSlow is the OTHER live-daemon shape, and it is a different
// diagnosis: the connection was accepted and nothing came back in time. The
// health sweep is the most expensive route the daemon serves, so a busy daemon
// really can produce this — and the remedy for busy is NOT the remedy for
// stale. It wraps ErrDaemonAnswered (something is listening) and therefore
// ErrDaemonDown (no usable answer), so every existing caller is unaffected.
var ErrDaemonSlow = errors.New("something accepted the connection but did not answer in time")

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
	var st daemon.State
	if err := c.fetch(ctx, "/v1/state", &st); err != nil {
		return nil, err
	}
	return &st, nil
}

// Doctor fetches GET /v1/doctor — the daemon's read-only health sweep. Same
// transport rules as State, same ErrDaemonDown: the caller then runs the sweep
// locally and reports every daemon-only check as NOT CHECKED.
func (c *Client) Doctor(ctx context.Context) (*doctor.Report, error) {
	var rep doctor.Report
	if err := c.fetch(ctx, "/v1/doctor", &rep); err != nil {
		return nil, err
	}
	if len(rep.Checks) == 0 {
		// A sweep always runs a fixed list of checks, so a document with none
		// is not a health report — it is JSON from something else. Rendering
		// it would print "0 of 0 checks could not run", which says nothing
		// about the fleet while looking like an answer.
		return nil, down(observation{reason: "it answered without a single health check", rank: 2})
	}
	return &rep, nil
}

// fetch performs one GET against the daemon: the unix socket first, the
// persisted 127.0.0.1 port second. Any transport failure is ErrDaemonDown.
func (c *Client) fetch(ctx context.Context, path string, dst any) error {
	// The strongest evidence seen across both transports wins, by RANK and not
	// by transport order: an answer we could not use outranks a connection that
	// opened and went quiet, which outranks silence. First-wins would let the
	// socket's weaker evidence mask the port's stronger evidence purely because
	// the socket is tried first.
	best := observation{}
	note := func(o observation) {
		switch {
		case o.rank > best.rank:
			best = o
		case o.rank == best.rank && o.slow && !best.slow:
			// A tie between "did not answer in time" and "hung up" resolves to
			// the timeout: its remedy is "wait a moment", and being wrong that
			// way costs a re-run, while being wrong the other way hands a hard
			// kill to a daemon that is merely busy.
			best = o
		}
	}
	if sock := daemon.SocketPath(c.Home); fileExists(sock) {
		var dialed atomic.Bool
		hc := &http.Client{
			Timeout: c.timeout(),
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					var d net.Dialer
					conn, err := d.DialContext(ctx, "unix", sock)
					if err == nil {
						dialed.Store(true)
					}
					return conn, err
				},
			},
		}
		// Host is a placeholder; the transport always dials the socket.
		err := c.get(ctx, hc, "http://llmpilot"+path, dst)
		if err == nil {
			return nil
		}
		note(answeredReason(err, dialed.Load()))
	}
	raw, err := os.ReadFile(daemon.PortFilePath(c.Home))
	if err != nil {
		return down(best)
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || port <= 0 || port > 65535 {
		return down(best)
	}
	var dialed atomic.Bool
	hc := &http.Client{
		Timeout: c.timeout(),
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				var d net.Dialer
				conn, err := d.DialContext(ctx, network, addr)
				if err == nil {
					dialed.Store(true)
				}
				return conn, err
			},
		},
	}
	if err := c.get(ctx, hc, "http://127.0.0.1:"+strconv.Itoa(port)+path, dst); err != nil {
		note(answeredReason(err, dialed.Load()))
		return down(best)
	}
	return nil
}

// answeredReason turns one failed attempt into evidence about what is there.
// A refused connection is silence. A connection that OPENED and then timed out,
// closed, or replied with something unusable is not — and telling that user to
// start a daemon they may already be running is the same lie as a false
// all-clear, pointed the other way. The health sweep is also the most expensive
// route the daemon serves, so "did not answer in time" is a shape a live daemon
// really can produce.
func answeredReason(err error, dialed bool) observation {
	// Timeout FIRST: a deadline can fire before the first byte (a transport
	// error) or midway through the body (a read error wrapped in an answer).
	// Both are the same thing — a daemon that needed longer — and neither may
	// be diagnosed as a broken one, because the remedy for broken is a kill.
	if dialed && (os.IsTimeout(err) || errors.Is(err, context.DeadlineExceeded)) {
		return observation{reason: "it accepted the connection but did not answer in time", rank: 1, slow: true}
	}
	if replied := (*answeredError)(nil); errors.As(err, &replied) {
		return observation{reason: replied.Error(), rank: 2}
	}
	if !dialed {
		return observation{} // nothing accepted a connection: genuinely silent
	}
	return observation{reason: "it accepted the connection but sent no usable answer", rank: 1}
}

// observation is what one attempt proved about whatever is (or is not) there.
// rank orders the evidence: 0 silence, 1 accepted-but-silent, 2 answered.
type observation struct {
	reason string
	rank   int
	slow   bool
}

// down reports the right flavour of unreachable — and they are three different
// diagnoses with three different remedies, so the distinction survives all the
// way to the copy the user reads.
func down(o observation) error {
	if o.rank == 0 {
		return ErrDaemonDown
	}
	// The observation travels as a VALUE in the chain, not flattened into a
	// format string: a caller that renders "what llmpilot saw" must get what
	// llmpilot actually saw, and a %s payload no errors.As can reach is a dead
	// payload that quietly becomes one canned sentence for every shape.
	seen := &answeredError{detail: o.reason}
	if o.slow {
		// Chained all the way down to ErrDaemonDown: every caller that
		// degrades on "no usable answer" must keep degrading, or a busy daemon
		// turns a diagnostic into a hard error (caught by its own test).
		return fmt.Errorf("%w: %w: %w: %w", ErrDaemonSlow, seen, ErrDaemonAnswered, ErrDaemonDown)
	}
	return fmt.Errorf("%w: %w: %w", seen, ErrDaemonAnswered, ErrDaemonDown)
}

// AnsweredReason extracts what llmpilot actually OBSERVED from one of these
// errors, so a caller renders the shape it saw instead of guessing one.
// Empty for a plain ErrDaemonDown.
func AnsweredReason(err error) string {
	var o *answeredError
	if errors.As(err, &o) && o.detail != "" {
		return o.detail
	}
	if errors.Is(err, ErrDaemonSlow) {
		return "it accepted the connection but did not answer in time"
	}
	if errors.Is(err, ErrDaemonAnswered) {
		return "it answered with something llmpilot could not use"
	}
	return ""
}

// answeredError is a reply from something listening where the daemon listens
// that is not the document we asked for — distinct from a transport failure,
// where nothing replied at all.
type answeredError struct {
	detail string
	// cause is kept so a caller can still ask what really happened — a
	// deadline that fires mid-body reaches us as a read failure, and erasing
	// it would classify a slow daemon as a broken one.
	cause error
}

func (e *answeredError) Error() string { return e.detail }
func (e *answeredError) Unwrap() error { return e.cause }

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
	var st daemon.State
	if err := c.get(ctx, &http.Client{Timeout: c.timeout()}, base+"/v1/state", &st); err != nil {
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

func (c *Client) get(ctx context.Context, hc *http.Client, url string, dst any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return &answeredError{detail: fmt.Sprintf("it answered %d", resp.StatusCode)}
	}
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		// A daemon older than this binary has no such route, so the embedded
		// cockpit's catch-all answers 200 with index.html. (An API-only daemon
		// — WebFS nil — 404s instead, which the branch above catches.)
		return &answeredError{
			detail: "it answered with something that is not the document llmpilot asked for",
			cause:  err,
		}
	}
	return nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
