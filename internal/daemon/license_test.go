package daemon

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/pilotapi"
)

// memLicenseStore is an in-memory LicenseStore — daemon license tests NEVER
// touch a real or throwaway Keychain (the money path binds the sandbox rule).
type memLicenseStore struct {
	mu    sync.Mutex
	v     pilot.StoredLicense
	saves int
}

func (s *memLicenseStore) Load(context.Context) (pilot.StoredLicense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.v.LicenseID == "" {
		return pilot.StoredLicense{}, pilot.ErrNoLicense
	}
	return s.v, nil
}

func (s *memLicenseStore) Save(_ context.Context, v pilot.StoredLicense) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.v = v
	s.saves++
	return nil
}

func (s *memLicenseStore) current() pilot.StoredLicense {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.v
}

// syncBuffer is a goroutine-safe log sink: the activation poller keeps
// logging from its own goroutine after the test's waitFor condition already
// holds, so an unsynchronized bytes.Buffer read is a data race under -race.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func signToken(t *testing.T, keyID string, p pilotapi.EntitlementPayload, priv ed25519.PrivateKey) string {
	t.Helper()
	p.KeyID = keyID
	body, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding.EncodeToString(body)
	sig := ed25519.Sign(priv, []byte(enc))
	return "LLMP2." + enc + "." + base64.RawURLEncoding.EncodeToString(sig)
}

var testIssuedAt = time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)

func proTrial(exp time.Time) pilotapi.EntitlementPayload {
	return pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot", "scheduling", "wake"}, Seats: 1, Kind: pilotapi.EntitlementTrial, Install: "install-a", IssuedAt: testIssuedAt, ExpiresAt: &exp}
}

func proLifetime() pilotapi.EntitlementPayload {
	return pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot", "scheduling", "wake"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: testIssuedAt}
}

// licenseDaemon wires a Daemon whose license gate uses the real HTTP client
// against workerURL — exercising the true wire contract, not a mock.
func licenseDaemon(t *testing.T, workerURL string, store pilot.LicenseStore, pub ed25519.PublicKey, available bool, logw io.Writer, now time.Time) *Daemon {
	t.Helper()
	gate := &LicenseGate{
		Manager:   &pilot.LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}},
		Client:    NewEntitlementClient(workerURL, "install-a", &http.Client{Timeout: 2 * time.Second}),
		Available: available,
		PollEvery: 5 * time.Millisecond,
		PollFor:   2 * time.Second,
		Now:       func() time.Time { return now },
	}
	d := &Daemon{Store: testStore(t), License: gate}
	if logw != nil {
		d.Log = slog.New(slog.NewTextHandler(logw, &slog.HandlerOptions{Level: slog.LevelDebug}))
	}
	d.init()
	return d
}

// postJSON posts with d's install token attached — the happy path every
// legitimate client (cockpit, menu bar, e2e script) follows. The 401 paths
// are pinned separately in auth_test.go.
func postJSON(t *testing.T, d *Daemon, url, body string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+d.authToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, string(raw)
}

