package anthropic

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fakeToken = "sk-ant-oat01-FAKEFAKEFAKEFAKE"

const fakePayload = `{"claudeAiOauth":{"accessToken":"` + fakeToken + `","otherField":1}}`

type staticSource string

func (s staticSource) Token(context.Context) (string, error) { return string(s), nil }

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestFetchUsageModernShape(t *testing.T) {
	var gotAuth, gotBeta, gotUA string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotBeta = r.Header.Get("anthropic-beta")
		gotUA = r.Header.Get("User-Agent")
		if r.URL.Path != "/api/oauth/usage" {
			t.Errorf("path = %q", r.URL.Path)
		}
		_, _ = w.Write(fixture(t, "usage-a.json"))
	}))
	defer srv.Close()

	c := &UsageClient{
		Source:    staticSource(fakeToken),
		BaseURL:   srv.URL,
		UserAgent: "claude-code/2.1.205",
	}
	buckets, err := c.FetchUsage(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	if gotAuth != "Bearer "+fakeToken {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if gotBeta != "oauth-2025-04-20" {
		t.Errorf("anthropic-beta = %q", gotBeta)
	}
	if gotUA != "claude-code/2.1.205" {
		t.Errorf("User-Agent = %q", gotUA)
	}

	if len(buckets) != 4 {
		t.Fatalf("got %d buckets, want 4: %+v", len(buckets), buckets)
	}
	sess := buckets[0]
	if sess.Kind != "session" || sess.Percent != 23 || sess.Severity != "normal" || !sess.Active {
		t.Errorf("session bucket = %+v", sess)
	}
	wantReset := time.Date(2026, 7, 8, 14, 32, 0, 0, time.UTC)
	if sess.ResetsAt == nil || !sess.ResetsAt.Equal(wantReset) {
		t.Errorf("session resets_at = %v, want %v", sess.ResetsAt, wantReset)
	}
	fable := buckets[2]
	if fable.Kind != "weekly_scoped" || fable.Scope != "Fable" || fable.Percent != 67 || fable.Severity != "warning" {
		t.Errorf("scoped bucket = %+v", fable)
	}
	// The 2026-07-12 case: a kind and severity this code has never heard of.
	unknown := buckets[3]
	if unknown.Kind != "quokka_hourly" || unknown.Percent != 12.5 || unknown.Severity != "elevated_novel" {
		t.Errorf("unknown-kind bucket = %+v", unknown)
	}
	if unknown.ResetsAt != nil {
		t.Errorf("null resets_at should stay nil, got %v", unknown.ResetsAt)
	}
}

func TestParseUsageLegacyFallback(t *testing.T) {
	buckets, err := ParseUsage(fixture(t, "usage-b.json"))
	if err != nil {
		t.Fatal(err)
	}
	// Sorted by kind; extra_usage (null utilization), spend (no utilization),
	// nulls, and booleans are all skipped.
	wantKinds := []string{"five_hour", "mango_daily", "seven_day", "seven_day_opus"}
	if len(buckets) != len(wantKinds) {
		t.Fatalf("got %d buckets %+v, want kinds %v", len(buckets), buckets, wantKinds)
	}
	for i, k := range wantKinds {
		if buckets[i].Kind != k {
			t.Fatalf("bucket[%d].Kind = %q, want %q (all: %+v)", i, buckets[i].Kind, k, buckets)
		}
		if buckets[i].Severity != "" {
			t.Errorf("legacy bucket %q has invented severity %q", k, buckets[i].Severity)
		}
	}
	if buckets[0].Percent != 88 {
		t.Errorf("five_hour percent = %v", buckets[0].Percent)
	}
	if buckets[1].Percent != 3.5 || buckets[1].ResetsAt != nil {
		t.Errorf("mango_daily = %+v", buckets[1])
	}
}

func TestFetchUsageStatusErrors(t *testing.T) {
	for _, code := range []int{401, 429, 500} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(code)
			_, _ = w.Write([]byte(`{"error":"nope"}`))
		}))
		c := &UsageClient{Source: staticSource(fakeToken), BaseURL: srv.URL}
		_, err := c.FetchUsage(context.Background())
		srv.Close()
		var se *StatusError
		if !errors.As(err, &se) || se.StatusCode != code {
			t.Fatalf("code %d: err = %v, want StatusError", code, err)
		}
	}
}

