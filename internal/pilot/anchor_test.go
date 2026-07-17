package pilot

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

func TestTimeAnchorObserveAdvancesAndLatchesRollback(t *testing.T) {
	dir := t.TempDir()
	a := &TimeAnchor{Dir: dir}
	base := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)

	// No anchor yet: fail closed, and Observe must not conjure one offline.
	if !a.Regressed(base) {
		t.Fatal("missing anchor did not fail closed")
	}
	a.Observe(base)
	if !a.Regressed(base) {
		t.Fatal("Observe created an anchor without online proof")
	}

	a.Reset(base)
	if a.Regressed(base) {
		t.Fatal("fresh anchor reported regression")
	}
	if a.Regressed(base.Add(-59 * time.Minute)) {
		t.Fatal("clock inside the tolerance failed closed")
	}
	if !a.Regressed(base.Add(-2 * time.Hour)) {
		t.Fatal("rollback past the tolerance was allowed")
	}

	// Observe past the write cadence advances the persisted mark.
	a.Observe(base.Add(24 * time.Hour))
	fresh := &TimeAnchor{Dir: dir}
	if !fresh.Regressed(base.Add(22 * time.Hour)) {
		t.Fatal("advanced high-water mark did not persist")
	}

	// The rollback latch survives the clock recovering.
	a2 := &TimeAnchor{Dir: dir}
	a2.Observe(base) // 24h behind the persisted mark: latches Hold
	if !a2.Regressed(base.Add(25 * time.Hour)) {
		t.Fatal("hold latch cleared without an online revalidate")
	}
	reloaded := &TimeAnchor{Dir: dir}
	if !reloaded.Regressed(base.Add(25 * time.Hour)) {
		t.Fatal("hold latch did not persist across restart")
	}
}

func TestClockRollbackFailsClosedUntilOnlineRevalidate(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	issued := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: issued, KeyID: "key-a"}
	token := signedToken(t, "key-a", p, priv)
	store := &memoryLicenseStore{v: StoredLicense{
		LicenseID: "lic_clock", Entitlement: token,
		Status: "lifetime", StoredAt: issued, LastValidated: issued,
	}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "lifetime", "entitlement": token})
	}))
	defer srv.Close()

	clock := issued
	m := &LicenseManager{
		Store: store, InstallID: "install-a", Keys: map[string][]byte{"key-a": pub},
		Anchor: &TimeAnchor{Dir: dir}, ValidateURL: srv.URL,
		Now: func() time.Time { return clock },
	}
	m.Anchor.Reset(issued) // the online activation that armed the anchor

	if !m.Allowed(context.Background(), "autopilot", issued.Add(-59*time.Minute)) {
		t.Fatal("clock inside the tolerance lost Pro")
	}
	if m.Allowed(context.Background(), "autopilot", issued.Add(-2*time.Hour)) {
		t.Fatal("rolled-back clock kept Pro offline")
	}
	// The latch holds even after the clock returns to honest time.
	if m.Allowed(context.Background(), "autopilot", issued.Add(time.Minute)) {
		t.Fatal("rollback latch cleared without an online revalidate")
	}
	if !m.Due(context.Background(), issued.Add(time.Minute)) {
		t.Fatal("latched rollback did not force revalidation")
	}

	clock = issued.Add(2 * time.Minute)
	if _, err := m.Revalidate(context.Background()); err != nil {
		t.Fatalf("Revalidate() = %v", err)
	}
	if !m.Allowed(context.Background(), "autopilot", issued.Add(3*time.Minute)) {
		t.Fatal("online revalidate did not restore Pro")
	}

	// A deleted anchor fails closed the same way until the next revalidate.
	if err := os.Remove(filepath.Join(dir, "time-anchor.json")); err != nil {
		t.Fatal(err)
	}
	m.Anchor = &TimeAnchor{Dir: dir} // fresh process view of the deleted file
	if m.Allowed(context.Background(), "autopilot", issued.Add(4*time.Minute)) {
		t.Fatal("deleted anchor kept Pro offline")
	}
	if !m.Due(context.Background(), issued.Add(4*time.Minute)) {
		t.Fatal("deleted anchor did not force revalidation")
	}
}
