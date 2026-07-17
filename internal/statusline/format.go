package statusline

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// This file is the classic bucket formatting, moved verbatim so the engine,
// the CLI, and the daemon preview all render through ONE implementation.
// internal/cli re-exports these for its fleet table.

// BucketLabel is the compact statusline/status label for one bucket kind.
// Known kinds get the runway shorthand; unknown kinds render verbatim —
// bucket-agnostic per the decision ledger.
func BucketLabel(b store.Bucket) string {
	switch b.Kind {
	case "session", "five_hour":
		return "5h"
	case "weekly_all", "seven_day":
		return "wk"
	case "seven_day_opus":
		return "O"
	case "seven_day_sonnet":
		return "S"
	}
	if b.Scope != "" { // scoped buckets: first letter of the model name (F, O, S)
		r := []rune(b.Scope)
		return strings.ToUpper(string(r[0]))
	}
	return b.Kind
}

// SeverityWarns reports whether the server marked this bucket worth watching.
// No local thresholds are invented: empty and "normal" stay quiet.
func SeverityWarns(sev string) bool {
	return sev != "" && sev != "normal"
}

// FormatPercent renders 23.0 as "23" and 12.5 as "12.5" — compact, no fake
// precision.
func FormatPercent(p float64) string {
	return strconv.FormatFloat(p, 'f', -1, 64)
}

// formatReset renders a reset instant for the compact readout: session-group
// buckets reset within hours so they show a clock time; anything longer shows
// the weekday.
func formatReset(t time.Time, now time.Time, loc *time.Location) string {
	t = t.In(loc)
	if t.Sub(now) < 24*time.Hour {
		return t.Format("15:04")
	}
	return t.Format("Mon")
}

// FormatBucket renders one bucket as `5h:23%(14:32)`. The reset shows always
// for session-window buckets and only when the server severity warns for the
// rest — the line stays short until something needs attention.
func FormatBucket(b store.Bucket, now time.Time, loc *time.Location) string {
	s := BucketLabel(b) + ":" + FormatPercent(b.Percent) + "%"
	session := b.Kind == "session" || b.Kind == "five_hour"
	if b.ResetsAt != nil && (session || SeverityWarns(b.Severity)) {
		s += "(" + formatReset(*b.ResetsAt, now, loc) + ")"
	}
	return s
}

// CanonicalOrder puts the runway in reading order: session window first,
// all-models weekly second, scoped weeklies next, anything unknown last in
// its served order.
func CanonicalOrder(buckets []store.Bucket) []store.Bucket {
	rank := func(b store.Bucket) int {
		switch {
		case b.Kind == "session" || b.Kind == "five_hour":
			return 0
		case b.Kind == "weekly_all" || b.Kind == "seven_day":
			return 1
		case b.Scope != "" || strings.HasPrefix(b.Kind, "seven_day_"):
			return 2
		default:
			return 3
		}
	}
	out := make([]store.Bucket, len(buckets))
	copy(out, buckets)
	sort.SliceStable(out, func(i, j int) bool { return rank(out[i]) < rank(out[j]) })
	return out
}

// FormatBuckets renders a whole runway, space-separated, canonical order.
func FormatBuckets(buckets []store.Bucket, now time.Time, loc *time.Location) string {
	parts := make([]string, 0, len(buckets))
	for _, b := range CanonicalOrder(buckets) {
		parts = append(parts, FormatBucket(b, now, loc))
	}
	return strings.Join(parts, " ")
}

// FormatAge renders a cache age like "~4m" (hours past 99 minutes).
func FormatAge(age time.Duration) string {
	if age < time.Minute {
		return "~now"
	}
	if age < 100*time.Minute {
		return "~" + strconv.Itoa(int(age.Minutes())) + "m"
	}
	return "~" + strconv.Itoa(int(age.Hours())) + "h"
}

// bucketSem maps the classic severity coloring: ≥100% is critical, a warning
// severity from the server paints amber, everything else stays quiet.
func bucketSem(b store.Bucket) Sem {
	if b.Percent >= 100 {
		return SemCrit
	}
	if SeverityWarns(b.Severity) {
		return SemWarn
	}
	return SemNone
}
