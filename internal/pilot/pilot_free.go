//go:build !pro

package pilot

import "github.com/alicicek/llmpilot/pilotapi"

// Get returns the engine this build carries: none. Callers branch on
// Available — the zero Provider never pretends to work.
func Get() pilotapi.Provider { return pilotapi.Provider{} }
