package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/store"
)

func TestBucketLabel(t *testing.T) {
	cases := []struct {
		b    store.Bucket
		want string
	}{
		{store.Bucket{Kind: "session"}, "5h"},
		{store.Bucket{Kind: "five_hour"}, "5h"},
		{store.Bucket{Kind: "weekly_all"}, "wk"},
		{store.Bucket{Kind: "seven_day"}, "wk"},
		{store.Bucket{Kind: "seven_day_opus"}, "O"},
		{store.Bucket{Kind: "seven_day_sonnet"}, "S"},
		{store.Bucket{Kind: "weekly_scoped", Scope: "Fable"}, "F"},
		{store.Bucket{Kind: "weekly_scoped", Scope: "opus"}, "O"},
		{store.Bucket{Kind: "quokka_hourly"}, "quokka_hourly"}, // unknown survives verbatim
	}
	for _, c := range cases {
		if got := BucketLabel(c.b); got != c.want {
			t.Errorf("BucketLabel(%+v) = %q, want %q", c.b, got, c.want)
		}
	}
}

func TestFormatBucketResetRules(t *testing.T) {
	sessionReset := time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC)
	weeklyReset := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		b    store.Bucket
		want string
	}{
		// session windows always show the clock time
		{store.Bucket{Kind: "session", Percent: 23, Severity: "normal", ResetsAt: &sessionReset}, "5h:23%(14:32)"},
		// quiet weekly buckets stay short
		{store.Bucket{Kind: "weekly_all", Percent: 41, Severity: "normal", ResetsAt: &weeklyReset}, "wk:41%"},
		// a warning severity earns the reset weekday
		{store.Bucket{Kind: "weekly_scoped", Scope: "Fable", Percent: 67, Severity: "warning", ResetsAt: &weeklyReset}, "F:67%(Sun)"},
		// no server severity, no invented threshold
		{store.Bucket{Kind: "weekly_all", Percent: 99, ResetsAt: &weeklyReset}, "wk:99%"},
		// fractional percentages keep their precision
		{store.Bucket{Kind: "session", Percent: 12.5, ResetsAt: &sessionReset}, "5h:12.5%(14:32)"},
	}
	for _, c := range cases {
		if got := FormatBucket(c.b, now, time.UTC); got != c.want {
			t.Errorf("FormatBucket(%+v) = %q, want %q", c.b, got, c.want)
		}
	}
}

func TestFormatAge(t *testing.T) {
	cases := []struct {
		age  time.Duration
		want string
	}{
		{30 * time.Second, "~now"},
		{4 * time.Minute, "~4m"},
		{95 * time.Minute, "~95m"},
		{3 * time.Hour, "~3h"},
	}
	for _, c := range cases {
		if got := FormatAge(c.age); got != c.want {
			t.Errorf("FormatAge(%v) = %q, want %q", c.age, got, c.want)
		}
	}
}

func TestMaskEmail(t *testing.T) {
	cases := map[string]string{
		"ali@example.dev": "a***@e***",
		"a@b.c":           "a***@b***",
		"":                "***",
		"nodomain":        "***",
		"@x":              "***",
	}
	for in, want := range cases {
		if got := MaskEmail(in); got != want {
			t.Errorf("MaskEmail(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestRenderFleet(t *testing.T) {
	reset := time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC)
	st := &daemon.State{
		ActiveID: "acct-1",
		Accounts: []daemon.AccountState{
			{
				Account: store.Account{ID: "acct-1", Label: "keep", Email: "ali@example.dev"},
				Snapshot: &store.UsageSnapshot{
					AccountID: "acct-1", AsOf: now.Add(-2 * time.Minute),
					Buckets: []store.Bucket{{Kind: "session", Percent: 23, ResetsAt: &reset}},
				},
			},
			{
				Account:   store.Account{ID: "acct-2", Label: "alt", Email: "alt@example.dev"},
				TokenNote: "token expired — run any claude session on this account to refresh",
			},
		},
	}
	var sb strings.Builder
	RenderFleet(&sb, st, now, time.UTC)
	out := sb.String()
	for _, want := range []string{
		"* keep", "a***@e***", "5h:23%(14:32)", "~2m",
		"  alt", "no usage data yet", "token expired",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("fleet output missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "example.dev") {
		t.Errorf("fleet output leaks a full email:\n%s", out)
	}
}

func TestRenderFleetEmpty(t *testing.T) {
	var sb strings.Builder
	RenderFleet(&sb, &daemon.State{}, now, time.UTC)
	if !strings.Contains(sb.String(), "llmpilot init") {
		t.Errorf("empty fleet must point at init: %q", sb.String())
	}
}
