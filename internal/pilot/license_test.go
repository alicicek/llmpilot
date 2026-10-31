package pilot

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

type memoryLicenseStore struct {
	mu sync.Mutex
	v  StoredLicense
}

func (s *memoryLicenseStore) Load(context.Context) (StoredLicense, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.v.LicenseID == "" {
		return StoredLicense{}, ErrNoLicense
	}
	return s.v, nil
}
func (s *memoryLicenseStore) Save(_ context.Context, v StoredLicense) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.v = v
	return nil
}

func TestLicenseManagerOfflineGraceAndWeeklyDue(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_stable", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "lifetime", StoredAt: now, LastValidated: now,
	}}
	m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}, OfflineGrace: 30 * 24 * time.Hour, CheckInterval: 7 * 24 * time.Hour}
	if !m.Allowed(context.Background(), "autopilot", now.Add(29*24*time.Hour)) {
		t.Fatal("offline grace ended early")
	}
	if m.Allowed(context.Background(), "autopilot", now.Add(31*24*time.Hour)) {
		t.Fatal("offline grace never ended")
	}
	if m.Due(context.Background(), now.Add(5*24*time.Hour)) {
		t.Fatal("weekly check due too early")
	}
	if !m.Due(context.Background(), now.Add(9*24*time.Hour)) {
		t.Fatal("weekly check not due after jitter window")
	}
}

func TestLicenseManagerFutureSignedIssuedAtStillForcesRevalidation(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	// issued_at an hour ahead of the local clock: signed, so it cannot be a
	// forgery — a slow clock right after purchase must not brick Pro, but the
	// oddity still forces the authoritative online check.
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now.Add(time.Hour), KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_future", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "lifetime", StoredAt: now, LastValidated: now,
	}}
	m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}}
	if !m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("signed future issued_at bricked a fresh purchase offline")
	}
	if !m.Due(context.Background(), now) {
		t.Fatal("future issued_at deferred online revalidation")
	}
}

func TestAllowedRefusesForeignInstall(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_copied", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "lifetime", StoredAt: now, LastValidated: now,
	}}
	// The Keychain item copied to another Mac: same signed token, different
	// local install id. Entirely offline, this must fail closed.
	m := &LicenseManager{Store: store, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}}
	if m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("token bound to install-a was accepted on install-b")
	}
	m.InstallID = "install-a"
	if !m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("token refused on its own install")
	}
	// An unwired (empty) install id must refuse rather than skip the check.
	m.InstallID = ""
	if m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("empty local install id accepted a bound token")
	}
}

func TestEditedStatusCannotOutliveSignedIssuedAt(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issued := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: issued, KeyID: "key-a"}
	// A revoked license whose Keychain JSON was hand-edited back to healthy:
	// Status flipped to lifetime and both unsigned timestamps pushed 90 days
	// ahead. Only the signed issued_at may bound offline access.
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_edited", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "lifetime", StoredAt: issued.Add(90 * 24 * time.Hour), LastValidated: issued.Add(90 * 24 * time.Hour),
	}}
	m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}}
	grace := 30 * 24 * time.Hour
	if !m.Allowed(context.Background(), "autopilot", issued.Add(grace-time.Hour)) {
		t.Fatal("access ended before one grace window past signed issued_at")
	}
	if m.Allowed(context.Background(), "autopilot", issued.Add(grace+time.Hour)) {
		t.Fatal("edited unsigned timestamps extended access past signed issued_at + grace")
	}
}

func TestLicenseManagerCancelledTrialPausesOfflineAtSignedExpiry(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	expires := now.Add(8 * 24 * time.Hour)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementTrial, Install: "install-a", IssuedAt: now, ExpiresAt: &expires, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_cancelled", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "trialing", StoredAt: now, LastValidated: now,
	}}
	m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}}
	if !m.Allowed(context.Background(), "autopilot", expires.Add(-time.Nanosecond)) {
		t.Fatal("trial paused before signed expiry")
	}
	if m.Allowed(context.Background(), "autopilot", expires) {
		t.Fatal("cancelled trial retained Pro at signed expiry while offline")
	}
}

