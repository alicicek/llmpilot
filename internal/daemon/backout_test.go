package daemon

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// getLicenseInfo fetches the public GET /v1/license view.
func getLicenseInfo(t *testing.T, srvURL string) map[string]any {
	t.Helper()
	resp, err := http.Get(srvURL + "/v1/license")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("license view decode: %v (%s)", err, raw)
	}
	return m
}

func outcome(t *testing.T, srvURL string) string {
	t.Helper()
	v, _ := getLicenseInfo(t, srvURL)["checkout_outcome"].(string)
	return v
}

// TestCheckoutDeclinedSignalArmsOutcomeAndPaymentSupersedes walks the real
// wire: press → pending polls → the worker records the browser back-arrow →
// the very next poll surfaces "declined" on GET /v1/license → a history-back
// payment lands → the verdict clears and the grant persists.
func TestCheckoutDeclinedSignalArmsOutcomeAndPaymentSupersedes(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(4 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)

	var declined, paid atomic.Bool
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_back1", "license": "lic_back0001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			if paid.Load() {
				writeJSON(w, 200, map[string]any{"license": "lic_back0001", "status": "trialing", "trial_end": trialEnd.Format(time.RFC3339), "entitlement": token})
				return
			}
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending", "declined": declined.Load()})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`)
	if resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	if got := outcome(t, srv.URL); got != "" {
		t.Fatalf("outcome before any signal = %q, want empty", got)
	}

	declined.Store(true)
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "declined" })

	paid.Store(true)
	waitFor(t, 2*time.Second, func() bool { return store.current().Status == "trialing" })
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "" })
}

// TestCheckoutDeadlineLapseIsTheAbandonedVerdict: silence (tab closed, no
// back-arrow) arms at the poll deadline — and only the deadline, never a
// refusal code.
func TestCheckoutDeadlineLapseIsTheAbandonedVerdict(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_silent1", "license": "lic_silent01", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending"})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	d.License.PollFor = 80 * time.Millisecond
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "abandoned" })
	if ec, _ := getLicenseInfo(t, srv.URL)["error_code"].(string); ec != "" {
		t.Fatalf("abandoned must not be an error, got error_code %q", ec)
	}
}

// TestAbandonedNeverDowngradesADeclinedVerdict: the fast deadline lapsing
// AFTER the back-arrow was recorded keeps the more specific verdict — a
// declined checkout's session is already expired server-side, so the poll
// ENDS there instead of entering the reconcile phase or writing "abandoned".
func TestAbandonedNeverDowngradesADeclinedVerdict(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_dec1", "license": "lic_dec00001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending", "declined": true})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	d.License.PollFor = 80 * time.Millisecond
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "declined" })
	// Let the 80ms deadline lapse well past, then re-read: still declined.
	time.Sleep(200 * time.Millisecond)
	if got := outcome(t, srv.URL); got != "declined" {
		t.Fatalf("deadline downgraded the verdict to %q", got)
	}
}

// TestStaleGenerationNeverWritesAVerdict pins the gen guard at the unit
// level: over the wire, cancelling a superseded poll usually aborts its HTTP
// call too, so the guard's real target — a response already decoded when the
// supersede lands, about to write — is a race the wire tests can't force.
func TestStaleGenerationNeverWritesAVerdict(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	d := licenseDaemon(t, "http://127.0.0.1:0", &memLicenseStore{}, pub, true, nil, time.Now())
	d.mu.Lock()
	d.checkoutPollGen = 2 // a newer press owns the verdict now
	d.mu.Unlock()

	d.setCheckoutOutcome(t.Context(), 1, "declined") // the superseded poll's late write
	d.mu.Lock()
	got := d.checkoutOutcome
	d.mu.Unlock()
	if got != "" {
		t.Fatalf("stale generation wrote verdict %q", got)
	}

	d.setCheckoutOutcome(t.Context(), 2, "declined") // the current one still may
	d.mu.Lock()
	got = d.checkoutOutcome
	d.mu.Unlock()
	if got != "declined" {
		t.Fatalf("current generation write lost, got %q", got)
	}
}

// TestLatePaymentInTheReconcilePhaseStillActivates: past the 10-minute
// verdict the SESSION is still payable for its 24h life (owner: the
// come-back-later tab stays alive) — a buyer who pays at "minute 12" must
// still receive their grant, not a paid-but-dark app (money review
// 2026-08-27 F3). The poll drops to the slow reconcile cadence and the late
// activation lands, clearing the armed verdict.
func TestLatePaymentInTheReconcilePhaseStillActivates(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(4 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)

	var paid atomic.Bool
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_late1", "license": "lic_late0001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			if paid.Load() {
				writeJSON(w, 200, map[string]any{"license": "lic_late0001", "status": "trialing", "trial_end": trialEnd.Format(time.RFC3339), "entitlement": token})
				return
			}
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending"})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	d.License.PollFor = 60 * time.Millisecond
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "abandoned" })

	paid.Store(true) // "minute 12": the still-open tab completes
	waitFor(t, 2*time.Second, func() bool { return store.current().Status == "trialing" })
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "" })
}

