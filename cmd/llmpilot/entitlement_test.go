package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// LLMPILOT_ENTITLEMENT_URL is the worker BASE origin (the daemon derives
// /v1/validate, /v1/checkout, … from it). The override applies ONLY under the
// test sandbox with a throwaway keychain — a test worker must never be paired
// with the login Keychain.
func TestEntitlementURLRequiresSandboxKeychain(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	t.Setenv("LLMPILOT_ENTITLEMENT_URL", "http://127.0.0.1:9999/") // trailing slash trimmed

	t.Setenv("LLMPILOT_KEYCHAIN", "")
	if got := entitlementBaseURL(); got != "https://api.llmpilot.dev" {
		t.Fatalf("test URL reached login Keychain: %q", got)
	}
	if got := entitlementValidateURL(); got != "https://api.llmpilot.dev/v1/validate" {
		t.Fatalf("validate URL reached login Keychain: %q", got)
	}

	t.Setenv("LLMPILOT_KEYCHAIN", t.TempDir()+"/keychain.json")
	if got := entitlementBaseURL(); got != "http://127.0.0.1:9999" {
		t.Fatalf("sandbox base URL = %q", got)
	}
	if got := entitlementValidateURL(); got != "http://127.0.0.1:9999/v1/validate" {
		t.Fatalf("sandbox validate URL = %q", got)
	}
}

type oneLicense struct{ v pilot.StoredLicense }

func (s *oneLicense) Load(context.Context) (pilot.StoredLicense, error) {
	if s.v.LicenseID == "" {
		return pilot.StoredLicense{}, pilot.ErrNoLicense
	}
	return s.v, nil
}
func (s *oneLicense) Save(_ context.Context, v pilot.StoredLicense) error { s.v = v; return nil }

// Startup takes back the install the stored purchase is signed for — the
// reinstall that wiped ~/.llmpilot — and writes it where the next start
// (and every CLI process) reads it.
func TestLicenseManagerAdoptsThePurchasesInstallAtStart(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	const bound = "6f1c2a3b-4d5e-4f60-8a71-b2c3d4e5f607"
	payload, err := json.Marshal(pilotapi.EntitlementPayload{
		Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime,
		Install: bound, IssuedAt: time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC), KeyID: "key-a",
	})
	if err != nil {
		t.Fatal(err)
	}
	enc := base64.RawURLEncoding.EncodeToString(payload)
	token := "LLMP2." + enc + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, []byte(enc)))

	st := store.At(t.TempDir())
	minted, err := st.InstallID()
	if err != nil {
		t.Fatal(err)
	}
	m := licenseManagerWith(st, &oneLicense{v: pilot.StoredLicense{LicenseID: "lic_start", Entitlement: token, Status: "lifetime"}}, map[string][]byte{"key-a": pub})
	if m.InstallID != bound {
		t.Fatalf("manager install = %q, want the purchase's %q (minted %q)", m.InstallID, bound, minted)
	}
	if got, err := st.InstallID(); err != nil || got != bound {
		t.Fatalf("install.id after start = %q, %v; want %q", got, err, bound)
	}
}