func TestLicenseManagerRevalidationRevokesAndPersists(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"wake"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_x", Entitlement: signedToken(t, "key-a", p, priv), Status: "lifetime", StoredAt: now, LastValidated: now}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() { _ = r.Body.Close() }()
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["license"] != "lic_x" {
			t.Errorf("request body = %v, %v", body, err)
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "revoked"})
	}))
	defer srv.Close()
	m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}, ValidateURL: srv.URL, Now: func() time.Time { return now.Add(8 * 24 * time.Hour) }}
	status, err := m.Revalidate(context.Background())
	if err != nil || status != "revoked" {
		t.Fatalf("Revalidate() = %q, %v", status, err)
	}
	if m.Allowed(context.Background(), "wake", now.Add(8*24*time.Hour)) {
		t.Fatal("revoked entitlement still allowed")
	}
}

// A reinstall that wiped ~/.llmpilot mints a fresh install id while the
// purchase in the Keychain stays signed for the old one. The manager takes
// the signed binding back instead of locking a paying user out of Pro on
// the Mac they bought it on.
func TestAdoptBoundInstallRestoresThePurchasesOwnInstall(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_reinstalled", Entitlement: signedToken(t, "key-a", p, priv),
		Status: "lifetime", StoredAt: now, LastValidated: now,
	}}
	m := &LicenseManager{Store: store, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}, Now: func() time.Time { return now }}
	if m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("precondition: the fresh install id should not unlock the purchase")
	}
	var persisted []string
	if !m.AdoptBoundInstall(context.Background(), func(id string) error { persisted = append(persisted, id); return nil }) {
		t.Fatal("the purchase's own install was not adopted")
	}
	if m.InstallID != "install-a" || len(persisted) != 1 || persisted[0] != "install-a" {
		t.Fatalf("InstallID = %q, persisted %v; want install-a written once", m.InstallID, persisted)
	}
	if !m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("Pro stayed locked after adopting the purchase's install")
	}
	// Already matching: nothing to write.
	if m.AdoptBoundInstall(context.Background(), func(string) error { t.Fatal("rewrote a matching id"); return nil }) {
		t.Fatal("reported an adoption for an id that already matched")
	}
}

func TestAdoptBoundInstallIgnoresWhatItCannotTrust(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, otherPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	expiredTrial := p
	expiredTrial.Kind = pilotapi.EntitlementTrial
	end := now.Add(-time.Hour)
	expiredTrial.ExpiresAt = &end
	cases := map[string]*memoryLicenseStore{
		"no purchase stored":                     {},
		"signed by a key the app does not trust": {v: StoredLicense{LicenseID: "lic_forged", Entitlement: signedToken(t, "key-a", p, otherPriv), Status: "lifetime"}},
		"not a token at all":                     {v: StoredLicense{LicenseID: "lic_junk", Entitlement: "LLMP2.e30.AAAA", Status: "lifetime"}},
	}
	for name, store := range cases {
		m := &LicenseManager{Store: store, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}, Now: func() time.Time { return now }}
		if m.AdoptBoundInstall(context.Background(), func(string) error { t.Errorf("%s: wrote an install id", name); return nil }) {
			t.Errorf("%s: adopted", name)
		}
		if m.InstallID != "install-b" {
			t.Errorf("%s: InstallID changed to %q", name, m.InstallID)
		}
	}
	// An expired trial's signature still proves its binding — the server may
	// have converted it to a purchase — so it is adopted.
	expired := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_expired", Entitlement: signedToken(t, "key-a", expiredTrial, priv), Status: "trialing"}}
	m := &LicenseManager{Store: expired, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}, Now: func() time.Time { return now }}
	if !m.AdoptBoundInstall(context.Background(), func(string) error { return nil }) || m.InstallID != "install-a" {
		t.Fatalf("an expired trial's genuine binding was not adopted: %q", m.InstallID)
	}

	// A write that fails keeps the current id: memory never runs ahead of disk.
	store := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_ro", Entitlement: signedToken(t, "key-a", p, priv), Status: "lifetime"}}
	m = &LicenseManager{Store: store, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}, Now: func() time.Time { return now }}
	if m.AdoptBoundInstall(context.Background(), func(string) error { return errors.New("read-only") }) || m.InstallID != "install-b" {
		t.Fatalf("a failed write still switched the install id to %q", m.InstallID)
	}
}

