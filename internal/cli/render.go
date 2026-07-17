package cli

import (
	"fmt"
	"io"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

// The bucket formatting moved to internal/statusline so the daemon preview
// renders through the same code; these wrappers keep the original call
// sites and tests unchanged.

// MaskEmail keeps one character each side of the @ so output can identify an
// account without exposing it (fleet listings may land in transcripts).
func MaskEmail(email string) string {
	at := strings.IndexByte(email, '@')
	if at <= 0 || at >= len(email)-1 {
		return "***"
	}
	return email[:1] + "***@" + email[at+1:at+2] + "***"
}

// BucketLabel is the compact statusline/status label for one bucket kind.
func BucketLabel(b store.Bucket) string { return statusline.BucketLabel(b) }

// FormatPercent renders 23.0 as "23" and 12.5 as "12.5".
func FormatPercent(p float64) string { return statusline.FormatPercent(p) }

// FormatBucket renders one bucket as `5h:23%(14:32)`.
func FormatBucket(b store.Bucket, now time.Time, loc *time.Location) string {
	return statusline.FormatBucket(b, now, loc)
}

// FormatBuckets renders a whole runway, space-separated, canonical order.
func FormatBuckets(buckets []store.Bucket, now time.Time, loc *time.Location) string {
	return statusline.FormatBuckets(buckets, now, loc)
}

// FormatAge renders a cache age like "~4m" (hours past 99 minutes).
func FormatAge(age time.Duration) string { return statusline.FormatAge(age) }

// RenderFleet writes the status table: one account per row, active marked,
// runway numbers first, honest as-of ages, token notes verbatim.
func RenderFleet(w io.Writer, st *daemon.State, now time.Time, loc *time.Location) {
	if len(st.Accounts) == 0 {
		fmt.Fprintln(w, "no accounts registered — llmpilot init detects existing claude logins")
		return
	}
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	for _, a := range st.Accounts {
		marker := " "
		if a.ID == st.ActiveID {
			marker = "*"
		}
		usage, age := "no usage data yet", ""
		if a.Snapshot != nil {
			usage = FormatBuckets(a.Snapshot.Buckets, now, loc)
			age = FormatAge(now.Sub(a.Snapshot.AsOf))
		}
		note := a.TokenNote
		fmt.Fprintf(tw, "%s %s\t%s\t%s\t%s\t%s\n",
			marker, a.Label, MaskEmail(a.Email), usage, age, note)
	}
	_ = tw.Flush()
}
