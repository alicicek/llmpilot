package switcher

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestKeepWarmE2ENoModelEgress is the mechanical no-window-advance proof: an
// idle account crossing its access-token expiry is kept fresh through the REAL
// refresh client, its usage keeps polling live with the ROTATED bearer, the
// refresh-token chain survives a second rotation — and across the whole run
// the process contacts ONLY the OAuth token endpoint and the usage endpoint.
// Zero requests to any inference path is the mechanical guarantee that
// keep-warm never makes a model call (never advances a 5-hour window).
func TestKeepWarmE2ENoModelEgress(t *testing.T) {
	var mu sync.Mutex
	paths := map[string]int{}
	// The server tracks the CURRENT valid (access, refresh) pair; a POST with
	// the current refresh token rotates both. A stale refresh token gets
	// invalid_grant (proving the chain uses the rotated token), and a usage
	// GET with a stale bearer gets 401.
	curAccess, curRefresh := "token-b", "r-token-b"
	gen := 0

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		paths[r.URL.Path]++
		switch r.URL.Path {
		case "/v1/oauth/token":
			raw, _ := io.ReadAll(r.Body)
			var body struct {
				GrantType    string `json:"grant_type"`
				RefreshToken string `json:"refresh_token"`
			}
			_ = json.Unmarshal(raw, &body)
			if body.GrantType != "refresh_token" || body.RefreshToken != curRefresh {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
				return
			}
			gen++
			curAccess = "access-gen" + itoa(gen)
			curRefresh = "refresh-gen" + itoa(gen)
			_, _ = w.Write([]byte(`{"access_token":"` + curAccess + `","refresh_token":"` + curRefresh +
				`","expires_in":28800,"scope":"user:inference"}`))
		case "/api/oauth/usage":
			if r.Header.Get("Authorization") != "Bearer "+curAccess {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte(`{"limits":[{"kind":"five_hour","percent":12,"is_active":true}]}`))
		default:
			t.Errorf("UNEXPECTED egress to %q — keep-warm must touch only token+usage", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	sw, _, _, _ := sandbox(t)
	ctx := context.Background()
	now := time.Now()
	acctB := store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: sw.Dir.Path()}

	seedNearExpiry := func(access, refresh string) {
		cred := json.RawMessage(`{"claudeAiOauth":{"accessToken":"` + access + `","refreshToken":"` + refresh +
			`","expiresAt":` + itoa(int(now.Add(20*time.Minute).UnixMilli())) + `,"scopes":["user:inference"]}}`)
		if err := sw.SaveBackup(ctx, "acct-b", cred, oauthJSON("b@example.dev")); err != nil {
			t.Fatal(err)
		}
	}
	// Backup starts holding the server's initial live credential, near expiry.
	seedNearExpiry("token-b", "r-token-b")

	opts := KeepWarmOpts{
		RefreshLead: time.Hour,
		Now:         func() time.Time { return now },
		Refresh: func(ctx context.Context, refreshToken string) (anthropic.RefreshResult, error) {
			rc := &anthropic.RefreshClient{BaseURL: srv.URL, UserAgent: "claude-code/test"}
			return rc.Refresh(ctx, refreshToken)
		},
	}
	usage := func() error {
		c := &anthropic.UsageClient{
			Source:    BackupTokenSource{Switcher: sw, AccountID: "acct-b"},
			BaseURL:   srv.URL,
			UserAgent: "claude-code/test",
		}
		_, err := c.FetchUsage(ctx)
		return err
	}

	// Before keep-warm the token is still valid — usage works.
	if err := usage(); err != nil {
		t.Fatalf("usage before refresh: %v", err)
	}
	// First rotation.
	if res, err := sw.KeepWarm(ctx, acctB, opts); err != nil || !res.Rotated {
		t.Fatalf("first keep-warm: err=%v res=%+v", err, res)
	}
	// Usage now succeeds ONLY if it uses the rotated bearer from the backup.
	if err := usage(); err != nil {
		t.Fatalf("usage after first rotation (stale bearer?): %v", err)
	}
	// Age the (rotated) backup near expiry and rotate again — the chain must
	// survive, i.e. the second POST uses the FIRST rotation's refresh token.
	mu.Lock()
	access1, refresh1 := curAccess, curRefresh
	mu.Unlock()
	seedNearExpiry(access1, refresh1)
	if res, err := sw.KeepWarm(ctx, acctB, opts); err != nil || !res.Rotated {
		t.Fatalf("second keep-warm (chain broken?): err=%v res=%+v", err, res)
	}
	if err := usage(); err != nil {
		t.Fatalf("usage after second rotation: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	var seen []string
	for p := range paths {
		seen = append(seen, p)
	}
	sort.Strings(seen)
	if strings.Join(seen, ",") != "/api/oauth/usage,/v1/oauth/token" {
		t.Fatalf("egress paths = %v, want only the token + usage endpoints", seen)
	}
	if paths["/v1/oauth/token"] != 2 {
		t.Fatalf("token endpoint hit %d times, want 2 rotations", paths["/v1/oauth/token"])
	}
}

// itoa is a tiny local int formatter for building fixture JSON without fmt.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
