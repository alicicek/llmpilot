package anthropic

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// fullBlob mimics a real credential payload: unknown keys at both levels
// must survive a splice byte-for-byte in value.
const fullBlob = `{
  "claudeAiOauth": {
    "accessToken": "old-access",
    "refreshToken": "old-refresh",
    "expiresAt": 1752600000000,
    "scopes": ["user:inference"],
    "subscriptionType": "max",
    "rateLimitTier": {"nested": true}
  },
  "someFutureTopLevel": {"keep": "me"}
}`

func TestParseOAuthCred(t *testing.T) {
	c, err := ParseOAuthCred([]byte(fullBlob))
	if err != nil {
		t.Fatal(err)
	}
	if c.AccessToken != "old-access" || c.RefreshToken != "old-refresh" {
		t.Errorf("tokens = %q/%q", c.AccessToken, c.RefreshToken)
	}
	if !c.ExpiresAt.Equal(time.UnixMilli(1752600000000)) {
		t.Errorf("ExpiresAt = %v", c.ExpiresAt)
	}
	if len(c.Scopes) != 1 || c.Scopes[0] != "user:inference" {
		t.Errorf("Scopes = %v", c.Scopes)
	}

	if _, err := ParseOAuthCred([]byte(`{"noOauth":1}`)); err == nil {
		t.Error("want error for missing claudeAiOauth")
	}
	if _, err := ParseOAuthCred([]byte(`not json`)); err == nil {
		t.Error("want error for invalid JSON")
	}
}

func TestSpliceOAuthCredPreservesUnknownFields(t *testing.T) {
	exp := time.Date(2026, 7, 16, 18, 0, 0, 0, time.UTC)
	out, err := SpliceOAuthCred([]byte(fullBlob), RefreshResult{
		AccessToken:  "new-access",
		RefreshToken: "new-refresh",
		ExpiresAt:    exp,
		Scopes:       []string{"user:inference", "user:profile"},
	})
	if err != nil {
		t.Fatal(err)
	}

	var doc map[string]json.RawMessage
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatal(err)
	}
	if string(doc["someFutureTopLevel"]) != `{"keep":"me"}` {
		t.Errorf("top-level unknown key mangled: %s", doc["someFutureTopLevel"])
	}
	var inner map[string]json.RawMessage
	if err := json.Unmarshal(doc["claudeAiOauth"], &inner); err != nil {
		t.Fatal(err)
	}
	if string(inner["subscriptionType"]) != `"max"` {
		t.Errorf("inner unknown key mangled: %s", inner["subscriptionType"])
	}
	if string(inner["rateLimitTier"]) != `{"nested":true}` {
		t.Errorf("inner nested unknown key mangled: %s", inner["rateLimitTier"])
	}

	got, err := ParseOAuthCred(out)
	if err != nil {
		t.Fatal(err)
	}
	if got.AccessToken != "new-access" || got.RefreshToken != "new-refresh" {
		t.Errorf("spliced tokens = %q/%q", got.AccessToken, got.RefreshToken)
	}
	if !got.ExpiresAt.Equal(exp.Truncate(time.Millisecond)) {
		t.Errorf("spliced ExpiresAt = %v, want %v", got.ExpiresAt, exp)
	}
	if len(got.Scopes) != 2 {
		t.Errorf("spliced Scopes = %v", got.Scopes)
	}
}

func TestSpliceOAuthCredKeepsStoredTokenWhenNotRotated(t *testing.T) {
	out, err := SpliceOAuthCred([]byte(fullBlob), RefreshResult{
		AccessToken: "new-access",
		ExpiresAt:   time.UnixMilli(1752700000000),
		// RefreshToken and Scopes empty: server did not rotate/report them.
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseOAuthCred(out)
	if err != nil {
		t.Fatal(err)
	}
	if got.RefreshToken != "old-refresh" {
		t.Errorf("RefreshToken = %q, want stored old-refresh", got.RefreshToken)
	}
	if len(got.Scopes) != 1 || got.Scopes[0] != "user:inference" {
		t.Errorf("Scopes = %v, want stored scopes", got.Scopes)
	}
}

func TestSpliceOAuthCredRejectsBadInput(t *testing.T) {
	if _, err := SpliceOAuthCred([]byte(fullBlob), RefreshResult{}); err == nil {
		t.Error("want error for empty access token")
	}
	if _, err := SpliceOAuthCred([]byte(`{"x":1}`), RefreshResult{AccessToken: "a"}); err == nil {
		t.Error("want error for missing claudeAiOauth")
	}
	if _, err := SpliceOAuthCred([]byte(`nope`), RefreshResult{AccessToken: "a"}); err == nil {
		t.Error("want error for invalid JSON")
	}
	// Errors never carry payload content.
	_, err := SpliceOAuthCred([]byte(`{"claudeAiOauth":"tok-SECRET"}`), RefreshResult{AccessToken: "a"})
	if err == nil || strings.Contains(err.Error(), "SECRET") {
		t.Errorf("err = %v (must exist, must not leak payload)", err)
	}
}

func TestCredFingerprint(t *testing.T) {
	a1 := []byte(`{"claudeAiOauth":{"accessToken":"x","refreshToken":"same-lineage"}}`)
	a2 := []byte(`{"claudeAiOauth":{"accessToken":"y","refreshToken":"same-lineage"}}`)
	b := []byte(`{"claudeAiOauth":{"accessToken":"x","refreshToken":"other-lineage"}}`)
	if CredFingerprint(a1) != CredFingerprint(a2) {
		t.Error("same lineage with rotated access token must fingerprint equal")
	}
	if CredFingerprint(a1) == CredFingerprint(b) {
		t.Error("different lineages must fingerprint differently")
	}
	noRefresh := []byte(`{"claudeAiOauth":{"accessToken":"x"}}`)
	if !strings.HasPrefix(CredFingerprint(noRefresh), "sha256-full:") {
		t.Error("no refresh token must fall back to full-content hash")
	}
	if CredFingerprint(nil) != "" {
		t.Error("empty input must fingerprint empty")
	}
	if strings.Contains(CredFingerprint(a1), "same-lineage") {
		t.Error("fingerprint must not embed the token")
	}
}
