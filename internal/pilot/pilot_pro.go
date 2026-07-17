//go:build pro

package pilot

import (
	"github.com/alicicek/llmpilot/pilotapi"

	"github.com/alicicek/llmpilot-pro/engine"
)

// Get returns the real autopilot engine (official builds only; the private
// module resolves via the release workspace, never over the network).
func Get() pilotapi.Provider { return engine.Provider() }
