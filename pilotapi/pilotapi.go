// Package pilotapi is the free, public contract between llmpilot's surfaces
// and the autopilot engine. It declares the shared data types every surface
// consumes, the policy/scheduler/wake interfaces the engine implements, and
// the display math (utilization, wake plans) that gates nothing.
//
// It lives at the module root — not under internal/ — because the engine is
// a separate Go module (github.com/alicicek/llmpilot-pro, compiled only into
// official builds via the `pro` build tag) and the compiler forbids
// cross-module imports of internal packages. Nothing here is engine IP:
// source builds compile a fully working free app against this package alone.
package pilotapi
