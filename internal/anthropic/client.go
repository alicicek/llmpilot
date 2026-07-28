package anthropic

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// DefaultBaseURL is the production API host.
const DefaultBaseURL = "https://api.anthropic.com"

const (
	usagePath       = "/api/oauth/usage"
	oauthBetaHeader = "oauth-2025-04-20"
)

// StatusError is a non-200 from the usage endpoint. The response body is
// never surfaced (it is drained and discarded). RetryAfter carries the
// server's Retry-After header when present (0 otherwise).
type StatusError struct {
	StatusCode int
	RetryAfter time.Duration
}

func (e *StatusError) Error() string {
	return fmt.Sprintf("usage endpoint returned HTTP %d", e.StatusCode)
}

// parseRetryAfter reads a Retry-After header (delta-seconds or HTTP-date) into a
// positive duration; 0 if absent/invalid/past.
func parseRetryAfter(v string) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(v); err == nil {
		if secs <= 0 {
			return 0
		}
		if secs > maxRetryAfterSeconds {
			secs = maxRetryAfterSeconds // clamp so ×time.Second can't overflow int64
		}
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil {
		if d := time.Until(t); d > 0 {
			return d
		}
	}
	return 0
}

// maxRetryAfterSeconds (a day) caps a parsed delta-seconds Retry-After so an
// absurd header can't overflow the int64 nanosecond duration; the daemon caps
// the effective wait far lower (maxRateLimitWait).
const maxRetryAfterSeconds = 24 * 60 * 60

// UsageClient fetches one account's rate-limit buckets.
type UsageClient struct {
	Source    TokenSource
	BaseURL   string       // "" = DefaultBaseURL
	UserAgent string       // e.g. "claude-code/2.1.205"
	HTTP      *http.Client // nil = 15s-timeout client
}

// FetchUsage performs one read-only GET of the usage document.
func (c *UsageClient) FetchUsage(ctx context.Context) ([]store.Bucket, error) {
	tok, err := c.Source.Token(ctx)
	if err != nil {
		return nil, err
	}
	base := c.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+usagePath, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("anthropic-beta", oauthBetaHeader)
	if c.UserAgent != "" {
		req.Header.Set("User-Agent", c.UserAgent)
	}
	httpc := c.HTTP
	if httpc == nil {
		httpc = &http.Client{Timeout: 15 * time.Second}
	}
	resp, err := httpc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only body
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return nil, &StatusError{StatusCode: resp.StatusCode, RetryAfter: parseRetryAfter(resp.Header.Get("Retry-After"))}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return ParseUsage(body)
}

// ParseUsage maps a usage document to buckets. It is bucket-agnostic by
// design: whatever kinds the endpoint reports survive as open strings.
//
// Two shapes are handled (both observed live 2026-07-08):
//   - modern: a self-describing "limits" array with kind/percent/severity/
//     resets_at/scope/is_active — used verbatim, server order kept;
//   - legacy fallback (when "limits" is absent): every top-level object
//     carrying a numeric "utilization" is a bucket named by its key
//     (null-valued experimental keys and null utilizations are skipped),
//     sorted by kind for determinism. No severity is invented for these.
func ParseUsage(data []byte) ([]store.Bucket, error) {
	var doc struct {
		Limits []struct {
			Kind     string     `json:"kind"`
			Percent  float64    `json:"percent"`
			Severity string     `json:"severity"`
			ResetsAt *time.Time `json:"resets_at"`
			IsActive bool       `json:"is_active"`
			Scope    *struct {
				Model *struct {
					DisplayName string `json:"display_name"`
				} `json:"model"`
			} `json:"scope"`
		} `json:"limits"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("usage response: %w", err)
	}

	if len(doc.Limits) > 0 {
		buckets := make([]store.Bucket, 0, len(doc.Limits))
		for _, l := range doc.Limits {
			b := store.Bucket{
				Kind:     l.Kind,
				Percent:  l.Percent,
				Severity: l.Severity,
				ResetsAt: l.ResetsAt,
				Active:   l.IsActive,
			}
			if l.Scope != nil && l.Scope.Model != nil {
				b.Scope = l.Scope.Model.DisplayName
			}
			buckets = append(buckets, b)
		}
		return buckets, nil
	}

	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return nil, fmt.Errorf("usage response: %w", err)
	}
	var buckets []store.Bucket
	for key, raw := range top {
		var lb struct {
			Utilization *float64   `json:"utilization"`
			ResetsAt    *time.Time `json:"resets_at"`
		}
		if json.Unmarshal(raw, &lb) != nil || lb.Utilization == nil {
			continue
		}
		buckets = append(buckets, store.Bucket{
			Kind:     key,
			Percent:  *lb.Utilization,
			ResetsAt: lb.ResetsAt,
		})
	}
	sort.Slice(buckets, func(i, j int) bool { return buckets[i].Kind < buckets[j].Kind })
	return buckets, nil
}