func TestLicenseCheckoutPollsUntilActivatedAndPersists(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(8 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)

	var activateCalls atomic.Int32
	var logs syncBuffer
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			if b["rung"] != "discount_trial" || b["ui"] != "embedded" {
				t.Errorf("checkout body = %v", b)
			}
			writeJSON(w, 200, map[string]string{"sessionId": "cs_test123", "license": "lic_abc0000feed", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			if b["session_id"] != "cs_test123" {
				t.Errorf("activate session = %q", b["session_id"])
			}
			if activateCalls.Add(1) < 2 { // first poll: not paid yet
				writeJSON(w, 200, map[string]any{"pending": true, "status": "pending"})
				return
			}
			writeJSON(w, 200, map[string]any{"license": "lic_abc0000feed", "status": "trialing", "trial_end": trialEnd.Format(time.RFC3339), "entitlement": token})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, &logs, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"discount_trial"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if got["url"] != "https://checkout.example/pay" || got["session_id"] != "cs_test123" {
		t.Fatalf("checkout returned %v", got)
	}

	// The poller activates silently in the background.
	waitFor(t, 2*time.Second, func() bool { return store.current().Status == "trialing" })
	cur := store.current()
	if cur.LicenseID != "lic_abc0000feed" || cur.Entitlement != token {
		t.Fatalf("stored license = %+v", cur)
	}
	if cur.TrialEnd == nil || !cur.TrialEnd.Equal(trialEnd) {
		t.Fatalf("stored trial_end = %v, want %v", cur.TrialEnd, trialEnd)
	}
	if activateCalls.Load() < 2 {
		t.Fatalf("poller stopped before success (calls=%d)", activateCalls.Load())
	}

	// The signed token and license id must never reach a log line. Wait for
	// the poller's post-persist "license activated" line so the check covers
	// the whole poll lifecycle, not just what raced in before persist.
	waitFor(t, 2*time.Second, func() bool { return strings.Contains(logs.String(), "license activated") })
	if s := logs.String(); strings.Contains(s, token) || strings.Contains(s, "LLMP2") || strings.Contains(s, "lic_abc0000feed") {
		t.Fatalf("token or license id leaked into logs:\n%s", s)
	}
}

func TestLicenseQuoteProxiesWorkerTerms(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	const workerQuote = `{"trial_days":8,"charge_date":"2026-07-23T12:00:00Z","prices":{"full":{"gbp":999,"usd":1299},"discount":{"gbp":599,"usd":799}}}`
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/quote" {
			t.Errorf("unexpected worker call %s %s", r.Method, r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(workerQuote))
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	// No install token: the quote is public pricing, deliberately open.
	resp, err := http.Get(srv.URL + "/v1/license/quote")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != 200 || strings.TrimSpace(string(body)) != workerQuote {
		t.Fatalf("quote proxy = %d %s", resp.StatusCode, body)
	}
}

func TestLicenseQuoteUnavailableOnSourceBuild(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	d := licenseDaemon(t, "http://unused.invalid", &panicStore{t: t}, pub, false, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/v1/license/quote")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("source build quote = %d, want 501", resp.StatusCode)
	}
}

func TestCheckoutForwardsQuoteEchoVerbatim(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	echo := map[string]any{"trial_days": float64(8), "currency": "gbp", "amount_minor": float64(599)}
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/checkout" {
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
		var b map[string]any
		_ = json.NewDecoder(r.Body).Decode(&b)
		got, ok := b["quote"].(map[string]any)
		if !ok {
			t.Errorf("worker saw no quote echo: %v", b)
		} else {
			for k, want := range echo {
				if got[k] != want {
					t.Errorf("echo[%s] = %v, want %v", k, got[k], want)
				}
			}
		}
		// A refused echo must surface its machine code through the daemon.
		writeJSON(w, http.StatusConflict, map[string]string{"error": "quote_stale"})
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout",
		`{"rung":"discount_trial","quote":{"trial_days":8,"currency":"gbp","amount_minor":599}}`)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("stale-quote checkout = %d (%s), want the worker's 409", resp.StatusCode, body)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if got["code"] != "quote_stale" || got["error"] == "" {
		t.Fatalf("stale-quote body = %v (want machine code + human copy)", got)
	}
}

func TestLicenseGetComputesTrialViewAndHidesSecrets(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(6 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)
	store := &memLicenseStore{v: pilot.StoredLicense{
		LicenseID: "lic_1111222233334444", Entitlement: token, Status: "trialing",
		TrialEnd: &trialEnd, StoredAt: now, LastValidated: now,
	}}
	d := licenseDaemon(t, "http://unused.invalid", store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/license")
	if err != nil {
		t.Fatal(err)
	}
	var info map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()

	if info["status"] != "trialing" || info["kind"] != "trial" || info["active"] != true {
		t.Fatalf("view = %v", info)
	}
	if info["license_id_masked"] != "lic_••••4444" {
		t.Fatalf("mask = %v", info["license_id_masked"])
	}
	if _, leaked := info["license_id"]; leaked {
		t.Fatal("full license id served without ?reveal=1")
	}
	if _, leaked := info["entitlement"]; leaked {
		t.Fatal("entitlement token served in GET /v1/license")
	}
	trial, ok := info["trial"].(map[string]any)
	if !ok || trial["days_left"].(float64) != 6 {
		t.Fatalf("trial detail = %v", info["trial"])
	}

	// ?reveal=1 with the install token exposes the full id (the Settings copy
	// affordance) but still no entitlement token.
	req, err := http.NewRequest(http.MethodGet, srv.URL+"/v1/license?reveal=1", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+d.authToken)
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var revealed map[string]any
	_ = json.NewDecoder(resp2.Body).Decode(&revealed)
	_ = resp2.Body.Close()
	if revealed["license_id"] != "lic_1111222233334444" {
		t.Fatalf("reveal id = %v", revealed["license_id"])
	}
	if _, leaked := revealed["entitlement"]; leaked {
		t.Fatal("entitlement token served even under ?reveal=1")
	}
}

func TestLicenseGetUnavailableOnSourceBuild(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	// A source build must answer without ever reading the store.
	store := &panicStore{t: t}
	d := licenseDaemon(t, "http://unused.invalid", store, pub, false, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/v1/license")
	if err != nil {
		t.Fatal(err)
	}
	var info map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&info)
	_ = resp.Body.Close()
	if info["available"] != false || info["status"] != "unavailable" {
		t.Fatalf("source build view = %v", info)
	}
	// Checkout must be refused on a build with no engine.
	r2, _ := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full"}`)
	if r2.StatusCode != http.StatusNotImplemented {
		t.Fatalf("source build checkout status = %d, want 501", r2.StatusCode)
	}
}

type panicStore struct{ t *testing.T }

func (p *panicStore) Load(context.Context) (pilot.StoredLicense, error) {
	p.t.Fatal("source build read the entitlement store")
	return pilot.StoredLicense{}, nil
}
func (p *panicStore) Save(context.Context, pilot.StoredLicense) error {
	p.t.Fatal("source build wrote the entitlement store")
	return nil
}

func TestLicenseCancelLapsesAndPausesPro(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(8 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)
	store := &memLicenseStore{v: pilot.StoredLicense{
		LicenseID: "lic_cancelme00001234", Entitlement: token, Status: "trialing",
		TrialEnd: &trialEnd, StoredAt: now, LastValidated: now,
	}}
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/cancel" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		var b map[string]string
		_ = json.NewDecoder(r.Body).Decode(&b)
		if b["license"] != "lic_cancelme00001234" {
			t.Errorf("cancel license = %q", b["license"])
		}
		writeJSON(w, 200, map[string]any{"ok": true, "status": "lapsed"})
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/cancel", `{}`)
	if resp.StatusCode != 200 {
		t.Fatalf("cancel status = %d (%s)", resp.StatusCode, body)
	}
	if store.current().Status != "lapsed" {
		t.Fatalf("status after cancel = %q", store.current().Status)
	}
	// Pro is off the instant the worker reports lapsed, even offline.
	if d.License.Manager.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("cancelled trial kept Pro on")
	}
}

func TestLicenseRecoverIsUniform202(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	var seenEmails []string
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b map[string]string
		_ = json.NewDecoder(r.Body).Decode(&b)
		seenEmails = append(seenEmails, b["email"])
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	for _, email := range []string{`{"email":"known@example.com"}`, `{"email":"nobody@example.com"}`} {
		resp, body := postJSON(t, d, srv.URL+"/v1/license/recover", email)
		if resp.StatusCode != http.StatusAccepted || !strings.Contains(body, `"ok":true`) {
			t.Fatalf("recover status = %d (%s)", resp.StatusCode, body)
		}
	}
	if len(seenEmails) != 2 {
		t.Fatalf("worker saw %d recovery calls", len(seenEmails))
	}
}

func TestLicenseClaimActivatesRecoveredGrant(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	token := signToken(t, "key-a", proLifetime(), priv)
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/recover/claim" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		writeJSON(w, 200, map[string]any{"license": "lic_recovered0000abcd", "status": "lifetime", "entitlement": token})
	}))
	defer worker.Close()
	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/recover/claim", `{"token":"magic-token-123"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("claim status = %d (%s)", resp.StatusCode, body)
	}
	cur := store.current()
	if cur.Status != "lifetime" || cur.Entitlement != token {
		t.Fatalf("recovered store = %+v", cur)
	}
	if !d.License.Manager.Allowed(context.Background(), "wake", now) {
		t.Fatal("recovered lifetime grant did not enable Pro")
	}
}

