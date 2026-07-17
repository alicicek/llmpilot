package daemon

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

var slNow = time.Date(2026, 7, 8, 12, 4, 0, 0, time.UTC)

// slFixture builds a daemon over a fleet store whose active account has a
// cached snapshot — the same data a binary render would read.
func slFixture(t *testing.T) (*Daemon, *store.Store) {
	t.Helper()
	st := store.At(t.TempDir())
	accs := []store.Account{
		{ID: "acct-1", Label: "one", Email: "one@example.dev"},
		{ID: "acct-2", Label: "two", Email: "a@example.dev"},
	}
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	sessionReset := time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC)
	weeklyReset := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-2", AsOf: slNow.Add(-time.Minute),
		Buckets: []store.Bucket{
			{Kind: "session", Percent: 23, Severity: "normal", ResetsAt: &sessionReset},
			{Kind: "weekly_all", Percent: 41, Severity: "normal", ResetsAt: &weeklyReset},
		},
	}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{
		Store:  st,
		Active: func(context.Context) string { return "acct-2" },
		NowFn:  func() time.Time { return slNow },
	}
	return d, st
}

func getJSON(t *testing.T, url string, into any) *http.Response {
	t.Helper()
	resp, err := http.Get(url) //nolint:gosec,noctx // test URL from httptest
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)
	if into != nil && resp.StatusCode == http.StatusOK {
		if err := json.Unmarshal(body, into); err != nil {
			t.Fatalf("decode %s: %v (%s)", url, err, body)
		}
	}
	return resp
}

// TestStatuslinePreviewParity: the daemon preview byte-equals the binary
// render path (cli.Statusline is a thin wrapper over the same call) for the
// same config + fixtures + clock — preview==production.
func TestStatuslinePreviewParity(t *testing.T) {
	d, st := slFixture(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	for _, preset := range statusline.Presets() {
		cfgJSON, err := json.Marshal(preset.Config)
		if err != nil {
			t.Fatal(err)
		}
		for _, tier := range []string{"plain", "16", "256", "truecolor"} {
			var doc struct{ Line, Plain string }
			resp := getJSON(t, srv.URL+"/v1/statusline/preview?width=120&tier="+tier+
				"&config="+url.QueryEscape(string(cfgJSON)), &doc)
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("preset %s tier %s: HTTP %d", preset.ID, tier, resp.StatusCode)
			}

			// The binary path: same renderer, same store, same sample stdin,
			// same clock — constructed the way `llmpilot statusline` does.
			binary := statusline.Render(preset.Config, &statusline.Ctx{
				Now: slNow, Loc: time.Local, Tier: statusline.TierFromString(tier), Width: 120,
				In:       statusline.ParsePayload(statusline.SamplePayload()),
				Store:    st,
				ActiveID: "acct-2",
				History:  func(_, _, _ string) []statusline.Sample { return nil },
				DaemonUp: func() bool { return true },
			})
			if doc.Line != binary {
				t.Errorf("preset %s tier %s: preview %q != binary %q", preset.ID, tier, doc.Line, binary)
			}
			if tier == "plain" && strings.Contains(doc.Plain, "\x1b[") {
				t.Errorf("plain preview leaked ANSI: %q", doc.Plain)
			}
		}
	}
}

func TestStatuslinePreviewRejectsJunk(t *testing.T) {
	d, _ := slFixture(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp := getJSON(t, srv.URL+"/v1/statusline/preview?config="+url.QueryEscape(`{"segments":[{"id":"nope"}]}`), nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("unknown segment in draft: HTTP %d, want 400", resp.StatusCode)
	}
	if resp := getJSON(t, srv.URL+"/v1/statusline/preview?width=badnum", nil); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("bad width: HTTP %d, want 400", resp.StatusCode)
	}
}

// TestStatuslinePreviewNeverExecutesCommands: a command segment in a draft
// config previews as a placeholder — a GET must not reach the shell.
func TestStatuslinePreviewNeverExecutesCommands(t *testing.T) {
	d, _ := slFixture(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	marker := t.TempDir() + "/pwned"
	cfg := fmt.Sprintf(`{"version":1,"segments":[{"id":"command","options":{"command":"touch %s && echo ran"}}]}`, marker)
	var doc struct{ Line string }
	resp := getJSON(t, srv.URL+"/v1/statusline/preview?config="+url.QueryEscape(cfg), &doc)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("HTTP %d", resp.StatusCode)
	}
	if strings.Contains(doc.Line, "ran") {
		t.Fatalf("preview executed the command: %q", doc.Line)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("preview touched the filesystem via a config-supplied command")
	}
}

func TestStatuslineConfigRoundTripOverAPI(t *testing.T) {
	d, st := slFixture(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	body := `{"version":1,"preset":"dev","segments":[{"id":"dir"},{"id":"model"},{"id":"usage"}]}`
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPut,
		srv.URL+"/v1/statusline/config", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("PUT: HTTP %d", resp.StatusCode)
	}

	cfg, err := statusline.LoadConfig(st.Home())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Preset != "dev" || len(cfg.Segments) != 3 {
		t.Errorf("saved config wrong: %+v", cfg)
	}

	var got struct {
		Config statusline.Config `json:"config"`
	}
	getJSON(t, srv.URL+"/v1/statusline/config", &got)
	if got.Config.Preset != "dev" {
		t.Errorf("GET config = %+v", got.Config)
	}

	// junk must 400 and leave disk untouched
	req2, _ := http.NewRequestWithContext(context.Background(), http.MethodPut,
		srv.URL+"/v1/statusline/config", strings.NewReader(`{"segments":[{"id":"junk"}]}`))
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusBadRequest {
		t.Errorf("junk PUT: HTTP %d, want 400", resp2.StatusCode)
	}
	after, _ := statusline.LoadConfig(st.Home())
	if after.Preset != "dev" {
		t.Errorf("junk PUT clobbered the saved config: %+v", after)
	}
}

func TestStatuslineSegmentsServesRegistryAndPresets(t *testing.T) {
	d, _ := slFixture(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	var doc struct {
		Segments []statusline.SegmentSpec `json:"segments"`
		Presets  []statusline.Preset      `json:"presets"`
	}
	getJSON(t, srv.URL+"/v1/statusline/segments", &doc)
	if len(doc.Segments) < 10 {
		t.Errorf("registry looks truncated: %d segments", len(doc.Segments))
	}
	if len(doc.Presets) != 3 {
		t.Errorf("want 3 presets, got %d", len(doc.Presets))
	}
	ids := map[string]bool{}
	for _, s := range doc.Segments {
		ids[s.ID] = true
	}
	for _, want := range []string{"account", "usage", "fleet", "burn", "rotation", "autopilot", "dir"} {
		if !ids[want] {
			t.Errorf("segment %q missing from the served registry", want)
		}
	}
}
