package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

// now is fixed so reset rendering is deterministic: 2026-07-08 was a
// Wednesday, 2026-07-12 a Sunday.
var now = time.Date(2026, 7, 8, 12, 4, 0, 0, time.UTC)

func fakeConfigDir(t *testing.T, email string) claudecfg.Dir {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	writeOAuthJSON(t, filepath.Join(path, ".claude.json"), email)
	return claudecfg.DirAt(path)
}

func writeOAuthJSON(t *testing.T, path, email string) {
	t.Helper()
	doc := map[string]any{"oauthAccount": map[string]any{"emailAddress": email}}
	data, _ := json.Marshal(doc)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// fleetStore registers four accounts (the matched one second) and returns the
// store plus the matched account's ID.
func fleetStore(t *testing.T, email string) (*store.Store, string) {
	t.Helper()
	st := store.At(t.TempDir())
	accs := []store.Account{
		{ID: "acct-1", Label: "one", Email: "one@example.dev"},
		{ID: "acct-2", Label: "two", Email: email},
		{ID: "acct-3", Label: "three", Email: "three@example.dev"},
		{ID: "acct-4", Label: "four", Email: "four@example.dev"},
	}
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	return st, "acct-2"
}

func proofBuckets() []store.Bucket {
	sessionReset := time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC)
	weeklyReset := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	return []store.Bucket{
		{Kind: "session", Percent: 23, Severity: "normal", ResetsAt: &sessionReset},
		{Kind: "weekly_all", Percent: 41, Severity: "normal", ResetsAt: &weeklyReset},
		{Kind: "weekly_scoped", Scope: "Fable", Percent: 67, Severity: "warning", ResetsAt: &weeklyReset},
	}
}

func saveSnap(t *testing.T, st *store.Store, id string, asOf time.Time, buckets []store.Bucket) {
	t.Helper()
	if err := st.SaveSnapshot(&store.UsageSnapshot{AccountID: id, AsOf: asOf, Buckets: buckets}); err != nil {
		t.Fatal(err)
	}
}

func TestStatuslineFreshCacheMatchesWaveProofLine(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-time.Minute), proofBuckets())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"),
		Now: now, Loc: time.UTC,
	})
	want := "[acct 2/4 | a@example.dev] 5h:23%(14:32) wk:41% F:67%(Sun)"
	if got != want {
		t.Errorf("statusline =\n  %q\nwant\n  %q", got, want)
	}
}

func TestStatuslineFreshButAgingCacheCarriesAgeToken(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-4*time.Minute), proofBuckets())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Now: now, Loc: time.UTC,
	})
	if !strings.HasSuffix(got, " ~4m") {
		t.Errorf("aging cache must carry an age token, got %q", got)
	}
}

func TestStatuslineStaleCacheUsesFloorAndKeepsScopedWithAge(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-48*time.Minute), proofBuckets())
	stdin := fmt.Sprintf(`{"rate_limits":{
		"five_hour":{"used_percentage":24.5,"resets_at":%d},
		"seven_day":{"used_percentage":42,"resets_at":%d}}}`,
		time.Date(2026, 7, 8, 15, 0, 0, 0, time.UTC).Unix(),
		time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC).Unix())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Stdin: []byte(stdin),
		Now: now, Loc: time.UTC,
	})
	want := "[acct 2/4 | a@example.dev] 5h:24.5%(15:00) wk:42% F:67%(Sun) ~48m"
	if got != want {
		t.Errorf("statusline =\n  %q\nwant\n  %q", got, want)
	}
}

func TestStatuslinePartialFloorKeepsUnreplacedCacheWindow(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-48*time.Minute), proofBuckets())
	// The floor carries only five_hour (each window may be independently
	// absent): wk must survive from the stale cache instead of vanishing.
	stdin := fmt.Sprintf(`{"rate_limits":{"five_hour":{"used_percentage":24.5,"resets_at":%d}}}`,
		time.Date(2026, 7, 8, 15, 0, 0, 0, time.UTC).Unix())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Stdin: []byte(stdin),
		Now: now, Loc: time.UTC,
	})
	want := "[acct 2/4 | a@example.dev] 5h:24.5%(15:00) wk:41% F:67%(Sun) ~48m"
	if got != want {
		t.Errorf("statusline =\n  %q\nwant\n  %q", got, want)
	}
}

