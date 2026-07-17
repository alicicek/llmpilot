package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

// StatuslineOptions carries everything Statusline needs; no globals so tests
// and benchmarks drive it directly. The engine behind this lives in
// internal/statusline; the zero-config render is byte-identical to the
// classic line.
type StatuslineOptions struct {
	Store   *store.Store
	Dir     claudecfg.Dir // the terminal's config dir ($CLAUDE_CONFIG_DIR-aware)
	Stdin   []byte        // Claude Code's statusline JSON, possibly empty
	Privacy bool          // alias mode: drop the email from the head
	Color   bool          // optional ANSI; callers resolve NO_COLOR/dumb terminals
	Now     time.Time
	Loc     *time.Location

	// Config drives the segments engine; zero value = statusline.Default()
	// (the classic line). The statusline command loads statusline.json here.
	Config statusline.Config
	// Width enables the flex collapse (0 = unknown, no collapse).
	Width int
	// Tier overrides the two-state Color mapping when set (config/env aware
	// callers); TierPlain is the zero value, so Color still governs when unset.
	Tier statusline.Tier
	// History/Exec/DaemonUp wire the daemon-backed and custom segments; all
	// optional (segments degrade to hidden).
	History  statusline.HistoryFn
	Exec     statusline.ExecFn
	DaemonUp func() bool
	// KeepExec runs the kept coexist statusline command (Config.Keep) with a
	// longer budget than segment commands. nil disables coexist output.
	KeepExec statusline.ExecFn
}

// Statusline renders the one-line readout, e.g.
//
//	[acct 2/4 | a@example.dev] 5h:23%(14:32) wk:41% F:67%(Sun)
//
// It never fails: every missing piece degrades to an honest, shorter line.
func Statusline(o StatuslineOptions) string {
	cfg := o.Config
	if len(cfg.Segments) == 0 {
		cfg = statusline.Default()
	}
	tier := o.Tier
	if tier == statusline.TierPlain {
		if o.Color {
			tier = statusline.Tier16
		} else {
			tier = statusline.TierPlain
		}
	}
	ctx := &statusline.Ctx{
		Now: o.Now, Loc: o.Loc, Tier: tier, Width: o.Width,
		In: statusline.ParsePayload(o.Stdin), Store: o.Store, Dir: o.Dir,
		Privacy: o.Privacy,
		History: o.History, Exec: o.Exec, DaemonUp: o.DaemonUp,
	}
	return statusline.Render(cfg, ctx)
}

// StatuslineOutput is the full stdout for the statusLine hook: when the
// config KEEPS a pre-existing statusline (coexist install), that command's
// output — colors, multiple lines, all of it — renders first, verbatim, and
// the llmpilot line prints below it. Claude Code renders every line.
func StatuslineOutput(o StatuslineOptions) string {
	var b strings.Builder
	if k := o.Config.Keep; k != nil && k.Command != "" && o.KeepExec != nil {
		out, err := o.KeepExec(k.Command)
		kept := strings.TrimRight(out, "\n")
		switch {
		case err != nil:
			// Their line vanishing silently would read as breakage — say so.
			b.WriteString("(kept statusline failed — llmpilot statusline uninstall restores it alone)\n")
		case kept != "":
			b.WriteString(kept)
			b.WriteString("\n")
		}
	}
	b.WriteString(Statusline(o))
	return b.String()
}

// statuslineNetTimeout bounds every daemon touch from the statusline path:
// Claude Code re-runs the line constantly and budgets ~300ms — a dead daemon
// must cost milliseconds, not the budget.
const statuslineNetTimeout = 30 * time.Millisecond

// socketClient returns an http.Client pinned to the daemon's unix socket.
func socketClient(home string) *http.Client {
	sock := daemon.SocketPath(home)
	return &http.Client{
		Timeout: statuslineNetTimeout,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "unix", sock)
			},
		},
	}
}

// StatuslineHistory returns a HistoryFn backed by GET /v1/history over the
// daemon socket, with the statusline's tight timeout. Failures are empty
// history — the burn segment hides, honestly.
func StatuslineHistory(home string) statusline.HistoryFn {
	return func(accountID, kind, scope string) []statusline.Sample {
		hc := socketClient(home)
		endpoint := "http://llmpilot/v1/history?account_id=" + url.QueryEscape(accountID) +
			"&kind=" + url.QueryEscape(kind) + "&scope=" + url.QueryEscape(scope)
		resp, err := hc.Get(endpoint)
		if err != nil {
			return nil
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			return nil
		}
		var doc struct {
			Samples []daemon.HistorySample `json:"samples"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
			return nil
		}
		out := make([]statusline.Sample, len(doc.Samples))
		for i, s := range doc.Samples {
			out[i] = statusline.Sample{At: s.At, Percent: s.Percent}
		}
		return out
	}
}

// StatuslineDaemonUp reports whether the daemon answers on its socket within
// the statusline budget.
func StatuslineDaemonUp(home string) func() bool {
	return func() bool {
		conn, err := net.DialTimeout("unix", daemon.SocketPath(home), statuslineNetTimeout)
		if err != nil {
			return false
		}
		_ = conn.Close()
		return true
	}
}

// StatuslineExec runs a command-segment or kept-statusline command with a
// hard budget, forwarding Claude Code's stdin JSON — a kept statusline (or a
// composed one, ccstatusline-style) needs the same session data we got.
func StatuslineExec(timeout time.Duration, stdin []byte) statusline.ExecFn {
	return func(command string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, "/bin/sh", "-c", command)
		cmd.Stdin = bytes.NewReader(stdin)
		out, err := cmd.Output()
		if err != nil {
			return "", err
		}
		return string(out), nil
	}
}
