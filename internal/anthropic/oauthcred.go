package anthropic

// Credential-blob surgery for the keep-warm engine. The claudeAiOauth payload
// layout is this adapter's surface (see the package doc); splicing preserves
// every field we do not understand, because Claude Code adds keys between
// releases and a lossy rewrite would corrupt the user's login.
//
// Error messages never include payload content.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// OAuthCred is the subset of claudeAiOauth the keep-warm engine reasons
// about. RefreshToken is deliberately never logged by any caller.
type OAuthCred struct {
	AccessToken  string
	RefreshToken string
	ExpiresAt    time.Time // zero when the payload carries none
	Scopes       []string
}

// ParseOAuthCred extracts the OAuth fields from a credential payload.
func ParseOAuthCred(blob []byte) (OAuthCred, error) {
	var doc struct {
		ClaudeAiOauth *struct {
			AccessToken  string   `json:"accessToken"`
			RefreshToken string   `json:"refreshToken"`
			ExpiresAt    int64    `json:"expiresAt"`
			Scopes       []string `json:"scopes"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(blob, &doc); err != nil {
		return OAuthCred{}, errors.New("credential payload: not valid JSON")
	}
	if doc.ClaudeAiOauth == nil {
		return OAuthCred{}, errors.New("credential payload: no claudeAiOauth block")
	}
	c := OAuthCred{
		AccessToken:  doc.ClaudeAiOauth.AccessToken,
		RefreshToken: doc.ClaudeAiOauth.RefreshToken,
		Scopes:       doc.ClaudeAiOauth.Scopes,
	}
	if doc.ClaudeAiOauth.ExpiresAt != 0 {
		c.ExpiresAt = time.UnixMilli(doc.ClaudeAiOauth.ExpiresAt)
	}
	return c, nil
}

// SpliceOAuthCred writes a refresh result into a credential payload,
// preserving every unknown key at both levels. An empty res.RefreshToken
// keeps the stored one (the server does not always rotate); empty Scopes
// keep the stored scopes. The result is re-parsed before it is returned —
// a corrupt credential locks the user out of every claude session.
func SpliceOAuthCred(blob []byte, res RefreshResult) ([]byte, error) {
	if res.AccessToken == "" {
		return nil, errors.New("splice: refresh result carries no access token")
	}
	var outer map[string]json.RawMessage
	if err := json.Unmarshal(blob, &outer); err != nil {
		return nil, errors.New("credential payload: not valid JSON")
	}
	rawInner, ok := outer["claudeAiOauth"]
	if !ok {
		return nil, errors.New("credential payload: no claudeAiOauth block")
	}
	var inner map[string]json.RawMessage
	if err := json.Unmarshal(rawInner, &inner); err != nil {
		return nil, errors.New("credential payload: claudeAiOauth is not an object")
	}
	set := func(key string, v any) error {
		enc, err := json.Marshal(v)
		if err != nil {
			return err
		}
		inner[key] = enc
		return nil
	}
	if err := set("accessToken", res.AccessToken); err != nil {
		return nil, err
	}
	if err := set("expiresAt", res.ExpiresAt.UnixMilli()); err != nil {
		return nil, err
	}
	if res.RefreshToken != "" {
		if err := set("refreshToken", res.RefreshToken); err != nil {
			return nil, err
		}
	}
	if len(res.Scopes) > 0 {
		if err := set("scopes", res.Scopes); err != nil {
			return nil, err
		}
	}
	encInner, err := json.Marshal(inner)
	if err != nil {
		return nil, err
	}
	outer["claudeAiOauth"] = encInner
	out, err := json.Marshal(outer)
	if err != nil {
		return nil, err
	}
	// Validate the write before anyone persists it.
	got, err := ParseOAuthCred(out)
	if err != nil {
		return nil, errors.New("splice: result failed to re-parse")
	}
	if got.AccessToken != res.AccessToken {
		return nil, errors.New("splice: result does not carry the new access token")
	}
	return out, nil
}

// CredFingerprint is a stable identity for a stored credential's
// refresh-token lineage: the refresh-token hash when one exists (survives
// access-token rotation, so two generations of one lineage compare equal),
// the full-content hash otherwise. "" only for empty input.
// (Pattern from claude-swap oauth.py credential_fingerprint, MIT.)
func CredFingerprint(blob []byte) string {
	if len(blob) == 0 {
		return ""
	}
	if c, err := ParseOAuthCred(blob); err == nil && c.RefreshToken != "" {
		sum := sha256.Sum256([]byte(c.RefreshToken))
		return "sha256:" + hex.EncodeToString(sum[:])
	}
	sum := sha256.Sum256(blob)
	return "sha256-full:" + hex.EncodeToString(sum[:])
}
