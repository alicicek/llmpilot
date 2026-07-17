package main

import "testing"

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
