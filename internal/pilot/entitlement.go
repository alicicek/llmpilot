package pilot

import (
	"bytes"
	"crypto/ed25519"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/alicicek/llmpilot/pilotapi"
)

var (
	ErrInvalidEntitlement = errors.New("invalid entitlement")
	ErrUnknownKey         = errors.New("unknown entitlement key")
	ErrExpiredTrial       = errors.New("trial entitlement expired")
)

//go:embed public_keys.json
var embeddedPublicKeys []byte

type publicKeyRecord struct {
	KeyID     string `json:"key_id"`
	PublicKey string `json:"public_key"`
}

// EmbeddedKeyring returns the rotation-safe verifier set shipped with this
// app build. Adding a new key never removes verification for older grants.
func EmbeddedKeyring() (map[string]ed25519.PublicKey, error) {
	var records []publicKeyRecord
	if err := json.Unmarshal(embeddedPublicKeys, &records); err != nil {
		return nil, fmt.Errorf("decode entitlement keyring: %w", err)
	}
	out := make(map[string]ed25519.PublicKey, len(records))
	for _, record := range records {
		raw, err := base64.StdEncoding.DecodeString(record.PublicKey)
		if err != nil || len(raw) != ed25519.PublicKeySize || record.KeyID == "" {
			return nil, fmt.Errorf("%w: malformed public key record", ErrInvalidEntitlement)
		}
		if _, exists := out[record.KeyID]; exists {
			return nil, fmt.Errorf("%w: duplicate key id %q", ErrInvalidEntitlement, record.KeyID)
		}
		out[record.KeyID] = ed25519.PublicKey(raw)
	}
	return out, nil
}

// VerifyEntitlement verifies LLMP2.<base64url-payload>.<base64url-signature>
// against a key selected by the signed key_id. Unknown keys fail closed, and
// so does the LLMP1 shape: no unbound pre-8.1 token exists in the wild.
func VerifyEntitlement(token string, keys map[string]ed25519.PublicKey, now time.Time) (pilotapi.EntitlementPayload, error) {
	var zero pilotapi.EntitlementPayload
	parts := bytes.Split([]byte(token), []byte("."))
	if len(parts) != 3 || string(parts[0]) != "LLMP2" {
		return zero, ErrInvalidEntitlement
	}
	body, err := base64.RawURLEncoding.DecodeString(string(parts[1]))
	if err != nil {
		return zero, ErrInvalidEntitlement
	}
	var payload pilotapi.EntitlementPayload
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&payload); err != nil {
		return zero, ErrInvalidEntitlement
	}
	if err := dec.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return zero, ErrInvalidEntitlement
	}
	key, ok := keys[payload.KeyID]
	if !ok {
		return zero, fmt.Errorf("%w: %s", ErrUnknownKey, payload.KeyID)
	}
	sig, err := base64.RawURLEncoding.DecodeString(string(parts[2]))
	if err != nil || len(sig) != ed25519.SignatureSize || !ed25519.Verify(key, parts[1], sig) {
		return zero, ErrInvalidEntitlement
	}
	if err := validatePayload(payload, now); err != nil {
		return zero, err
	}
	return payload, nil
}

func validatePayload(payload pilotapi.EntitlementPayload, now time.Time) error {
	if payload.Tier != "pro" || payload.Seats < 1 || payload.KeyID == "" || len(payload.Features) == 0 {
		return ErrInvalidEntitlement
	}
	if payload.Install == "" || payload.IssuedAt.IsZero() {
		return ErrInvalidEntitlement
	}
	switch payload.Kind {
	case pilotapi.EntitlementTrial:
		if payload.ExpiresAt == nil {
			return ErrInvalidEntitlement
		}
		if !now.Before(*payload.ExpiresAt) {
			return ErrExpiredTrial
		}
	case pilotapi.EntitlementLifetime:
		if payload.ExpiresAt != nil {
			return ErrInvalidEntitlement
		}
	default:
		return ErrInvalidEntitlement
	}
	return nil
}
