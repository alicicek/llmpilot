package anthropic

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestNewPKCEShape(t *testing.T) {
	a, err := NewPKCE()
	if err != nil {
		t.Fatal(err)
	}
	if len(a.Verifier) != 43 { // 32 bytes, base64url unpadded
		t.Fatalf("verifier length = %d, want 43", len(a.Verifier))
	}
	sum := sha256.Sum256([]byte(a.Verifier))
	if want := base64.RawURLEncoding.EncodeToString(sum[:]); a.Challenge != want {
		t.Fatalf("challenge is not S256(verifier)")
	}
	b, err := NewPKCE()
	if err != nil {
		t.Fatal(err)
	}
	if a.Verifier == b.Verifier {
		t.Fatal("two PKCE verifiers are identical")
	}
}

func TestAuthorizeURLExactShape(t *testing.T) {
	raw, err := AuthorizeURL("chal-123", "state-456", LoginRedirectURI)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := u.Scheme + "://" + u.Host + u.Path; got != "https://claude.com/cai/oauth/authorize" {
		t.Fatalf("authorize base = %q", got)
	}
	q := u.Query()
	want := map[string]string{
		"code":                  "true",
		"client_id":             "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
		"response_type":         "code",
		"redirect_uri":          "https://platform.claude.com/oauth/code/callback",
		"scope":                 "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
		"code_challenge":        "chal-123",
		"code_challenge_method": "S256",
		"state":                 "state-456",
	}
	for k, v := range want {
		if got := q.Get(k); got != v {
			t.Errorf("param %s = %q, want %q", k, got, v)
		}
	}
	if len(q) != len(want) {
		t.Errorf("authorize URL has %d params, want %d: %v", len(q), len(want), q)
	}

	if _, err := AuthorizeURL("", "s", LoginRedirectURI); err == nil {
		t.Error("empty challenge accepted")
	}
	if _, err := AuthorizeURL("c", "", LoginRedirectURI); err == nil {
		t.Error("empty state accepted")
	}
}

func TestAuthorizeURLLoopbackOmitsCodeParam(t *testing.T) {
	if got := LoopbackRedirectURI(51789); got != "http://localhost:51789/callback" {
		t.Fatalf("loopback redirect = %q", got)
	}
	loopback := LoopbackRedirectURI(51789)
	raw, err := AuthorizeURL("chal", "st", loopback)
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if q.Get("redirect_uri") != loopback {
		t.Errorf("redirect_uri = %q, want %q", q.Get("redirect_uri"), loopback)
	}
	// The loopback flow auto-redirects; it must NOT request display-the-code
	// (manual-paste) mode — that is only for the hosted callback.
	if q.Has("code") {
		t.Errorf("loopback authorize URL set code=%q; it must be absent", q.Get("code"))
	}
}

func TestExchangeSendsCLIExactBodyAndParses(t *testing.T) {
	var gotBody map[string]string
	var gotCT string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/oauth/token" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		gotCT = r.Header.Get("Content-Type")
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token":  "at-new",
			"refresh_token": "rt-new",
			"expires_in":    3600,
			"scope":         "user:inference user:profile",
			"account":       map[string]string{"uuid": "acct-uuid-1", "email_address": "who@example.com"},
			"organization":  map[string]string{"uuid": "org-uuid-1"},
		})
	}))
	defer srv.Close()

	fixed := time.Date(2026, 7, 23, 12, 0, 0, 0, time.UTC)
	c := &LoginClient{TokenBaseURL: srv.URL, UserAgent: "claude-code/2.1.218", Now: func() time.Time { return fixed }}
	res, err := c.Exchange(context.Background(), "the-code", "the-state", "the-verifier", LoginRedirectURI)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(gotCT, "application/json") {
		t.Errorf("Content-Type = %q", gotCT)
	}
	wantBody := map[string]string{
		"grant_type":    "authorization_code",
		"code":          "the-code",
		"redirect_uri":  "https://platform.claude.com/oauth/code/callback",
		"client_id":     "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
		"code_verifier": "the-verifier",
		"state":         "the-state",
	}
	for k, v := range wantBody {
		if gotBody[k] != v {
			t.Errorf("body %s = %q, want %q", k, gotBody[k], v)
		}
	}
	if len(gotBody) != len(wantBody) {
		t.Errorf("body has %d fields, want %d: %v", len(gotBody), len(wantBody), gotBody)
	}
	if res.AccessToken != "at-new" || res.RefreshToken != "rt-new" {
		t.Fatal("tokens not parsed")
	}
	if want := fixed.Add(time.Hour); !res.ExpiresAt.Equal(want) {
		t.Errorf("ExpiresAt = %v, want %v", res.ExpiresAt, want)
	}
	if len(res.Scopes) != 2 || res.Scopes[0] != "user:inference" {
		t.Errorf("Scopes = %v", res.Scopes)
	}
	if res.Identity.EmailAddress != "who@example.com" || res.Identity.AccountUUID != "acct-uuid-1" || res.Identity.OrgUUID != "org-uuid-1" {
		t.Errorf("Identity = %+v", res.Identity)
	}
}