// TestLatePaymentAfterAFailedExpireStillActivates (re-review F11): the
// back-out's server-side expire is BEST-EFFORT — when it fails transiently,
// the declined session stays payable, so the declined path must reconcile
// exactly like the abandoned one. A minute-12 browser-Back payment on a
// declined-but-alive session still lands its grant, and the more specific
// declined verdict is never downgraded to abandoned along the way.
func TestLatePaymentAfterAFailedExpireStillActivates(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(4 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)

	var paid atomic.Bool
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_fail1", "license": "lic_fail0001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			if paid.Load() {
				writeJSON(w, 200, map[string]any{"license": "lic_fail0001", "status": "trialing", "trial_end": trialEnd.Format(time.RFC3339), "entitlement": token})
				return
			}
			// Declined recorded, but the expire failed: session still open,
			// so NO session_expired flag ever arrives.
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending", "declined": true})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	store := &memLicenseStore{}
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	d.License.PollFor = 60 * time.Millisecond
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "declined" })
	// Let the fast deadline lapse — the reconcile phase must carry on.
	time.Sleep(150 * time.Millisecond)
	if got := outcome(t, srv.URL); got != "declined" {
		t.Fatalf("verdict downgraded to %q past the fast deadline", got)
	}

	paid.Store(true) // "minute 12": browser-Back on the surviving session
	waitFor(t, 2*time.Second, func() bool { return store.current().Status == "trialing" })
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "" })
}

// TestReconcileEndsOnceTheSessionExpires (re-review F12): the reconcile's
// stop condition is the worker REPORTING session_expired — not a local
// assumption — and once it arrives the poll goroutine is done instead of
// burning a day of metered calls on a session nothing can pay.
func TestReconcileEndsOnceTheSessionExpires(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var expired atomic.Bool
	var activateCalls atomic.Int32
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			writeJSON(w, 200, map[string]string{"sessionId": "cs_exp1", "license": "lic_exp00001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			activateCalls.Add(1)
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending", "session_expired": expired.Load()})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	d.License.PollFor = 60 * time.Millisecond
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
		t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
	}
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "abandoned" })

	expired.Store(true)
	// Give the poll a few ticks to see the flag, then require silence.
	time.Sleep(100 * time.Millisecond)
	settled := activateCalls.Load()
	time.Sleep(150 * time.Millisecond)
	if got := activateCalls.Load(); got != settled {
		t.Fatalf("poll kept calling activate after session_expired (%d → %d)", settled, got)
	}
	// The verdict written before expiry stands.
	if got := outcome(t, srv.URL); got != "abandoned" {
		t.Fatalf("outcome = %q after expiry, want abandoned", got)
	}
}

// TestNewerCheckoutPressOwnsTheVerdict: a second press clears the armed
// verdict, and the superseded poll (whose session still reports declined)
// can never re-write it — the verdict belongs to the newest checkout only.
func TestNewerCheckoutPressOwnsTheVerdict(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var presses atomic.Int32
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/checkout":
			n := presses.Add(1)
			id := "cs_first"
			if n > 1 {
				id = "cs_second"
			}
			writeJSON(w, 200, map[string]string{"sessionId": id, "license": "lic_two00001", "url": "https://checkout.example/pay"})
		case "/v1/activate":
			var b map[string]string
			_ = json.NewDecoder(r.Body).Decode(&b)
			// The FIRST session keeps screaming declined; the second stays quiet.
			writeJSON(w, 200, map[string]any{"pending": true, "status": "pending", "declined": b["session_id"] == "cs_first"})
		default:
			t.Errorf("unexpected worker path %q", r.URL.Path)
		}
	}))
	defer worker.Close()

	d := licenseDaemon(t, worker.URL, &memLicenseStore{}, pub, true, nil, time.Now())
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	press := func() {
		if resp, body := postJSON(t, d, srv.URL+"/v1/license/checkout", `{"rung":"full","ui":"hosted","quote":{"trial_days":4,"currency":"gbp","amount_minor":999}}`); resp.StatusCode != 200 {
			t.Fatalf("checkout status = %d (%s)", resp.StatusCode, body)
		}
	}
	press()
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "declined" })
	press()
	waitFor(t, 2*time.Second, func() bool { return outcome(t, srv.URL) == "" })
	// Many poll ticks later the stale loop must still not have re-armed it.
	time.Sleep(100 * time.Millisecond)
	if got := outcome(t, srv.URL); got != "" {
		t.Fatalf("superseded poll re-armed the verdict %q", got)
	}
}
