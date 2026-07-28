package anthropic

import "time"

// backoffCap follows the observed 429 behavior: blocks can persist 30+
// minutes with no Retry-After, so waiting longer than this buys nothing.
const backoffCap = 30 * time.Minute

const rateLimitFloor = 10 * time.Minute   // first-429 wait; must exceed poll/refresh cadence
const maxRateLimitWait = 60 * time.Minute // cap when honoring a server Retry-After

// Backoff is the wait before retry attempt n (0-based): 1m, 2m, 4m, …
// capped at 30m. The steady-state poll cadence (≥300s per account) is the
// daemon's job; this only paces retries after 429/5xx.
func Backoff(attempt int) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	if attempt > 10 {
		return backoffCap
	}
	d := time.Minute << uint(attempt)
	if d > backoffCap {
		return backoffCap
	}
	return d
}

// RateLimitBackoff is the per-account cool-down after the nth consecutive 429
// (0-based): 10m, 20m, 30m(cap) — or the server's Retry-After if longer, up to
// maxRateLimitWait. Anthropic's OAuth/usage 429s carry no dependable Retry-After
// and persist many minutes; a sub-minute retry only re-arms the limit.
func RateLimitBackoff(attempt int, retryAfter time.Duration) time.Duration {
	if attempt < 0 {
		attempt = 0
	}
	shift := attempt
	if shift > 2 {
		shift = 2
	}
	d := rateLimitFloor << uint(shift) // 10m,20m,40m
	if d > backoffCap {
		d = backoffCap
	}
	if retryAfter > d {
		d = retryAfter
	}
	if d > maxRateLimitWait {
		d = maxRateLimitWait
	}
	return d
}
