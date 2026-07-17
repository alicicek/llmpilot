package daemon

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
)

// guardedRoutes enumerates every license route that reveals or mutates. A
// new sensitive route belongs here — the tests below fail closed on the
// whole table.
var guardedRoutes = []struct {
	method, path, body string
}{
	{http.MethodGet, "/v1/license?reveal=1", ""},
	{http.MethodPost, "/v1/license/checkout", `{"rung":"full"}`},
	{http.MethodPost, "/v1/license/cancel", `{}`},
	{http.MethodPost, "/v1/license/recover", `{"email":"a@example.com"}`},
	{http.MethodPost, "/v1/license/recover/claim", `{"token":"tok"}`},
	{http.MethodPost, "/v1/license/marker", `{"present":true}`},
}

func doAuthed(t *testing.T, method, url, body, token string) (*http.Response, string) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, string(raw)
}

// TestLicenseRoutesRequireInstallToken pins the loopback auth boundary: a
// caller who can reach 127.0.0.1 but cannot read daemon.token gets 401 from
// every revealing or mutating license route, and the worker is never touched.
func TestLicenseRoutesRequireInstallToken(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(8 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)
	store := &memLicenseStore{v: pilot.StoredLicense{
		LicenseID: "lic_guard000000secret", Entitlement: token, Status: "trialing",
		TrialEnd: &trialEnd, StoredAt: now, LastValidated: now,
	}}
	// Any worker call from an unauthenticated request is a confused-deputy
	// escape — fail the test, not just the request.
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("worker reached without install token: %s %s", r.Method, r.URL.Path)
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	for _, tok := range []string{"", "not-the-token"} {
		for _, rt := range guardedRoutes {
			resp, body := doAuthed(t, rt.method, srv.URL+rt.path, rt.body, tok)
			if resp.StatusCode != http.StatusUnauthorized {
				t.Errorf("%s %s with token %q = %d (%s), want 401", rt.method, rt.path, tok, resp.StatusCode, body)
			}
			var got map[string]string
			_ = json.Unmarshal([]byte(body), &got)
			if got["code"] != "auth_required" {
				t.Errorf("%s %s code = %q, want auth_required", rt.method, rt.path, got["code"])
			}
			if strings.Contains(body, "lic_guard000000secret") {
				t.Errorf("%s %s leaked the license id in a 401", rt.method, rt.path)
			}
		}
	}

	// The masked read-only view stays open — the statusline/menu bar tier.
	resp, body := doAuthed(t, http.MethodGet, srv.URL+"/v1/license", "", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("masked GET = %d (%s), want 200", resp.StatusCode, body)
	}
	if strings.Contains(body, "lic_guard000000secret") {
		t.Fatal("masked GET leaked the full license id")
	}
	// reveal=1 WITH the token serves the full id (worker still untouched).
	resp, body = doAuthed(t, http.MethodGet, srv.URL+"/v1/license?reveal=1", "", d.authToken)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "lic_guard000000secret") {
		t.Fatalf("authed reveal = %d (%s)", resp.StatusCode, body)
	}
}

// TestAuthFailsClosedWithEmptyToken proves a daemon whose token generation
// failed refuses even an empty Bearer value — "" never matches "".
func TestAuthFailsClosedWithEmptyToken(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	d := licenseDaemon(t, "http://unused.invalid", &memLicenseStore{}, pub, true, nil, time.Now())
	d.authToken = ""
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/license/cancel", `{}`, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("empty-token daemon answered %d (%s), want 401", resp.StatusCode, body)
	}
}

// TestCheckHostRejectsForeignHost pins the DNS-rebinding guard: a request
// carrying a non-loopback Host never reaches any handler.
func TestCheckHostRejectsForeignHost(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	d := licenseDaemon(t, "http://unused.invalid", &memLicenseStore{}, pub, true, nil, time.Now())
	h := d.Handler()

	for _, host := range []string{"127.0.0.1:5555", "localhost:5555", "[::1]:5555", "llmpilot"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/state", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code == http.StatusForbidden {
			t.Errorf("Host %q rejected, want admitted", host)
		}
	}
	for _, host := range []string{"evil.example.com", "evil.example.com:5555", "127.0.0.1.evil.example.com"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/state", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Errorf("Host %q = %d, want 403", host, rec.Code)
		}
	}
}