func TestLicenseMarkerHidesNocardRung(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	// The worker must NEVER be called for a nocard checkout once the marker is set.
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("worker called despite marker: %q", r.URL.Path)
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/marker", `{"present":true}`); resp.StatusCode != 200 {
		t.Fatalf("marker status = %d (%s)", resp.StatusCode, body)
	}
	resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"nocard_trial"}`)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("nocard checkout with marker = %d (%s), want 409", resp.StatusCode, body)
	}
	// The GET view advertises the marker so the ladder hides the rung.
	gresp, err := http.Get(srv.URL + "/v1/license")
	if err != nil {
		t.Fatal(err)
	}
	var info map[string]any
	_ = json.NewDecoder(gresp.Body).Decode(&info)
	_ = gresp.Body.Close()
	if info["nocard_trial_used"] != true {
		t.Fatalf("nocard_trial_used = %v", info["nocard_trial_used"])
	}
}

func TestActivationRefusalStopsPollerAndSurfacesCode(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	var activateCalls atomic.Int32
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			if b["install_id"] != "install-a" {
				t.Errorf("checkout install_id = %q", b["install_id"])
			}
			writeJSON(w, 200, map[string]string{"sessionId": "cs_seat1", "license": "lic_seatcap0000beef", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			if b["install_id"] != "install-a" {
				t.Errorf("activate install_id = %q", b["install_id"])
			}
			activateCalls.Add(1)
			writeJSON(w, http.StatusConflict, map[string]string{"error": "seat_limit_reached"})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full"}`)
	if resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}

	// The typed refusal is terminal: the poller stops instead of retrying
	// against a seat cap for ten minutes.
	waitFor(t, 2*time.Second, func() bool {
		st, err := d.State(context.Background())
		return err == nil && st.LicenseError == "seat_limit_reached"
	})
	calls := activateCalls.Load()
	if calls != 1 {
		t.Fatalf("refused activation was retried (calls=%d)", calls)
	}
	if store.saves != 0 {
		t.Fatalf("refused activation reached the store (saves=%d)", store.saves)
	}

	// GET /v1/license echoes the machine code for the cockpit's copy map.
	gresp, err := http.Get(srv.URL + "/v1/license")
	if err != nil {
		t.Fatal(err)
	}
	var info map[string]any
	_ = json.NewDecoder(gresp.Body).Decode(&info)
	_ = gresp.Body.Close()
	if info["error_code"] != "seat_limit_reached" {
		t.Fatalf("error_code = %v", info["error_code"])
	}

	// A fresh checkout clears the stale refusal before its poll begins.
	d.setLicenseError(context.Background(), "")
	if st, _ := d.State(context.Background()); st.LicenseError != "" {
		t.Fatalf("license_error not cleared: %q", st.LicenseError)
	}
}

