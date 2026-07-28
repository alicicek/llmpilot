package anthropic

// login.go — the authorization_code (sign-in) half of the OAuth surface; the
// refresh grant lives in refresh.go and shares the client id and token host.
//
// Receipts (live capture 2026-07-23 + string
// extraction of the CLI 2.1.218 binary, BUILD_TIME 2026-07-22):
//   - Authorize URL: https://claude.com/cai/oauth/authorize with code=true
//     (the hosted callback then renders the code for manual copy), the same
//     client_id as refresh, response_type=code,
//     redirect_uri=https://platform.claude.com/oauth/code/callback, the six
//     scopes below, code_challenge (S256) + code_challenge_method, state.
//   - Exchange: POST {token host}/v1/oauth/token as JSON
//     {grant_type:"authorization_code", code, redirect_uri, client_id,
//     code_verifier, state} — the CLI sends state in the body too; 30s
//     timeout; a 401 means the code is invalid or already used.
//   - Exchange response: access_token, refresh_token, expires_in, scope, and
//     optionally account{uuid,email_address} + organization{uuid}.
//   - Identity: GET https://api.anthropic.com/api/oauth/profile with
//     "Authorization: Bearer <access>" returns account/organization; the CLI
//     seeds oauthAccount from {accountUuid, emailAddress, organizationUuid}
//     and self-heals optional fields on its own later profile fetches.
//   - The pasted-code fallback format is "<code>#<state>" (both required).
//
// The rotation hazard binds here exactly as in refresh.go: a successful
// exchange mints a refresh-token lineage server-side, so a timed-out POST
// must NEVER be retried in the same pass — the server may have committed the
// first attempt, and the retry both fails (code consumed) and orphans the
// minted lineage. This client performs exactly one POST per call.
//
// Tokens and authorization codes never appear in logs or errors; error text
// carries only the HTTP status and the parsed OAuth error code.

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// DefaultAuthorizeBaseURL is the page a login surface opens for the user —
// the exact URL the official CLI prints (it 307s to claude.ai carrying the
// same query). Never fetched by this process.
const DefaultAuthorizeBaseURL = "https://claude.com/cai/oauth/authorize"

// LoginRedirectURI is the Anthropic-hosted manual-mode callback. The code
// rides its URL query, so it is also the URL a login webview intercepts.
const LoginRedirectURI = "https://platform.claude.com/oauth/code/callback"

// DefaultProfileBaseURL is the API host serving /api/oauth/profile (the same
// host as the usage endpoint).
const DefaultProfileBaseURL = "https://api.anthropic.com"

const profilePath = "/api/oauth/profile"

// loginScopes is the exact scope list the CLI requests for a claude.ai
// subscription sign-in (live capture 2026-07-23).
var loginScopes = []string{
	"org:create_api_key",
	"user:profile",
	"user:inference",
	"user:sessions:claude_code",
	"user:mcp_servers",
	"user:file_upload",
}

// PKCE is one login attempt's proof-key pair. The Verifier stays in the
// daemon process; only the Challenge rides the authorize URL.
type PKCE struct {
	Verifier  string
	Challenge string
}

// NewPKCE mints a fresh S256 pair: a 32-byte random verifier (base64url,
// 43 chars — RFC 7636 §4.1) and its sha256 challenge.
func NewPKCE() (PKCE, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return PKCE{}, err
	}
	verifier := base64.RawURLEncoding.EncodeToString(b[:])
	sum := sha256.Sum256([]byte(verifier))
	return PKCE{
		Verifier:  verifier,
		Challenge: base64.RawURLEncoding.EncodeToString(sum[:]),
	}, nil
}

// NewLoginState mints the CSRF state for one login attempt.
func NewLoginState() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// LoopbackRedirectURI is the localhost callback for the zero-paste browser
// flow. The host is "localhost" (CLI parity — the official client registers
// that host) even though the daemon binds its listener on 127.0.0.1; browsers
// resolve localhost→127.0.0.1.
func LoopbackRedirectURI(port int) string {
	return fmt.Sprintf("http://localhost:%d/callback", port)
}