func TestStatuslineNoCacheFloorOnly(t *testing.T) {
	st, _ := fleetStore(t, "a@example.dev")
	stdin := fmt.Sprintf(`{"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":%d}}}`,
		time.Date(2026, 7, 8, 15, 0, 0, 0, time.UTC).Unix())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Stdin: []byte(stdin),
		Now: now, Loc: time.UTC,
	})
	want := "[acct 2/4 | a@example.dev] 5h:24%(15:00)"
	if got != want {
		t.Errorf("statusline = %q, want %q", got, want)
	}
}

func TestStatuslineNothingAtAllPointsAtDaemonInstall(t *testing.T) {
	st, _ := fleetStore(t, "a@example.dev")
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Now: now, Loc: time.UTC,
	})
	want := "[acct 2/4 | a@example.dev] no usage data — llmpilot daemon install"
	if got != want {
		t.Errorf("statusline = %q, want %q", got, want)
	}
}

func TestStatuslinePrivacyDropsEmail(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-time.Minute), proofBuckets())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Privacy: true,
		Now: now, Loc: time.UTC,
	})
	if !strings.HasPrefix(got, "[acct 2/4] ") || strings.Contains(got, "example.dev") {
		t.Errorf("privacy mode leaked identity: %q", got)
	}
}

func TestStatuslineUnknownTerminalIdentity(t *testing.T) {
	st, _ := fleetStore(t, "a@example.dev")
	dir := claudecfg.DirAt(filepath.Join(t.TempDir(), "never-logged-in"))
	got := Statusline(StatuslineOptions{Store: st, Dir: dir, Now: now, Loc: time.UTC})
	want := "[acct ?/4] no usage data — llmpilot daemon install"
	if got != want {
		t.Errorf("statusline = %q, want %q", got, want)
	}
}

func TestStatuslineGarbageStdinIsIgnored(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-time.Minute), proofBuckets())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Stdin: []byte("{not json"),
		Now: now, Loc: time.UTC,
	})
	if !strings.Contains(got, "5h:23%") {
		t.Errorf("garbage stdin broke rendering: %q", got)
	}
}

// TestStatuslineZeroConfigIsWidthImmune pins a verified fix: the
// zero-config default line is the classic bytes at EVERY terminal width —
// flex collapse never applies to it (Default() sets flex off; width-aware
// collapse is opt-in for customized lines).
func TestStatuslineZeroConfigIsWidthImmune(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-time.Minute), proofBuckets())
	want := "[acct 2/4 | a@example.dev] 5h:23%(14:32) wk:41% F:67%(Sun)"
	for _, width := range []int{0, 60, 80, 120, 200} {
		got := Statusline(StatuslineOptions{
			Store: st, Dir: fakeConfigDir(t, "a@example.dev"),
			Now: now, Loc: time.UTC, Width: width,
			Config: statusline.Default(),
		})
		if got != want {
			t.Errorf("width %d broke the zero-config default line:\n  got  %q\n  want %q", width, got, want)
		}
	}
}

func TestStatuslineColorPaintsWarningAndDimsAge(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-4*time.Minute), proofBuckets())
	got := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Color: true,
		Now: now, Loc: time.UTC,
	})
	if !strings.Contains(got, "\x1b[33mF:67%(Sun)\x1b[0m") {
		t.Errorf("warning bucket not painted: %q", got)
	}
	if !strings.Contains(got, "\x1b[2m~4m\x1b[0m") {
		t.Errorf("age token not dimmed: %q", got)
	}
	plain := Statusline(StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Color: false,
		Now: now, Loc: time.UTC,
	})
	if strings.Contains(plain, "\x1b[") {
		t.Errorf("NO_COLOR output still has ANSI: %q", plain)
	}
}

