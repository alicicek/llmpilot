package daemon

import (
	"io/fs"
	"net/http"
)

// notBuiltPage is served when the embedded dist carries no index.html
// (a Go-only build where web/ was never compiled). Honest, not a 404.
const notBuiltPage = `<!doctype html><meta charset="utf-8"><title>llmpilot</title>
<body style="font-family:-apple-system,system-ui,sans-serif;padding:40px;color:#59595e">
<p style="font-weight:600;color:#1d1d1f">Cockpit not built into this binary.</p>
<p>Build it: <code>cd web &amp;&amp; pnpm build</code>, then rebuild llmpilot.</p>`

// webHandler serves the embedded cockpit. Anything that is not a real file
// falls back to index.html (the cockpit is a single page); a dist without
// index.html gets the not-built page.
func webHandler(dist fs.FS) http.Handler {
	fileServer := http.FileServerFS(dist)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, err := fs.Stat(dist, "index.html"); err != nil {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(notBuiltPage))
			return
		}
		path := r.URL.Path
		if path != "/" {
			if _, err := fs.Stat(dist, path[1:]); err != nil {
				r.URL.Path = "/" // SPA fallback
			}
		}
		fileServer.ServeHTTP(w, r)
	})
}
