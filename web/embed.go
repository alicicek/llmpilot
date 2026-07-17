// Package web embeds the built cockpit (dist/) into the binary. Run
// `pnpm build` in web/ to populate dist; a fresh clone carries only
// dist/.gitkeep and the daemon serves an honest "cockpit not built" page.
package web

import (
	"embed"
	"io/fs"
)

//go:embed all:dist
var dist embed.FS

// Dist is the built cockpit rooted at its index.html.
func Dist() fs.FS {
	sub, err := fs.Sub(dist, "dist")
	if err != nil {
		// The dist directory is embedded at compile time; Sub only fails if
		// the path is invalid, which a build with this file cannot be.
		panic(err)
	}
	return sub
}
