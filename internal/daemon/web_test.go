package daemon

import (
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestWebHandlerNotBuilt(t *testing.T) {
	// A Go-only build embeds just .gitkeep — the handler must say so
	// honestly, never 404 or serve a broken shell.
	h := webHandler(fstest.MapFS{".gitkeep": &fstest.MapFile{}})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Cockpit not built") {
		t.Fatalf("want not-built page, got %d %q", rec.Code, rec.Body.String())
	}
}

func TestWebHandlerServesAndFallsBack(t *testing.T) {
	dist := fstest.MapFS{
		"index.html":        &fstest.MapFile{Data: []byte("<html>cockpit</html>")},
		"assets/app-abc.js": &fstest.MapFile{Data: []byte("js!")},
	}
	h := webHandler(dist)

	cases := []struct {
		path, want string
	}{
		{"/", "cockpit"},
		{"/assets/app-abc.js", "js!"},
		{"/no/such/route", "cockpit"}, // SPA fallback
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", c.path, nil))
		if rec.Code != 200 || !strings.Contains(rec.Body.String(), c.want) {
			t.Fatalf("%s: want %q, got %d %q", c.path, c.want, rec.Code, rec.Body.String())
		}
	}
}

func TestWebDoesNotShadowAPI(t *testing.T) {
	d := &Daemon{
		Store: testStore(t),
		WebFS: fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("cockpit")}},
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/state", nil)
	req.Host = "127.0.0.1:5555" // checkHost admits loopback only
	d.Handler().ServeHTTP(rec, req)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "accounts") {
		t.Fatalf("API shadowed by web handler: %d %q", rec.Code, rec.Body.String())
	}
}
