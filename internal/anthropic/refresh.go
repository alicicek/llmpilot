package anthropic

// OAuth token refresh — the second undocumented surface this adapter owns.
//
// Receipts (verified live, as-of 2026-07-16):
//   - POST https://platform.claude.com/v1/oauth/token with JSON
//     {"grant_type":"refresh_token","refresh_token":…,"client_id":…} mints a
//     new access token. It is a pure auth call: no model request, so it never
//     starts or advances a 5-hour usage window.
//   - The refresh token ROTATES: a successful POST kills the old one
//     server-side. Persisting the rotated credential is the caller's very
//     next duty; a response lost after the server committed (timeout, crash)
//     strands the lineage — callers must NOT retry a timed-out POST in the
//     same pass (the retry would burn the stored token a second time) and
//     must let the next pass surface invalid_grant honestly.
//   - Permanent failure is ONLY a 4xx carrying invalid_grant/invalid_client;
//     anything else is transient. A misclassified transient costs one retry,
//     a misclassified permanent wrongly quarantines a live account.
//     (Classification mirrors claude-swap oauth.py, MIT.)
//
// Tokens never appear in logs or errors; error text carries only the HTTP
// status and the parsed OAuth error code.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// DefaultRefreshBaseURL is the production OAuth token host. It moved from
// console.anthropic.com to platform.claude.com before 2026-07-16 and can move
// again — the delegated `claude auth status` path is the designed fallback.
const DefaultRefreshBaseURL = "https://platform.claude.com"

const (
	refreshPath = "/v1/oauth/token"
	// refreshClientID is Claude Code's own OAuth client id (public knowledge:
	// it ships in the CLI binary and in claude-swap).
	refreshClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
)

// RefreshError is a non-200 from the token endpoint. The response body is
// never surfaced — only the parsed OAuth error code rides along. RetryAfter
// carries the server's Retry-After header when present (0 otherwise).
type RefreshError struct {
	StatusCode int
	Code       string        // e.g. "invalid_grant"; "" when the body carried none
	RetryAfter time.Duration // server Retry-After, 0 if absent
}

func (e *RefreshError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("token refresh returned HTTP %d", e.StatusCode)
	}
	return fmt.Sprintf("token refresh returned HTTP %d (%s)", e.StatusCode, e.Code)
}

// Permanent reports whether the server itself rejected the grant — the
// refresh-token lineage is dead and only a re-login recovers it. True ONLY
// for a 4xx with an explicit invalid_grant/invalid_client marker; everything
// ambiguous stays transient.
func (e *RefreshError) Permanent() bool {
	switch e.StatusCode {
	case http.StatusBadRequest, http.StatusUnauthorized, http.StatusForbidden:
		return e.Code == "invalid_grant" || e.Code == "invalid_client"
	}
	return false
}

// RefreshResult is a successful rotation. RefreshToken may be "" when the
// server did not rotate it — callers keep the stored one then.
type RefreshResult struct {
	AccessToken  string
	RefreshToken string
	ExpiresAt    time.Time
	Scopes       []string
}

// RefreshClient performs one OAuth refresh grant.
type RefreshClient struct {
	BaseURL   string           // "" = DefaultRefreshBaseURL
	UserAgent string           // same claude-code/<ver> the usage client sends
	HTTP      *http.Client     // nil = 8s-timeout client (see package doc: keep POSTs short)
	Now       func() time.Time // nil = time.Now; injected so tests pin ExpiresAt
}

// Refresh POSTs the refresh grant and returns the rotated credential fields.
//
// Interlock: under LLMPILOT_TEST the production host is refused — a sandbox
// test holding a real captured credential must never be able to rotate a
// real account (same rationale as AssertThrowawayKeychain).
func (c *RefreshClient) Refresh(ctx context.Context, refreshToken string) (RefreshResult, error) {
	if refreshToken == "" {
		return RefreshResult{}, errors.New("credential payload: no claudeAiOauth.refreshToken")
	}
	base := c.BaseURL
	if base == "" {
		base = DefaultRefreshBaseURL
	}
	if os.Getenv("LLMPILOT_TEST") != "" && base == DefaultRefreshBaseURL {
		return RefreshResult{}, errors.New("LLMPILOT_TEST is set: refusing the production token endpoint (interlock; point BaseURL at a test server)")
	}
	body, err := json.Marshal(map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": refreshToken,
		"client_id":     refreshClientID,
	})
	if err != nil {
		return RefreshResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+refreshPath, bytes.NewReader(body))
	if err != nil {
		return RefreshResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	httpc := c.HTTP
	if httpc == nil {
		httpc = &http.Client{Timeout: 8 * time.Second}
	}
	resp, err := httpc.Do(req)
	if err != nil {
		return RefreshResult{}, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return RefreshResult{}, &RefreshError{StatusCode: resp.StatusCode, Code: oauthErrorCode(raw), RetryAfter: parseRetryAfter(resp.Header.Get("Retry-After"))}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return RefreshResult{}, err
	}
	var doc struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return RefreshResult{}, errors.New("refresh response: not valid JSON")
	}
	if doc.AccessToken == "" {
		return RefreshResult{}, errors.New("refresh response: no access_token")
	}
	if doc.ExpiresIn <= 0 {
		return RefreshResult{}, errors.New("refresh response: no expires_in")
	}
	now := c.Now
	if now == nil {
		now = time.Now
	}
	res := RefreshResult{
		AccessToken:  doc.AccessToken,
		RefreshToken: doc.RefreshToken,
		ExpiresAt:    now().Add(time.Duration(doc.ExpiresIn) * time.Second),
	}
	if doc.Scope != "" {
		res.Scopes = strings.Fields(doc.Scope)
	}
	return res, nil
}

// oauthErrorCode pulls the OAuth error code out of a failure body without
// ever surfacing the body itself. The structured field is authoritative; the
// substring scan catches non-JSON bodies that still name the code.
func oauthErrorCode(body []byte) string {
	var doc struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(body, &doc) == nil && doc.Error != "" {
		return sanitizeErrorCode(doc.Error)
	}
	for _, code := range []string{"invalid_grant", "invalid_client"} {
		if bytes.Contains(body, []byte(code)) {
			return code
		}
	}
	return ""
}

// sanitizeErrorCode keeps only a short well-formed code so a hostile or
// malformed body can never smuggle content into error strings.
func sanitizeErrorCode(s string) string {
	if len(s) > 40 {
		return ""
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
		default:
			return ""
		}
	}
	return s
}
