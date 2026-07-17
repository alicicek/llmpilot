package pilotapi

import (
	"testing"
	"time"
)

func TestEntitlementAllowsEnforcesTrialExpiryOffline(t *testing.T) {
	exp := time.Date(2026, 7, 20, 12, 0, 0, 0, time.UTC)
	p := EntitlementPayload{
		Tier: "pro", Features: []string{"autopilot"}, Seats: 1,
		Kind: EntitlementTrial, ExpiresAt: &exp, KeyID: "2026-07-a",
	}
	if !p.Allows("autopilot", exp.Add(-time.Nanosecond)) {
		t.Fatal("trial should allow the feature before signed expiry")
	}
	if p.Allows("autopilot", exp) {
		t.Fatal("trial must pause at signed expiry without a network check")
	}
	if p.Allows("scheduling", exp.Add(-time.Hour)) {
		t.Fatal("ungranted feature was allowed")
	}
}

func TestEntitlementAllowsLifetimeHasNoExpiry(t *testing.T) {
	p := EntitlementPayload{
		Tier: "pro", Features: []string{"wake"}, Seats: 1,
		Kind: EntitlementLifetime, KeyID: "2026-07-a",
	}
	if !p.Allows("wake", time.Date(2126, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatal("lifetime entitlement unexpectedly expired")
	}
	exp := time.Now().Add(time.Hour)
	p.ExpiresAt = &exp
	if p.Allows("wake", time.Now()) {
		t.Fatal("lifetime payload carrying expires_at must be rejected")
	}
}
