// Package pilot selects the autopilot engine at build time: official builds
// (`-tags pro`) compile github.com/alicicek/llmpilot-pro in; source builds
// get Available=false and every surface shows honest not-available copy.
// This is the ONLY place the build tag is consulted.
package pilot

import (
	"errors"
	"fmt"
)

// A tier boundary is not a failure. These sentinels let a caller tell "you
// have not bought this yet" apart from "the machine broke", so the two are
// never reported to the buyer in the same voice.
var (
	// ErrNotAvailable: this binary has no engine compiled in (source build).
	ErrNotAvailable = errors.New("pro_unavailable")
	// ErrNotLicensed: official build, no current entitlement.
	ErrNotLicensed = errors.New("pro_required")
)

// NotAvailable explains an engine feature's absence and what to do next.
// Free/source builds return it wherever the engine would act; official
// builds return it when no license or trial is active (wired with the
// entitlement client).
func NotAvailable(feature string) error {
	return fmt.Errorf("%s is part of llmpilot Pro, and this build was compiled without it — the official app at https://llmpilot.dev includes Pro; switching, statusline, cockpit, and analytics all keep working here: %w", feature, ErrNotAvailable)
}

// NotLicensed is the honest pause for an official build whose signed trial
// expired, whose purchase was revoked, or which has no entitlement yet.
func NotLicensed(feature string) error {
	return fmt.Errorf("%s is paused because this app has no current llmpilot Pro entitlement — open Settings → License to activate or recover it: %w", feature, ErrNotLicensed)
}
