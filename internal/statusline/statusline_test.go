package statusline

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// now is fixed so reset rendering is deterministic: 2026-07-08 was a
// Wednesday, 2026-07-12 a Sunday (same clock as internal/cli's goldens).
var now = time.Date(2026, 7, 8, 12, 4, 0, 0, time.UTC)

func fakeDir(t *testing.T, email string) claudecfg.Dir {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	doc := map[string]any{"oauthAccount": map[string]any{"emailAddress": email}}
	data, _ := json.Marshal(doc)
	if err := os.WriteFile(filepath.Join(path, ".claude.json"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	return claudecfg.DirAt(path)
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

// fixtureCtx builds a four-account fleet with snapshots and a full stdin
// payload — every segment has data to render from.
func fixtureCtx(t *testing.T, tier Tier) *Ctx {
	t.Helper()
	st := store.At(t.TempDir())
	accs := []store.Account{
		{ID: "acct-1", Label: "one", Email: "one@example.dev"},
		{ID: "acct-2", Label: "two", Email: "a@example.dev"},
		{ID: "acct-3", Label: "three", Email: "three@example.dev"},
		{ID: "acct-4", Label: "four", Email: "four@example.dev", Pinned: true},
	}
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-2", AsOf: now.Add(-time.Minute), Buckets: proofBuckets(),
	}); err != nil {
		t.Fatal(err)
	}
	lowReset := time.Date(2026, 7, 8, 16, 0, 0, 0, time.UTC)
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-3", AsOf: now.Add(-time.Minute),
		Buckets: []store.Bucket{{Kind: "session", Percent: 12, ResetsAt: &lowReset}},
	}); err != nil {
		t.Fatal(err)
	}
	stdin := fmt.Sprintf(`{
		"model": {"id": "claude-fable-5", "display_name": "Fable"},
		"workspace": {"current_dir": %q},
		"cost": {"total_cost_usd": 3.42},
		"context_window": {"used_percentage": 34, "context_window_size": 200000},
		"rate_limits": {"five_hour": {"used_percentage": 23, "resets_at": %d}}
	}`, gitWorkdir(t), time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC).Unix())
	return &Ctx{
		Now: now, Loc: time.UTC, Tier: tier,
		In: ParsePayload([]byte(stdin)), Store: st, Dir: fakeDir(t, "a@example.dev"),
		History: func(accountID, kind, scope string) []Sample {
			return []Sample{
				{At: now.Add(-30 * time.Minute), Percent: 10},
				{At: now.Add(-1 * time.Minute), Percent: 23},
			}
		},
		Exec:     func(command string) (string, error) { return "cmd-out\nsecond line", nil },
		DaemonUp: func() bool { return true },
	}
}

