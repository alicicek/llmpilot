package anthropic

import "time"

// backoffCap follows the observed 429 behavior: blocks can persist 30+
// minutes with no Retry-After, so waiting longer than this buys nothing.
const backoffCap = 30 * time.Minute

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