func TestBoundElsewhereOnlyForAGenuineForeignBinding(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	store := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_x", Entitlement: signedToken(t, "key-a", p, priv), Status: "lifetime"}}
	m := &LicenseManager{Store: store, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}}
	if !m.BoundElsewhere(context.Background()) {
		t.Fatal("a purchase signed for install-a was not reported as bound elsewhere on install-b")
	}
	m.InstallID = "install-a"
	if m.BoundElsewhere(context.Background()) {
		t.Fatal("a purchase on its own install was reported as bound elsewhere")
	}
	if (&LicenseManager{Store: &memoryLicenseStore{}, InstallID: "install-b", Keys: map[string][]byte{"key-a": pub}}).BoundElsewhere(context.Background()) {
		t.Fatal("no purchase at all was reported as bound elsewhere")
	}
}

// The server refusing an install with no seat is named, not a bare HTTP
// status: it is what tells the app to offer the email restore.
func TestRevalidateNamesTheNoSeatRefusal(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}
	for _, tc := range []struct {
		status int
		body   string
		named  bool
	}{
		{http.StatusForbidden, `{"error":"install_not_activated"}`, true},
		{http.StatusForbidden, `{"error":"something_else"}`, false},
		{http.StatusInternalServerError, `{"error":"install_not_activated"}`, false},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.body))
		}))
		store := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_x", Entitlement: signedToken(t, "key-a", p, priv), Status: "lifetime"}}
		m := &LicenseManager{Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub}, ValidateURL: srv.URL, HTTP: srv.Client()}
		_, err := m.Revalidate(context.Background())
		srv.Close()
		if err == nil {
			t.Fatalf("%d %s: refusal returned no error", tc.status, tc.body)
		}
		if got := errors.Is(err, ErrInstallNotActivated); got != tc.named {
			t.Errorf("%d %s: errors.Is(ErrInstallNotActivated) = %v, want %v", tc.status, tc.body, got, tc.named)
		}
	}
}

// The whole reinstall, with the parts production really has: the wipe took
// install.id AND the clock anchor, so even after adopting the purchase's own
// install Pro stays off until one online check answers — then it is on.
func TestReinstallComesBackAfterOneOnlineCheck(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	issued := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	now := time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: issued, KeyID: "key-a"}
	fresh := p
	fresh.IssuedAt = now
	var sawInstall string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		sawInstall = body["install_id"]
		if sawInstall != "install-a" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":"install_not_activated"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "lifetime", "entitlement": signedToken(t, "key-a", fresh, priv)})
	}))
	defer srv.Close()
	store := &memoryLicenseStore{v: StoredLicense{LicenseID: "lic_back", Entitlement: signedToken(t, "key-a", p, priv), Status: "lifetime"}}
	m := &LicenseManager{
		Store: store, InstallID: "install-fresh", Keys: map[string][]byte{"key-a": pub},
		Anchor: &TimeAnchor{Dir: t.TempDir()}, ValidateURL: srv.URL, HTTP: srv.Client(),
		Now: func() time.Time { return now },
	}
	if !m.AdoptBoundInstall(context.Background(), func(string) error { return nil }) {
		t.Fatal("the purchase's install was not adopted")
	}
	if m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("precondition: with the clock anchor gone, Pro waits for the online check")
	}
	if _, err := m.Revalidate(context.Background()); err != nil {
		t.Fatalf("online check: %v", err)
	}
	if sawInstall != "install-a" {
		t.Fatalf("the check asked for install %q, want the adopted install-a", sawInstall)
	}
	if !m.Allowed(context.Background(), "autopilot", now) {
		t.Fatal("Pro stayed off after the online check accepted the purchase's own install")
	}
}