func TestExchangeIdentityAbsentIsZero(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"access_token": "at", "refresh_token": "rt", "expires_in": 60,
		})
	}))
	defer srv.Close()
	c := &LoginClient{TokenBaseURL: srv.URL}
	res, err := c.Exchange(context.Background(), "c", "s", "v", LoginRedirectURI)
	if err != nil {
		t.Fatal(err)
	}
	if res.Identity != (LoginIdentity{}) {
		t.Errorf("Identity = %+v, want zero", res.Identity)
	}
}

func TestExchangeErrorNeverSurfacesBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant","secret_echo":"sk-super-secret-token"}`))
	}))
	defer srv.Close()
	c := &LoginClient{TokenBaseURL: srv.URL}
	_, err := c.Exchange(context.Background(), "c", "s", "v", LoginRedirectURI)
	var ee *ExchangeError
	if !errors.As(err, &ee) {
		t.Fatalf("err = %v, want *ExchangeError", err)
	}
	if ee.StatusCode != http.StatusBadRequest || ee.Code != "invalid_grant" {
		t.Errorf("ExchangeError = %+v", ee)
	}
	if strings.Contains(err.Error(), "secret") {
		t.Errorf("error surfaces response body: %q", err)
	}
}

// TestExchangeTimedOutPostIsNotRetried pins the rotation hazard: one call =
// one POST, even when that POST times out (the server may have committed it).
func TestExchangeTimedOutPostIsNotRetried(t *testing.T) {
	var hits atomic.Int32
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		<-block
	}))
	defer srv.Close()
	// LIFO: unblock the handler BEFORE srv.Close waits on it.
	defer close(block)
	c := &LoginClient{TokenBaseURL: srv.URL, HTTP: &http.Client{Timeout: 50 * time.Millisecond}}
	_, err := c.Exchange(context.Background(), "c", "s", "v", LoginRedirectURI)
	if err == nil {
		t.Fatal("timed-out exchange returned nil error")
	}
	if got := hits.Load(); got != 1 {
		t.Fatalf("token endpoint hit %d times, want exactly 1", got)
	}
}

func TestExchangeInterlockRefusesProduction(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	c := &LoginClient{}
	_, err := c.Exchange(context.Background(), "c", "s", "v", LoginRedirectURI)
	if err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Fatalf("production exchange under LLMPILOT_TEST not refused: %v", err)
	}
}

func TestExchangeRequiresRefreshToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "at-only", "expires_in": 60})
	}))
	defer srv.Close()
	c := &LoginClient{TokenBaseURL: srv.URL}
	_, err := c.Exchange(context.Background(), "c", "s", "v", LoginRedirectURI)
	if err == nil || strings.Contains(err.Error(), "at-only") {
		t.Fatalf("refresh-token-less exchange: err = %v", err)
	}
}

func TestFetchProfile(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/oauth/profile" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		gotAuth = r.Header.Get("Authorization")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"account":      map[string]string{"uuid": "u-1", "email": "who@example.com", "display_name": "Who"},
			"organization": map[string]string{"uuid": "o-1"},
		})
	}))
	defer srv.Close()
	c := &LoginClient{ProfileBaseURL: srv.URL}
	p, err := c.FetchProfile(context.Background(), "at-123")
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer at-123" {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if p.EmailAddress != "who@example.com" || p.AccountUUID != "u-1" || p.OrgUUID != "o-1" || p.DisplayName != "Who" {
		t.Errorf("Profile = %+v", p)
	}
}

func TestFetchProfileErrorCarriesNoBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"leak":"bearer-echo"}`))
	}))
	defer srv.Close()
	c := &LoginClient{ProfileBaseURL: srv.URL}
	_, err := c.FetchProfile(context.Background(), "at")
	if err == nil || strings.Contains(err.Error(), "leak") || strings.Contains(err.Error(), "bearer-echo") {
		t.Fatalf("profile error surfaces body: %v", err)
	}
}

func TestFetchProfileInterlockRefusesProduction(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	c := &LoginClient{}
	_, err := c.FetchProfile(context.Background(), "at")
	if err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Fatalf("production profile fetch under LLMPILOT_TEST not refused: %v", err)
	}
}

func TestMintOAuthCred(t *testing.T) {
	res := ExchangeResult{
		AccessToken:  "at-mint",
		RefreshToken: "rt-mint",
		ExpiresAt:    time.UnixMilli(1_800_000_000_000),
		Scopes:       []string{"user:inference"},
	}
	blob, err := MintOAuthCred(res)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseOAuthCred(blob)
	if err != nil {
		t.Fatal(err)
	}
	if got.AccessToken != "at-mint" || got.RefreshToken != "rt-mint" || !got.ExpiresAt.Equal(res.ExpiresAt) || len(got.Scopes) != 1 {
		t.Errorf("round-trip = %+v", got)
	}

	if _, err := MintOAuthCred(ExchangeResult{RefreshToken: "rt", ExpiresAt: res.ExpiresAt}); err == nil {
		t.Error("mint without access token accepted")
	}
	if _, err := MintOAuthCred(ExchangeResult{AccessToken: "at", RefreshToken: "rt"}); err == nil {
		t.Error("mint without expiry accepted")
	}
}