// gitWorkdir fabricates a repo dir (a .git/HEAD file) for the dir segment.
func gitWorkdir(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "myrepo")
	if err := os.MkdirAll(filepath.Join(dir, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".git", "HEAD"),
		[]byte("ref: refs/heads/main\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dir
}

// TestSegmentMatrix renders EVERY registered segment at plain, standard (16),
// 256, and rich tiers: each must produce visible output on the fixture, and
// plain output must carry zero ANSI.
func TestSegmentMatrix(t *testing.T) {
	tiers := []Tier{TierPlain, Tier16, Tier256, TierRich}
	opts := map[string]map[string]any{
		"text":    {"text": "hello", "color": "#8250df"},
		"command": {"command": "echo hi"},
		"usage":   {"mode": "bar"},
	}
	for _, spec := range Specs() {
		for _, tier := range tiers {
			t.Run(spec.ID+"/"+tier.String(), func(t *testing.T) {
				ctx := fixtureCtx(t, tier)
				cfg := Config{Version: 1, Segments: []SegmentConfig{{ID: spec.ID, Options: opts[spec.ID]}}}
				got := Render(cfg, ctx)
				if got == "" {
					t.Fatalf("segment %q rendered nothing on the full fixture", spec.ID)
				}
				if tier == TierPlain && strings.Contains(got, "\x1b[") {
					t.Errorf("plain tier leaked ANSI: %q", got)
				}
				t.Logf("%-10s %-9s %q", spec.ID, tier, got)
			})
		}
	}
}

// TestWidthCollapse pins the golden at three widths: wide keeps everything,
// medium collapses the lowest-priority segments first, narrow keeps the
// usage runway alive.
func TestWidthCollapse(t *testing.T) {
	cfg := Config{Version: 1, Segments: []SegmentConfig{
		{ID: "account"}, {ID: "usage"}, {ID: "model"}, {ID: "context"},
		{ID: "cost"}, {ID: "autopilot"},
	}}
	render := func(width int) string {
		ctx := fixtureCtx(t, TierPlain)
		ctx.Width = width
		return Render(cfg, ctx)
	}

	wide := render(200)
	for _, want := range []string{"Fable", "ctx:34%", "$3.42", "auto:on", "5h:23%"} {
		if !strings.Contains(wide, want) {
			t.Errorf("width 200 dropped %q: %q", want, wide)
		}
	}

	medium := render(100)
	if strings.Contains(medium, "auto:on") || strings.Contains(medium, "$3.42") {
		t.Errorf("width 100 must drop the lowest-priority segments (autopilot, cost) first: %q", medium)
	}
	if !strings.Contains(medium, "5h:23%") {
		t.Errorf("width 100 lost the usage runway: %q", medium)
	}

	narrow := render(60)
	if !strings.Contains(narrow, "5h:23%") {
		t.Errorf("width 60 lost the usage runway (highest priority must survive): %q", narrow)
	}
	if len([]rune(narrow)) > len([]rune(medium)) || len([]rune(medium)) > len([]rune(wide)) {
		t.Errorf("collapse not monotonic: %d / %d / %d chars",
			len([]rune(wide)), len([]rune(medium)), len([]rune(narrow)))
	}
	t.Logf("width 200: %q", wide)
	t.Logf("width 100: %q", medium)
	t.Logf("width  60: %q", narrow)
}

// TestWidthCollapseDropsRightmostOnTie: equal priorities drop right-to-left.
func TestWidthNarrowFormBeforeDrop(t *testing.T) {
	// account's narrow form drops the email before the segment disappears.
	cfg := Config{Version: 1, Segments: []SegmentConfig{{ID: "account"}, {ID: "usage"}}}
	ctx := fixtureCtx(t, TierPlain)
	ctx.Width = 44 + 40 // flex reserves 40; leaves 44 — enough for the narrow head + runway
	got := Render(cfg, ctx)
	if strings.Contains(got, "a@example.dev") {
		t.Errorf("narrow width must drop the email via the account narrow form: %q", got)
	}
	if !strings.Contains(got, "[acct 2/4]") {
		t.Errorf("account head should survive in privacy form: %q", got)
	}
}

func TestConfigMissingIsDefault(t *testing.T) {
	cfg, err := LoadConfig(t.TempDir())
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	if len(cfg.Segments) != 2 || cfg.Segments[0].ID != "account" || cfg.Segments[1].ID != "usage" {
		t.Errorf("default config is not the original default line: %+v", cfg.Segments)
	}
}

// TestConfigCorruptNeverClobbers: unreadable config → defaults in memory,
// disk byte-identical (teardown: never-clobber-on-error).
func TestConfigCorruptNeverClobbers(t *testing.T) {
	home := t.TempDir()
	junk := []byte(`{"version": 1, "segments": [{"id": "usage"`)
	if err := os.WriteFile(ConfigPath(home), junk, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(home)
	if err == nil {
		t.Error("corrupt file must surface an error")
	}
	if len(cfg.Segments) != 2 {
		t.Errorf("corrupt file must fall back to defaults, got %+v", cfg.Segments)
	}
	after, _ := os.ReadFile(ConfigPath(home))
	if string(after) != string(junk) {
		t.Errorf("LoadConfig wrote to disk on error — never-clobber violated")
	}
}

// TestConfigMigrationAllowlist: an unversioned file keeps known segments and
// valid options; junk segments, junk options, and junk field values drop.
func TestConfigMigrationAllowlist(t *testing.T) {
	home := t.TempDir()
	raw := `{
		"segments": [
			{"id": "usage", "options": {"mode": "bar", "bogus": true, "privacy": "not-a-bool"}},
			{"id": "no-such-segment"},
			{"id": "account", "options": {"privacy": true}}
		],
		"flex": "diagonal",
		"color": "plaid",
		"separator": "waaaaaaaay-too-long"
	}`
	if err := os.WriteFile(ConfigPath(home), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(home)
	if err != nil {
		t.Fatalf("valid JSON must load: %v", err)
	}
	if cfg.Version != ConfigVersion {
		t.Errorf("migration must stamp the current version, got %d", cfg.Version)
	}
	if len(cfg.Segments) != 2 {
		t.Fatalf("want 2 surviving segments, got %+v", cfg.Segments)
	}
	if cfg.Segments[0].ID != "usage" || cfg.Segments[0].Options["mode"] != "bar" {
		t.Errorf("valid option lost: %+v", cfg.Segments[0])
	}
	if _, ok := cfg.Segments[0].Options["bogus"]; ok {
		t.Error("unknown option key survived the allowlist")
	}
	if cfg.Segments[1].Options["privacy"] != true {
		t.Errorf("valid bool option lost: %+v", cfg.Segments[1])
	}
	if cfg.Flex != "" || cfg.Color != "" || cfg.Separator != "" {
		t.Errorf("junk field values survived: flex=%q color=%q sep=%q", cfg.Flex, cfg.Color, cfg.Separator)
	}
}

func TestValidateRejectsJunk(t *testing.T) {
	cases := []Config{
		{Version: 1, Segments: []SegmentConfig{{ID: "nope"}}},
		{Version: 1, Segments: []SegmentConfig{{ID: "usage", Options: map[string]any{"mode": "spiral"}}}},
		{Version: 1, Segments: []SegmentConfig{{ID: "text", Options: map[string]any{"color": "red"}}}},
		{Version: 7, Segments: []SegmentConfig{{ID: "usage"}}},
		{Version: 1},
	}
	for i, c := range cases {
		if err := Validate(c); err == nil {
			t.Errorf("case %d: junk config validated: %+v", i, c)
		}
	}
	good := Config{Version: 1, Segments: []SegmentConfig{
		{ID: "usage", Options: map[string]any{"mode": "bar"}},
		{ID: "text", Options: map[string]any{"text": "hi", "color": "#8250df"}},
	}}
	if err := Validate(good); err != nil {
		t.Errorf("good config rejected: %v", err)
	}
}

func TestSaveConfigRoundTrip(t *testing.T) {
	home := t.TempDir()
	cfg := Config{Segments: []SegmentConfig{{ID: "usage", Options: map[string]any{"mode": "time"}}}}
	if err := SaveConfig(home, cfg); err != nil {
		t.Fatal(err)
	}
	got, err := LoadConfig(home)
	if err != nil {
		t.Fatal(err)
	}
	if got.Version != ConfigVersion || got.Segments[0].Options["mode"] != "time" {
		t.Errorf("round trip lost data: %+v", got)
	}
	if err := SaveConfig(home, Config{Segments: []SegmentConfig{{ID: "junk"}}}); err == nil {
		t.Error("SaveConfig must refuse invalid configs")
	}
}

// TestColorDowngradeSanitize: one hex color renders as truecolor at rich,
// a 256 index at 256, a basic code at 16, and nothing at plain.
func TestColorDowngradeSanitize(t *testing.T) {
	spans := []Span{spanHex("X", "#1fa943")}
	cases := []struct {
		tier Tier
		want string
	}{
		{TierRich, "\x1b[38;2;31;169;67mX\x1b[0m"},
		{Tier256, "\x1b[38;5;"},
		{Tier16, "\x1b[3"},
		{TierPlain, "X"},
	}
	for _, c := range cases {
		got := paint(spans, c.tier)
		if !strings.Contains(got, c.want) {
			t.Errorf("tier %s: got %q, want it to contain %q", c.tier, got, c.want)
		}
	}
	if got := paint(spans, TierPlain); got != "X" {
		t.Errorf("plain tier must strip everything: %q", got)
	}
	// semantic colors stay classic SGR at every colored tier
	warn := []Span{spanSem("W", SemWarn)}
	for _, tier := range []Tier{Tier16, Tier256, TierRich} {
		if got := paint(warn, tier); got != "\x1b[33mW\x1b[0m" {
			t.Errorf("tier %s: semantic warn drifted from SGR 33: %q", tier, got)
		}
	}
}

func TestNoColorAlwaysWins(t *testing.T) {
	env := map[string]string{"NO_COLOR": "1", "TERM": "xterm-256color", "COLORTERM": "truecolor"}
	getenv := func(k string) string { return env[k] }
	if got := ResolveTier("truecolor", getenv); got != TierPlain {
		t.Errorf("NO_COLOR must beat an explicit truecolor pin, got %s", got)
	}
	delete(env, "NO_COLOR")
	if got := ResolveTier("auto", getenv); got != TierRich {
		t.Errorf("COLORTERM=truecolor should autodetect rich, got %s", got)
	}
	env["COLORTERM"] = ""
	if got := ResolveTier("auto", getenv); got != Tier256 {
		t.Errorf("TERM=xterm-256color should autodetect 256, got %s", got)
	}
	env["TERM"] = "dumb"
	if got := ResolveTier("auto", getenv); got != TierPlain {
		t.Errorf("dumb terminal must be plain, got %s", got)
	}
}

func TestGradientHexEndpointsAndMidpoint(t *testing.T) {
	stops := []string{"#000000", "#ffffff"}
	if got := GradientHex(stops, 0); got != "#000000" {
		t.Errorf("t=0: %s", got)
	}
	if got := GradientHex(stops, 1); got != "#ffffff" {
		t.Errorf("t=1: %s", got)
	}
	mid := GradientHex(stops, 0.5)
	r, g, b, ok := parseHex(mid)
	if !ok || r != g || g != b {
		t.Errorf("OKLab midpoint of black→white must stay neutral gray: %s", mid)
	}
	// OKLab L=0.5 sits near sRGB #636363 — darker than the naive #808080.
	if r < 90 || r > 160 {
		t.Errorf("perceptual midpoint out of plausible range: %s", mid)
	}
}

func TestProjectWall(t *testing.T) {
	base := now.Add(-40 * time.Minute)
	burning := []Sample{
		{At: base, Percent: 50},
		{At: base.Add(20 * time.Minute), Percent: 70},
		{At: base.Add(39 * time.Minute), Percent: 89},
	}
	wall, ok := projectWall(burning, now)
	if !ok {
		t.Fatal("steady burn must project a wall")
	}
	// ~1%/min from 89% → ~11 minutes after the last sample.
	expect := base.Add(39 * time.Minute).Add(11 * time.Minute)
	if d := wall.Sub(expect); d < -2*time.Minute || d > 2*time.Minute {
		t.Errorf("wall projection off: got %v, want ≈%v", wall, expect)
	}

	if _, ok := projectWall([]Sample{{At: now, Percent: 50}}, now); ok {
		t.Error("one sample must not project")
	}
	flat := []Sample{{At: base, Percent: 50}, {At: now, Percent: 50}}
	if _, ok := projectWall(flat, now); ok {
		t.Error("flat burn must not project")
	}
	stale := []Sample{
		{At: now.Add(-3 * time.Hour), Percent: 10},
		{At: now.Add(-2 * time.Hour), Percent: 90},
	}
	if _, ok := projectWall(stale, now); ok {
		t.Error("samples older than the lookback must not project")
	}
}

// TestBurnSegmentCritBeforeReset: the fixture burns 13%/29min from 23% —
// wall lands after the 14:32 reset, so the segment reads "no wall"; a hotter
// burn flips it to the crit wall time.
func TestBurnSegment(t *testing.T) {
	ctx := fixtureCtx(t, TierPlain)
	cfg := Config{Version: 1, Segments: []SegmentConfig{{ID: "burn"}}}
	if got := Render(cfg, ctx); got != "no wall" {
		t.Errorf("slow burn: got %q, want %q", got, "no wall")
	}
	hot := fixtureCtx(t, TierPlain)
	hot.History = func(_, _, _ string) []Sample {
		return []Sample{
			{At: now.Add(-30 * time.Minute), Percent: 40},
			{At: now.Add(-1 * time.Minute), Percent: 90},
		}
	}
	got := Render(cfg, hot)
	if !strings.HasPrefix(got, "wall ") {
		t.Errorf("hot burn must print the wall clock: %q", got)
	}
}

func TestRotationPrefersLowestEligible(t *testing.T) {
	ctx := fixtureCtx(t, TierPlain)
	cfg := Config{Version: 1, Segments: []SegmentConfig{{ID: "rotation"}}}
	got := Render(cfg, ctx)
	// acct-3 ("three") at 12% is the only fresh, unpinned, non-active
	// candidate; acct-4 is pinned, acct-1 has no snapshot.
	if got != "→three:12%" {
		t.Errorf("rotation preview = %q, want %q", got, "→three:12%")
	}
}

func TestFleetMarksActiveAndUnknown(t *testing.T) {
	ctx := fixtureCtx(t, TierPlain)
	cfg := Config{Version: 1, Segments: []SegmentConfig{{ID: "fleet"}}}
	got := Render(cfg, ctx)
	want := "one:— *two:23% three:12% four:—"
	if got != want {
		t.Errorf("fleet = %q, want %q", got, want)
	}
}

func TestPresetsAreValidAndDefaultIsOriginalLine(t *testing.T) {
	for _, p := range Presets() {
		if err := Validate(p.Config); err != nil {
			t.Errorf("preset %q is invalid: %v", p.ID, err)
		}
	}
	def := Default()
	runway := PresetByID("runway")
	if runway == nil || fmt.Sprint(runway.Config.Segments) != fmt.Sprint(def.Segments) {
		t.Error("the runway preset must equal the zero-config default (zero-config parity anchor)")
	}
}

func TestCommandSegmentPreviewNeverExecutes(t *testing.T) {
	ctx := fixtureCtx(t, TierPlain)
	ctx.Exec = nil // daemon preview: execution disabled
	cfg := Config{Version: 1, Segments: []SegmentConfig{
		{ID: "command", Options: map[string]any{"command": "echo pwned"}},
	}}
	got := Render(cfg, ctx)
	if strings.Contains(got, "pwned") && !strings.Contains(got, "echo pwned") {
		t.Errorf("preview executed a command: %q", got)
	}
	if !strings.Contains(got, "(echo pwned") {
		t.Errorf("preview should show the command placeholder: %q", got)
	}
}
