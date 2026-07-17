package daemon

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/alicicek/llmpilot/internal/statusline"
)

// The statusline endpoints exist for ONE property: the cockpit editor's live
// preview runs the SAME Go renderer as the binary — never a JS mock
// (preview==production, docs/research/CCSTATUSLINE-TEARDOWN.md).

// now is the daemon's clock (NowFn override or time.Now): the statusline
// preview parity test and the refresh loop's expiry/backoff math share it.
func (d *Daemon) now() time.Time {
	if d.NowFn != nil {
		return d.NowFn()
	}
	return time.Now()
}

// previewCtx assembles the render context from the daemon's own live data.
// Session-scoped stdin fields render from statusline.SamplePayload (the
// daemon has no live session); usage/fleet segments render the real store.
// Exec stays nil BY DESIGN: a GET with a config in the query must never be a
// path into the shell — command segments preview as a placeholder.
func (d *Daemon) previewCtx(r *http.Request, tier statusline.Tier, width int) *statusline.Ctx {
	ctx := &statusline.Ctx{
		Now: d.now(), Loc: time.Local, Tier: tier, Width: width,
		In:    statusline.ParsePayload(statusline.SamplePayload()),
		Store: d.Store,
		History: func(accountID, kind, scope string) []statusline.Sample {
			samples := d.History(accountID, kind, scope)
			out := make([]statusline.Sample, len(samples))
			for i, s := range samples {
				out[i] = statusline.Sample{At: s.At, Percent: s.Percent}
			}
			return out
		},
		DaemonUp: func() bool { return true },
	}
	if d.Active != nil {
		ctx.ActiveID = d.Active(r.Context())
	}
	return ctx
}

func (d *Daemon) handleStatuslinePreview(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	cfg, err := statusline.LoadConfig(d.Store.Home())
	if err != nil {
		d.Log.Warn("statusline config unreadable, previewing defaults", "err", err)
	}
	if raw := q.Get("config"); raw != "" {
		var draft statusline.Config
		if err := json.Unmarshal([]byte(raw), &draft); err != nil {
			httpError(w, http.StatusBadRequest, err)
			return
		}
		if err := statusline.Validate(draft); err != nil {
			httpError(w, http.StatusBadRequest, err)
			return
		}
		cfg = draft
	}
	width := 0
	if v := q.Get("width"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n > 1000 {
			httpError(w, http.StatusBadRequest, errors.New("width must be an integer in [0,1000]"))
			return
		}
		width = n
	}
	tier := statusline.Tier16
	if v := q.Get("tier"); v != "" {
		tier = statusline.TierFromString(v)
	}

	line := statusline.Render(cfg, d.previewCtx(r, tier, width))
	plain := statusline.Render(cfg, d.previewCtx(r, statusline.TierPlain, width))
	writeJSON(w, http.StatusOK, map[string]any{
		"line":  line,
		"plain": plain,
		"width": width,
		"tier":  tier.String(),
	})
}

func (d *Daemon) handleStatuslineConfigGet(w http.ResponseWriter, _ *http.Request) {
	cfg, err := statusline.LoadConfig(d.Store.Home())
	note := ""
	if err != nil {
		// Never-clobber honesty: the editor sees defaults AND why.
		note = err.Error()
	}
	writeJSON(w, http.StatusOK, map[string]any{"config": cfg, "load_error": note})
}

func (d *Daemon) handleStatuslineConfigPut(w http.ResponseWriter, r *http.Request) {
	if !requireJSON(w, r) {
		return
	}
	var cfg statusline.Config
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	if err := statusline.SaveConfig(d.Store.Home(), cfg); err != nil {
		httpError(w, http.StatusBadRequest, err)
		return
	}
	saved, _ := statusline.LoadConfig(d.Store.Home())
	writeJSON(w, http.StatusOK, map[string]any{"config": saved})
}

// handleStatuslineSegments serves the registry and presets — the ONE
// registry drives the editor's palette (wave anchor).
func (d *Daemon) handleStatuslineSegments(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"segments": statusline.Specs(),
		"presets":  statusline.Presets(),
	})
}
