package pilotapi

import (
	"os"
	"time"
)

// Wake state probes and plan math. Display-class: the CLI's `wake status`,
// the daemon state, and the cockpit render these whether or not the engine
// is present. The arming engine (pmset via the privileged helper) lives in
// the pro module.

// SudoersPath is where the approved helper design lands its one root-owned
// rule; its existence is what flips Mode to armed.
const SudoersPath = "/etc/sudoers.d/llmpilot-wake"

// Lead is how long before a fire the wake is armed.
const Lead = 2 * time.Minute

// WakeOwner tags every power event llmpilot schedules — arming, canceling,
// and `pmset -g sched` listing all match on it, never on anyone else's
// events.
const WakeOwner = "dev.llmpilot"

// WakeMode reports the wake mode from the machine's actual state.
func WakeMode() string {
	if _, err := os.Stat(WakeActivePath()); err == nil {
		return "armed"
	}
	return "degraded"
}

// WakeActivePath is the sudoers path every wake read AND write must use: the
// guard and the destructive action resolve identically, so a sandbox
// redirect can never aim WakeMode() at a fake file while an uninstall hits
// the real one (review P1-2). The redirect is honored only under
// LLMPILOT_TEST like every other sandbox redirect.
func WakeActivePath() string {
	if os.Getenv("LLMPILOT_TEST") != "" {
		if p := os.Getenv("LLMPILOT_SUDOERS"); p != "" {
			return p
		}
	}
	return SudoersPath
}

// Sandboxed reports whether wake operations run under the test interlock —
// privileged actions (sudo) are refused outright in that state.
func Sandboxed() bool { return os.Getenv("LLMPILOT_TEST") != "" }

// NextFire is the schedule's next wall-clock occurrence strictly after now.
func NextFire(now time.Time, sc Schedule) time.Time {
	next := time.Date(now.Year(), now.Month(), now.Day(), sc.Hour, sc.Minute, 0, 0, now.Location())
	if !next.After(now) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}

// Plan is one schedule's wake outlook, rendered by CLI/state.
type Plan struct {
	ScheduleID string    `json:"schedule_id"`
	AccountID  string    `json:"account_id"`
	FireAt     time.Time `json:"fire_at"`
	WakeAt     time.Time `json:"wake_at,omitempty"` // armed mode only
}

// Plans computes the next fire (and, when armed, wake) for every schedule.
func Plans(now time.Time, scheds []Schedule, mode string) []Plan {
	var ps []Plan
	for _, sc := range scheds {
		p := Plan{ScheduleID: sc.ID, AccountID: sc.AccountID, FireAt: NextFire(now, sc)}
		if mode == "armed" {
			p.WakeAt = p.FireAt.Add(-Lead)
		}
		ps = append(ps, p)
	}
	return ps
}
