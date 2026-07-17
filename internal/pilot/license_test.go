package pilot

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
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