func TestClaimRefusalForwardsWorkerCode(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_or_expired"})
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/recover/claim", `{"token":"stale-token"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("claim status = %d (%s), want the worker's 400", resp.StatusCode, body)
	}
	var got map[string]string
	if err := json.Unmarshal([]byte(body), &got); err != nil {
		t.Fatal(err)
	}
	if got["code"] != "invalid_or_expired" || got["error"] == "" {
		t.Fatalf("claim error body = %v (want machine code + human copy)", got)
	}
}

func TestPersistLicenseRejectsUnverifiableToken(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	_, otherPriv, _ := ed25519.GenerateKey(rand.Reader) // signs with a key the app doesn't trust
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	forged := signToken(t, "key-a", proLifetime(), otherPriv)
	store := &memLicenseStore{}
	d := licenseDaemon(t, "http://unused.invalid", store, pub, true, nil, now)
	err := d.persistLicense(context.Background(), LicenseView{License: "lic_forged", Status: "lifetime", Entitlement: forged})
	if err == nil {
		t.Fatal("stored a token signed by an untrusted key")
	}
	if store.saves != 0 {
		t.Fatalf("forged token reached the store (saves=%d)", store.saves)
	}
}

func TestPersistLicenseRejectsForeignInstallToken(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	foreign := proLifetime()
	foreign.Install = "install-b" // validly signed, bound to another Mac
	token := signToken(t, "key-a", foreign, priv)
	store := &memLicenseStore{}
	d := licenseDaemon(t, "http://unused.invalid", store, pub, true, nil, now)
	if err := d.persistLicense(context.Background(), LicenseView{License: "lic_foreign", Status: "lifetime", Entitlement: token}); err == nil {
		t.Fatal("stored an entitlement bound to another install")
	}
	if store.saves != 0 {
		t.Fatalf("foreign-install token reached the store (saves=%d)", store.saves)
	}
}

func waitFor(t *testing.T, d time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not met within deadline")
}
