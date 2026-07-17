package pilotapi

import "time"

// EntitlementKind distinguishes a time-bounded trial from a paid lifetime
// grant. Callers must never infer access from a generic boolean.
type EntitlementKind string

const (
	EntitlementTrial    EntitlementKind = "TRIAL"
	EntitlementLifetime EntitlementKind = "LIFETIME"
)

// EntitlementPayload is the complete signed payload shared by the Worker and
// every app verifier. Keep these JSON names stable: signatures cover the exact
// encoded payload bytes.
type EntitlementPayload struct {
	Tier     string          `json:"tier"`
	Features []string        `json:"features"`
	Seats    int             `json:"seats"`
	Kind     EntitlementKind `json:"kind"`
	// Install binds the grant to one machine's random install id; verifiers
	// refuse a token minted for a different install.
	Install   string     `json:"install"`
	IssuedAt  time.Time  `json:"issued_at"`
	ExpiresAt *time.Time `json:"expires_at"`
	KeyID     string     `json:"key_id"`
}

// Allows reports whether the signed grant currently enables feature. Trial
// expiry is enforced from the signed timestamp with no network dependency.
func (p EntitlementPayload) Allows(feature string, now time.Time) bool {
	if p.Tier != "pro" || p.Seats < 1 {
		return false
	}
	if p.Kind == EntitlementTrial && (p.ExpiresAt == nil || !now.Before(*p.ExpiresAt)) {
		return false
	}
	if p.Kind == EntitlementLifetime && p.ExpiresAt != nil {
		return false
	}
	for _, got := range p.Features {
		if got == feature {
			return true
		}
	}
	return false
}