// realisticSetup mirrors a real machine: a ~200KB .claude.json and a
// four-account fleet, so the benchmark and the 50ms assertion measure the
// real read+parse cost, not a toy.
func realisticSetup(t testing.TB) StatuslineOptions {
	dirPath := filepath.Join(t.TempDir(), ".claude-bench")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	padding := map[string]any{"oauthAccount": map[string]any{"emailAddress": "a@example.dev"}}
	blob := strings.Repeat("x", 512)
	for i := range 400 { // ~200KB of realistic project-history noise
		padding[fmt.Sprintf("project-%d", i)] = blob
	}
	data, _ := json.Marshal(padding)
	if err := os.WriteFile(filepath.Join(dirPath, ".claude.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}

	st := store.At(t.TempDir())
	var accs []store.Account
	for i := 1; i <= 4; i++ {
		accs = append(accs, store.Account{ID: fmt.Sprintf("acct-%d", i),
			Label: fmt.Sprintf("a%d", i), Email: fmt.Sprintf("a%d@example.dev", i)})
	}
	accs[1].Email = "a@example.dev"
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-2", AsOf: now.Add(-time.Minute), Buckets: proofBuckets(),
	}); err != nil {
		t.Fatal(err)
	}
	// Production shape: the pilot preset exercises the fleet
	// segments, width collapse runs, and the daemon-backed sources are wired
	// (stubs — the E2E budget check covers the real socket).
	samples := make([]statusline.Sample, 60)
	for i := range samples {
		samples[i] = statusline.Sample{At: now.Add(time.Duration(i-60) * time.Minute), Percent: float64(i)}
	}
	pilot := statusline.PresetByID("pilot")
	// A session_id on stdin puts the P2 floor-guard binding read (one small
	// file under $LLMPILOT_HOME) on the measured path — the 50ms budget is
	// proven WITH the guard, not around it.
	stdin := []byte(fmt.Sprintf(`{"session_id":"bench-sess-1","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":%d}}}`,
		time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC).Unix()))
	return StatuslineOptions{
		Store: st, Dir: claudecfg.DirAt(dirPath), Now: now, Loc: time.UTC,
		Stdin:  stdin,
		Config: pilot.Config, Width: 120,
		History:  func(_, _, _ string) []statusline.Sample { return samples },
		DaemonUp: func() bool { return true },
	}
}

func TestStatuslineRendersUnder50ms(t *testing.T) {
	opts := realisticSetup(t)
	start := time.Now()
	got := Statusline(opts)
	elapsed := time.Since(start)
	if !strings.Contains(got, "5h:23%") {
		t.Fatalf("unexpected render: %q", got)
	}
	if elapsed > 50*time.Millisecond {
		t.Errorf("statusline render took %v, budget 50ms", elapsed)
	}
	t.Logf("statusline render: %v (budget 50ms)", elapsed)
}

func BenchmarkStatusline(b *testing.B) {
	opts := realisticSetup(b)
	b.ResetTimer()
	for range b.N {
		Statusline(opts)
	}
}

// TestStatuslineOutputCoexist: a kept statusline's full multi-line output
// renders above the llmpilot line; a failing kept command says so instead of
// vanishing; no keep = single line.
func TestStatuslineOutputCoexist(t *testing.T) {
	st, id := fleetStore(t, "a@example.dev")
	saveSnap(t, st, id, now.Add(-time.Minute), proofBuckets())
	base := StatuslineOptions{
		Store: st, Dir: fakeConfigDir(t, "a@example.dev"), Now: now, Loc: time.UTC,
	}
	ours := "[acct 2/4 | a@example.dev] 5h:23%(14:32) wk:41% F:67%(Sun)"

	cfg := statusline.Default()
	cfg.Keep = &statusline.KeepConfig{Command: "their-statusline"}
	kept := base
	kept.Config = cfg
	kept.KeepExec = func(command string) (string, error) {
		if command != "their-statusline" {
			t.Errorf("wrong kept command: %q", command)
		}
		return "their line 1\ntheir line 2\n\n", nil
	}
	got := StatuslineOutput(kept)
	want := "their line 1\ntheir line 2\n" + ours
	if got != want {
		t.Errorf("coexist output:\n  got  %q\n  want %q", got, want)
	}

	failing := kept
	failing.KeepExec = func(string) (string, error) { return "", os.ErrDeadlineExceeded }
	got = StatuslineOutput(failing)
	if !strings.Contains(got, "kept statusline failed") || !strings.HasSuffix(got, ours) {
		t.Errorf("failing kept command must say so and still render our line: %q", got)
	}

	plain := base
	if got := StatuslineOutput(plain); got != ours {
		t.Errorf("no keep must be exactly the single line: %q", got)
	}
}