// TestTokenNeverInErrors is the no-leak guarantee: force every error path
// that has touched the token and assert the token is absent from the error.
func TestTokenNeverInErrors(t *testing.T) {
	// 1. HTTP status error path.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	c := &UsageClient{Source: staticSource(fakeToken), BaseURL: srv.URL}
	_, err := c.FetchUsage(context.Background())
	assertNoToken(t, err)

	// 2. Malformed response body path.
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"limits": [{"kind": 42}]`)) // truncated + wrong type
	}))
	defer srv2.Close()
	c2 := &UsageClient{Source: staticSource(fakeToken), BaseURL: srv2.URL}
	_, err = c2.FetchUsage(context.Background())
	if err == nil {
		t.Fatal("want parse error")
	}
	assertNoToken(t, err)

	// 3. Credential payload parse failures (payload content must not leak).
	_, err = accessTokenFromJSON([]byte(`{"claudeAiOauth":{` + fakeToken))
	if err == nil {
		t.Fatal("want parse error")
	}
	assertNoToken(t, err)
	_, err = accessTokenFromJSON([]byte(`{"mcpOAuth":{"x":"` + fakeToken + `"}}`))
	if err == nil {
		t.Fatal("want missing-token error")
	}
	assertNoToken(t, err)
}

func assertNoToken(t *testing.T, err error) {
	t.Helper()
	if err == nil {
		return
	}
	if strings.Contains(err.Error(), fakeToken) || strings.Contains(err.Error(), "FAKEFAKE") {
		t.Fatalf("token leaked into error: %v", err)
	}
}

// TestKeychainInterlockRefusesRealKeychains tests the guard's FAIL cases:
// under LLMPILOT_TEST, the login keychain — by identity, not just by
// absence of a path — and anything inside a real Keychains directory must
// be refused before any subprocess runs.
func TestKeychainInterlockRefusesRealKeychains(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	home := t.TempDir()
	t.Setenv("HOME", home)
	cases := []struct {
		name     string
		keychain string
	}{
		{"empty path", ""},
		{"login keychain by bare name", "login.keychain-db"},
		{"login keychain absolute", filepath.Join(home, "Library", "Keychains", "login.keychain-db")},
		{"login keychain legacy name, odd case", "/tmp/somewhere/Login.Keychain"},
		{"non-login keychain inside the real dir", filepath.Join(home, "Library", "Keychains", "innocent.keychain-db")},
		{"system keychain", "/Library/Keychains/System.keychain"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ran := false
			k := &KeychainSource{
				Service:  "Claude Code-credentials",
				Keychain: c.keychain,
				Run: func(context.Context, string, ...string) ([]byte, error) {
					ran = true
					return []byte(fakePayload), nil
				},
			}
			_, err := k.Token(context.Background())
			if err == nil || !strings.Contains(err.Error(), "interlock") {
				t.Fatalf("want interlock error, got %v", err)
			}
			if ran {
				t.Fatal("interlock must refuse BEFORE running /usr/bin/security")
			}
		})
	}
}

func TestKeychainInterlockAllowsThrowawayKeychain(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	var gotName string
	var gotArgs []string
	k := &KeychainSource{
		Service:  "Claude Code-credentials",
		Keychain: "/tmp/llmpilot-test.keychain-db",
		Run: func(_ context.Context, name string, args ...string) ([]byte, error) {
			gotName, gotArgs = name, args
			return []byte(fakePayload + "\n"), nil
		},
	}
	tok, err := k.Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if tok != fakeToken {
		t.Fatalf("token = %q", tok)
	}
	if gotName != "/usr/bin/security" {
		t.Fatalf("ran %q", gotName)
	}
	want := []string{"find-generic-password", "-s", "Claude Code-credentials", "-w", "/tmp/llmpilot-test.keychain-db"}
	if strings.Join(gotArgs, " ") != strings.Join(want, " ") {
		t.Fatalf("args = %v, want %v", gotArgs, want)
	}
}

func TestKeychainReadFailure(t *testing.T) {
	k := &KeychainSource{
		Service: "Claude Code-credentials",
		Run: func(context.Context, string, ...string) ([]byte, error) {
			return nil, errors.New("exit status 44")
		},
	}
	_, err := k.Token(context.Background())
	if err == nil || !strings.Contains(err.Error(), "Claude Code-credentials") {
		t.Fatalf("want keychain error naming the service, got %v", err)
	}
}

func TestFileSource(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	if err := os.WriteFile(good, []byte(fakePayload), 0o600); err != nil {
		t.Fatal(err)
	}
	tok, err := (&FileSource{Path: good}).Token(context.Background())
	if err != nil || tok != fakeToken {
		t.Fatalf("tok=%q err=%v", tok, err)
	}

	// A real-world shape: credentials file exists but holds only MCP OAuth
	// entries, no claudeAiOauth block (observed on a live machine 2026-07-08).
	mcpOnly := filepath.Join(dir, "mcp.json")
	if err := os.WriteFile(mcpOnly, []byte(`{"mcpOAuth":{"some-server":{"accessToken":"x"}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = (&FileSource{Path: mcpOnly}).Token(context.Background())
	if err == nil || !strings.Contains(err.Error(), "no claudeAiOauth.accessToken") {
		t.Fatalf("want missing-token error, got %v", err)
	}
}

func TestFirstSource(t *testing.T) {
	failing := &FileSource{Path: "/nonexistent/nope.json"}
	s := FirstSource{failing, staticSource(fakeToken)}
	tok, err := s.Token(context.Background())
	if err != nil || tok != fakeToken {
		t.Fatalf("tok=%q err=%v", tok, err)
	}

	_, err = FirstSource{failing}.Token(context.Background())
	if err == nil {
		t.Fatal("want error when every source fails")
	}
	_, err = FirstSource{}.Token(context.Background())
	if err == nil {
		t.Fatal("want error for empty source list")
	}
}

func TestBackoff(t *testing.T) {
	cases := []struct {
		attempt int
		want    time.Duration
	}{
		{-1, time.Minute},
		{0, time.Minute},
		{1, 2 * time.Minute},
		{4, 16 * time.Minute},
		{5, 30 * time.Minute},
		{10, 30 * time.Minute},
		{100, 30 * time.Minute},
	}
	for _, c := range cases {
		if got := Backoff(c.attempt); got != c.want {
			t.Errorf("Backoff(%d) = %v, want %v", c.attempt, got, c.want)
		}
	}
}

func TestRateLimitBackoff(t *testing.T) {
	cases := []struct {
		attempt    int
		retryAfter time.Duration
		want       time.Duration
	}{
		{0, 0, 10 * time.Minute},                // floor
		{1, 0, 20 * time.Minute},                // doubled
		{2, 0, 30 * time.Minute},                // 40m clamped to backoffCap
		{3, 0, 30 * time.Minute},                // shift capped → still 30m
		{0, 45 * time.Minute, 45 * time.Minute}, // Retry-After longer than the ramp wins
		{0, 90 * time.Minute, 60 * time.Minute}, // Retry-After capped at maxRateLimitWait
	}
	for _, c := range cases {
		if got := RateLimitBackoff(c.attempt, c.retryAfter); got != c.want {
			t.Errorf("RateLimitBackoff(%d, %v) = %v, want %v", c.attempt, c.retryAfter, got, c.want)
		}
	}
}

func TestParseRetryAfter(t *testing.T) {
	if got := parseRetryAfter("120"); got != 2*time.Minute {
		t.Errorf("delta-seconds: got %v, want 2m", got)
	}
	future := time.Now().Add(90 * time.Second).UTC().Format(http.TimeFormat)
	if got := parseRetryAfter(future); got <= 0 {
		t.Errorf("future HTTP-date: got %v, want > 0", got)
	}
	past := time.Now().Add(-time.Hour).UTC().Format(http.TimeFormat)
	for _, v := range []string{"", "0", "-5", "garbage", past} {
		if got := parseRetryAfter(v); got != 0 {
			t.Errorf("parseRetryAfter(%q) = %v, want 0", v, got)
		}
	}
	// An absurd delta-seconds value clamps instead of overflowing int64.
	if got := parseRetryAfter("99999999999"); got != maxRetryAfterSeconds*time.Second {
		t.Errorf("overflow clamp: got %v, want %v", got, time.Duration(maxRetryAfterSeconds)*time.Second)
	}
}