// AuthorizeURL assembles the sign-in URL for one attempt against redirectURI —
// either LoginRedirectURI (hosted callback: in-app webview or browser+paste)
// or a LoopbackRedirectURI (zero-paste browser flow). Both are redirect
// targets the official client accepts.
func AuthorizeURL(challenge, state, redirectURI string) (string, error) {
	if challenge == "" || state == "" || redirectURI == "" {
		return "", errors.New("authorize url: challenge, state, and redirect_uri are required")
	}
	q := url.Values{
		"client_id":             {refreshClientID},
		"response_type":         {"code"},
		"redirect_uri":          {redirectURI},
		"scope":                 {strings.Join(loginScopes, " ")},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"state":                 {state},
	}
	// code=true puts the HOSTED callback into display-the-code (manual paste)
	// mode. A loopback redirect must NOT set it — it auto-redirects the browser
	// back to the local listener instead of rendering a code to copy.
	if redirectURI == LoginRedirectURI {
		q.Set("code", "true")
	}
	return DefaultAuthorizeBaseURL + "?" + q.Encode(), nil
}

// ExchangeError is a non-200 from the token endpoint during a code exchange.
// The response body is never surfaced — only the parsed OAuth error code.
type ExchangeError struct {
	StatusCode int
	Code       string
}

func (e *ExchangeError) Error() string {
	if e.Code == "" {
		return fmt.Sprintf("code exchange returned HTTP %d", e.StatusCode)
	}
	return fmt.Sprintf("code exchange returned HTTP %d (%s)", e.StatusCode, e.Code)
}

// LoginIdentity is the account identity the token response itself may carry.
type LoginIdentity struct {
	AccountUUID  string
	EmailAddress string
	OrgUUID      string
}

// ExchangeResult is a successful code→token exchange. Identity is zero-valued
// when the response carried no account block (FetchProfile covers it then).
type ExchangeResult struct {
	AccessToken  string
	RefreshToken string
	ExpiresAt    time.Time
	Scopes       []string
	Identity     LoginIdentity
}

// Profile is the /api/oauth/profile identity subset the fleet needs.
type Profile struct {
	AccountUUID  string
	EmailAddress string
	DisplayName  string
	OrgUUID      string
}

// LoginClient performs the code→token exchange and the identity fetch for
// one in-app sign-in. It never touches the authorize host — the user's
// browser/webview does that.
type LoginClient struct {
	TokenBaseURL   string           // "" = DefaultRefreshBaseURL
	ProfileBaseURL string           // "" = DefaultProfileBaseURL
	UserAgent      string           // same claude-code/<ver> the usage client sends
	HTTP           *http.Client     // nil = 30s-timeout client (CLI parity; never called under locks)
	Now            func() time.Time // nil = time.Now; injected so tests pin ExpiresAt
}

