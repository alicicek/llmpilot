package pilot

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

func signedToken(t *testing.T, keyID string, payload pilotapi.EntitlementPayload, private ed25519.PrivateKey) string {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(body)
	sig := ed25519.Sign(private, []byte(encoded))
	return "LLMP2." + encoded + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func TestVerifyEntitlementKnownKeyAndExpiry(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 12, 0, 0, 0, time.UTC)
	exp := now.Add(time.Hour)
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementTrial, Install: "install-a", IssuedAt: now, ExpiresAt: &exp, KeyID: "key-a"}
	token := signedToken(t, "key-a", p, priv)
	got, err := VerifyEntitlement(token, map[string]ed25519.PublicKey{"key-a": pub}, now)
	if err != nil || got.KeyID != "key-a" {
		t.Fatalf("VerifyEntitlement() = %+v, %v", got, err)
	}
	if _, err := VerifyEntitlement(token, map[string]ed25519.PublicKey{"key-a": pub}, exp); !errors.Is(err, ErrExpiredTrial) {
		t.Fatalf("expiry error = %v, want ErrExpiredTrial", err)
	}
}

func TestVerifyEntitlementRejectsUnknownKeyID(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: time.Now().UTC(), KeyID: "rotated-away"}
	token := signedToken(t, "rotated-away", p, priv)
	if _, err := VerifyEntitlement(token, map[string]ed25519.PublicKey{}, time.Now()); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("unknown key error = %v, want ErrUnknownKey", err)
	}
}

func TestVerifyEntitlementRejectsTamperingAndUnknownFields(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"wake"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: time.Now().UTC(), KeyID: "key-a"}
	token := signedToken(t, "key-a", p, priv)
	parts := strings.Split(token, ".")
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		t.Fatal(err)
	}
	sig[0] ^= 0x80
	tampered := parts[0] + "." + parts[1] + "." + base64.RawURLEncoding.EncodeToString(sig)
	if _, err := VerifyEntitlement(tampered, map[string]ed25519.PublicKey{"key-a": pub}, time.Now()); !errors.Is(err, ErrInvalidEntitlement) {
		t.Fatalf("tamper error = %v", err)
	}
	body := []byte(`{"tier":"pro","features":["wake"],"seats":1,"kind":"lifetime","install":"install-a","issued_at":"2026-07-12T12:00:00Z","expires_at":null,"key_id":"key-a","admin":true}`)
	encoded := base64.RawURLEncoding.EncodeToString(body)
	extra := "LLMP2." + encoded + "." + base64.RawURLEncoding.EncodeToString(ed25519.Sign(priv, []byte(encoded)))
	if _, err := VerifyEntitlement(extra, map[string]ed25519.PublicKey{"key-a": pub}, time.Now()); !errors.Is(err, ErrInvalidEntitlement) {
		t.Fatalf("unknown field error = %v", err)
	}
}

func TestVerifyEntitlementRequiresBindingClaims(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keys := map[string]ed25519.PublicKey{"key-a": pub}
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	base := pilotapi.EntitlementPayload{Tier: "pro", Features: []string{"autopilot"}, Seats: 1, Kind: pilotapi.EntitlementLifetime, Install: "install-a", IssuedAt: now, KeyID: "key-a"}

	noInstall := base
	noInstall.Install = ""
	if _, err := VerifyEntitlement(signedToken(t, "key-a", noInstall, priv), keys, now); !errors.Is(err, ErrInvalidEntitlement) {
		t.Fatalf("missing install error = %v, want ErrInvalidEntitlement", err)
	}

	noIssued := base
	noIssued.IssuedAt = time.Time{}
	if _, err := VerifyEntitlement(signedToken(t, "key-a", noIssued, priv), keys, now); !errors.Is(err, ErrInvalidEntitlement) {
		t.Fatalf("missing issued_at error = %v, want ErrInvalidEntitlement", err)
	}

	// The pre-8.1 LLMP1 shape stays dead even with a valid signature: no
	// unbound token may verify.
	legacy := signedToken(t, "key-a", base, priv)
	legacy = "LLMP1" + strings.TrimPrefix(legacy, "LLMP2")
	if _, err := VerifyEntitlement(legacy, keys, now); !errors.Is(err, ErrInvalidEntitlement) {
		t.Fatalf("LLMP1 magic error = %v, want ErrInvalidEntitlement", err)
	}
}
