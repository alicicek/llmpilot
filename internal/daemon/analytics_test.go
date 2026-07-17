package daemon

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

func writeTranscript(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assistantLine(model, ts, msgID, reqID string, in, out int64) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":"%s","requestId":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}`,
		ts, reqID, msgID, model, in, out)
}

type analyticsResp struct {
	Cells []struct {
		AccountID string `json:"account_id"`
		Project   string `json:"project"`
		Model     string `json:"model"`
		Day       string `json:"day"`
		Messages  int64  `json:"messages"`
		Tokens    struct {
			Input  int64 `json:"input"`
			Output int64 `json:"output"`
		} `json:"tokens"`
	} `json:"cells"`
	HourWeekday [7][24]int64 `json:"hour_weekday"`
	FilesTotal  int          `json:"files_total"`
	FilesParsed int          `json:"files_parsed"`
	FilesReused int          `json:"files_reused"`
}

func getAnalytics(t *testing.T, srv *httptest.Server, query string) (analyticsResp, int) {
	t.Helper()
	resp, err := http.Get(srv.URL + "/v1/analytics" + query)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var out analyticsResp
	if resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			t.Fatal(err)
		}
	}
	return out, resp.StatusCode
}

func TestAnalyticsBadDaysParam(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/analytics?days=nope")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestAnalyticsEmptyRegistryIsEmptyArrays(t *testing.T) {
	st := store.At(t.TempDir()) // no accounts at all
	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	out, code := getAnalytics(t, srv, "")
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if out.Cells == nil || len(out.Cells) != 0 {
		t.Fatalf("cells = %+v, want empty non-nil", out.Cells)
	}
}

// TestAnalyticsWalksOwnConfigDirAndFiltersByDay proves per-account
// attribution, the project label, and the day-range clamp/filter.
func TestAnalyticsWalksOwnConfigDirAndFiltersByDay(t *testing.T) {
	llHome := t.TempDir()
	st := store.At(llHome)
	cfgDir := t.TempDir()
	if err := st.SaveAccounts([]store.Account{{ID: "acct-a", Label: "a", Email: "a@x.dev", ConfigDir: cfgDir}}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC()
	recentDay := now.Format("2006-01-02")
	oldDay := now.AddDate(0, 0, -100).Format("2006-01-02")

	transcript := assistantLine("claude-fable-5", recentDay+"T09:00:00.000Z", "m1", "r1", 100, 10) + "\n" +
		assistantLine("claude-fable-5", oldDay+"T09:00:00.000Z", "m2", "r2", 200, 20) + "\n"
	// Encoded project dir: "-Users-x-repo" decodes to basename "repo".
	writeTranscript(t, filepath.Join(cfgDir, "projects", "-Users-x-repo", "s.jsonl"), transcript)

	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	// Default 30-day window: only the recent-day cell should appear.
	out, code := getAnalytics(t, srv, "")
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if len(out.Cells) != 1 {
		t.Fatalf("cells = %+v, want exactly the recent-day cell", out.Cells)
	}
	c := out.Cells[0]
	if c.AccountID != "acct-a" || c.Project != "repo" || c.Day != recentDay || c.Messages != 1 || c.Tokens.Input != 100 {
		t.Fatalf("cell = %+v", c)
	}
	if out.FilesTotal != 1 || out.FilesParsed != 1 {
		t.Fatalf("file counts = total=%d parsed=%d", out.FilesTotal, out.FilesParsed)
	}

	// A wide enough window picks up both days.
	wide, code := getAnalytics(t, srv, "?days=200")
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if len(wide.Cells) != 2 {
		t.Fatalf("wide-window cells = %+v, want 2", wide.Cells)
	}

	// days<1 clamps to 1 (still returns 200, not an error).
	_, code = getAnalytics(t, srv, "?days=0")
	if code != http.StatusOK {
		t.Fatalf("days=0 status = %d, want 200 (clamped)", code)
	}
	// days>730 clamps to 730 (still 200).
	_, code = getAnalytics(t, srv, "?days=99999")
	if code != http.StatusOK {
		t.Fatalf("days=99999 status = %d, want 200 (clamped)", code)
	}
}

// TestAnalyticsSharedDirWalkedOnce proves accounts with an empty ConfigDir
// are attributed account_id:"" and the shared global dir is walked exactly
// once even with two such accounts.
func TestAnalyticsSharedDirWalkedOnce(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	globalDir := filepath.Join(home, ".claude")

	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{
		{ID: "shared-1", Label: "s1", Email: "s1@x.dev"}, // empty ConfigDir
		{ID: "shared-2", Label: "s2", Email: "s2@x.dev"}, // empty ConfigDir
	}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Format("2006-01-02")
	transcript := assistantLine("claude-fable-5", now+"T09:00:00.000Z", "m1", "r1", 100, 10) + "\n"
	writeTranscript(t, filepath.Join(globalDir, "projects", "proj", "s.jsonl"), transcript)

	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	out, code := getAnalytics(t, srv, "")
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if len(out.Cells) != 1 {
		t.Fatalf("cells = %+v, want exactly 1 (shared dir walked once)", out.Cells)
	}
	if out.Cells[0].AccountID != "" {
		t.Fatalf("shared cell account_id = %q, want empty", out.Cells[0].AccountID)
	}
	if out.FilesTotal != 1 {
		t.Fatalf("shared dir walked more than once: files_total = %d", out.FilesTotal)
	}
}

// TestAnalyticsHourWeekday proves the heatmap lands entries in the right
// (weekday, hour) slot and respects the day-range filter.
func TestAnalyticsHourWeekday(t *testing.T) {
	st := store.At(t.TempDir())
	cfgDir := t.TempDir()
	if err := st.SaveAccounts([]store.Account{{ID: "acct-a", Label: "a", Email: "a@x.dev", ConfigDir: cfgDir}}); err != nil {
		t.Fatal(err)
	}

	const ts = "2026-07-06T09:15:00.000Z"
	lt, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		t.Fatal(err)
	}
	local := lt.Local()

	transcript := assistantLine("claude-fable-5", ts, "m1", "r1", 100, 20) + "\n"
	writeTranscript(t, filepath.Join(cfgDir, "projects", "p", "s.jsonl"), transcript)

	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	out, code := getAnalytics(t, srv, "?days=3650")
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if out.HourWeekday[int(local.Weekday())][local.Hour()] != 120 {
		t.Fatalf("hour_weekday[%v][%d] = %d, want 120: %v",
			local.Weekday(), local.Hour(), out.HourWeekday[int(local.Weekday())][local.Hour()], out.HourWeekday)
	}
}