func (c *LoginClient) httpc() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// Exchange POSTs the authorization_code grant exactly once. Callers must not
// retry a timed-out call in the same pass (see the package hazard note).
//
// Interlock: under LLMPILOT_TEST the production host is refused — a sandbox
// test must never be able to consume a real authorization code.
// redirectURI MUST equal the one the authorize URL used (OAuth binds them).
func (c *LoginClient) Exchange(ctx context.Context, code, state, verifier, redirectURI string) (ExchangeResult, error) {
	if code == "" || state == "" || verifier == "" || redirectURI == "" {
		return ExchangeResult{}, errors.New("code exchange: code, state, verifier, and redirect_uri are required")
	}
	base := c.TokenBaseURL
	if base == "" {
		base = DefaultRefreshBaseURL
	}
	if os.Getenv("LLMPILOT_TEST") != "" && base == DefaultRefreshBaseURL {
		return ExchangeResult{}, errors.New("LLMPILOT_TEST is set: refusing the production token endpoint (interlock; point TokenBaseURL at a test server)")
	}
	body, err := json.Marshal(map[string]string{
		"grant_type":    "authorization_code",
		"code":          code,
		"redirect_uri":  redirectURI,
		"client_id":     refreshClientID,
		"code_verifier": verifier,
		"state":         state,
	})
	if err != nil {
		return ExchangeResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+refreshPath, bytes.NewReader(body))
	if err != nil {
		return ExchangeResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	resp, err := c.httpc().Do(req)
	if err != nil {
		return ExchangeResult{}, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return ExchangeResult{}, &ExchangeError{StatusCode: resp.StatusCode, Code: oauthErrorCode(raw)}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return ExchangeResult{}, err
	}
	var doc struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
		Scope        string `json:"scope"`
		Account      *struct {
			UUID         string `json:"uuid"`
			EmailAddress string `json:"email_address"`
		} `json:"account"`
		Organization *struct {
			UUID string `json:"uuid"`
		} `json:"organization"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return ExchangeResult{}, errors.New("exchange response: not valid JSON")
	}
	if doc.AccessToken == "" {
		return ExchangeResult{}, errors.New("exchange response: no access_token")
	}
	// A login without a refresh token cannot be kept warm or swapped to later
	// — refuse it now rather than register a fleet account that dies in hours.
	if doc.RefreshToken == "" {
		return ExchangeResult{}, errors.New("exchange response: no refresh_token")
	}
	if doc.ExpiresIn <= 0 {
		return ExchangeResult{}, errors.New("exchange response: no expires_in")
	}
	now := c.Now
	if now == nil {
		now = time.Now
	}
	res := ExchangeResult{
		AccessToken:  doc.AccessToken,
		RefreshToken: doc.RefreshToken,
		ExpiresAt:    now().Add(time.Duration(doc.ExpiresIn) * time.Second),
	}
	if doc.Scope != "" {
		res.Scopes = strings.Fields(doc.Scope)
	}
	if doc.Account != nil {
		res.Identity.AccountUUID = doc.Account.UUID
		res.Identity.EmailAddress = doc.Account.EmailAddress
	}
	if doc.Organization != nil {
		res.Identity.OrgUUID = doc.Organization.UUID
	}
	return res, nil
}

// FetchProfile reads the signed-in account's identity with the fresh access
// token — the fleet label comes from here (or from the exchange response's
// own account block when this fails).
func (c *LoginClient) FetchProfile(ctx context.Context, accessToken string) (Profile, error) {
	if accessToken == "" {
		return Profile{}, errors.New("profile fetch: no access token")
	}
	base := c.ProfileBaseURL
	if base == "" {
		base = DefaultProfileBaseURL
	}
	if os.Getenv("LLMPILOT_TEST") != "" && base == DefaultProfileBaseURL {
		return Profile{}, errors.New("LLMPILOT_TEST is set: refusing the production API host (interlock; point ProfileBaseURL at a test server)")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+profilePath, nil)
	if err != nil {
		return Profile{}, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	resp, err := c.httpc().Do(req)
	if err != nil {
		return Profile{}, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body
	if resp.StatusCode != http.StatusOK {
		// The body is never surfaced (it could echo the Authorization header).
		return Profile{}, fmt.Errorf("profile fetch returned HTTP %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Profile{}, err
	}
	var doc struct {
		Account struct {
			UUID        string `json:"uuid"`
			Email       string `json:"email"`
			DisplayName string `json:"display_name"`
		} `json:"account"`
		Organization struct {
			UUID string `json:"uuid"`
		} `json:"organization"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return Profile{}, errors.New("profile response: not valid JSON")
	}
	if doc.Account.Email == "" || doc.Account.UUID == "" {
		return Profile{}, errors.New("profile response: no account identity")
	}
	return Profile{
		AccountUUID:  doc.Account.UUID,
		EmailAddress: doc.Account.Email,
		DisplayName:  doc.Account.DisplayName,
		OrgUUID:      doc.Organization.UUID,
	}, nil
}

// MintOAuthCred builds a fresh credential payload in Claude Code's exact
// claudeAiOauth layout from a successful exchange. Optional fields the CLI
// stores (subscriptionType, rateLimitTier, …) are omitted — Claude Code
// refetches them itself when absent. The result is re-parsed before it is
// returned, same as SpliceOAuthCred.
func MintOAuthCred(res ExchangeResult) ([]byte, error) {
	if res.AccessToken == "" || res.RefreshToken == "" {
		return nil, errors.New("mint: exchange result is missing tokens")
	}
	if res.ExpiresAt.IsZero() {
		return nil, errors.New("mint: exchange result carries no expiry")
	}
	inner := map[string]any{
		"accessToken":  res.AccessToken,
		"refreshToken": res.RefreshToken,
		"expiresAt":    res.ExpiresAt.UnixMilli(),
	}
	if len(res.Scopes) > 0 {
		inner["scopes"] = res.Scopes
	}
	out, err := json.Marshal(map[string]any{"claudeAiOauth": inner})
	if err != nil {
		return nil, err
	}
	got, err := ParseOAuthCred(out)
	if err != nil || got.AccessToken != res.AccessToken || got.RefreshToken != res.RefreshToken {
		return nil, errors.New("mint: result failed to re-parse")
	}
	return out, nil
}
