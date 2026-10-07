package daemon

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// withToken serves d.Handler() the way the apps reach it: every request
// carries this run's bearer. Tests of the guard itself use the bare
// d.Handler().
func withToken(d *Daemon) http.Handler {
	h := d.Handler()
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+d.authToken)
		h.ServeHTTP(w, r)
	})
}

// registeredRoute is one Handler() registration as written in the source.
type registeredRoute struct {
	method, path string
	fd           *ast.FuncDecl
}

// handlerRoutes parses this package's source and returns every
// mux.HandleFunc registration in Handler(). It fails the test on any other
// use of the mux except the one open route — `mux.Handle("GET /",
// webHandler(...))`, the cockpit's static files, which a browser loads by
// navigation and so cannot carry a header. Reading the code instead of
// calling handlers means no handler body (Keychain sweeps, network calls)
// runs.
func handlerRoutes(t *testing.T) []registeredRoute {
	t.Helper()
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	funcs := map[string]*ast.FuncDecl{}
	var handler *ast.FuncDecl
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range af.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Recv != nil {
				funcs[fd.Name.Name] = fd
				if fd.Name.Name == "Handler" {
					handler = fd
				}
			}
		}
	}
	if handler == nil {
		t.Fatal("Handler() not found")
	}
	var routes []registeredRoute
	static := 0
	// Every mention of the mux must be one this walk understands: its
	// definition, a HandleFunc/Handle receiver, or checkHost's argument. An
	// alias (`m := mux`) or a helper that took the mux could register routes
	// the walk never sees.
	muxIdents, muxKnown := 0, 0
	ast.Inspect(handler.Body, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok && id.Name == "mux" {
			muxIdents++
		}
		return true
	})
	ast.Inspect(handler, func(n ast.Node) bool {
		if as, ok := n.(*ast.AssignStmt); ok && as.Tok == token.DEFINE && len(as.Lhs) == 1 {
			if id, ok := as.Lhs[0].(*ast.Ident); ok && id.Name == "mux" {
				muxKnown++
			}
		}
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if fn, ok := call.Fun.(*ast.Ident); ok && fn.Name == "checkHost" && len(call.Args) == 1 {
			if id, ok := call.Args[0].(*ast.Ident); ok && id.Name == "mux" {
				muxKnown++
			}
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if recv, ok := sel.X.(*ast.Ident); !ok || recv.Name != "mux" {
			return true
		}
		switch sel.Sel.Name {
		case "HandleFunc":
			lit, ok := call.Args[0].(*ast.BasicLit)
			target, ok2 := call.Args[1].(*ast.SelectorExpr)
			if len(call.Args) != 2 || !ok || !ok2 {
				t.Errorf("unrecognized registration at %v", fset.Position(call.Pos()))
				return true
			}
			method, path, _ := strings.Cut(strings.Trim(lit.Value, `"`), " ")
			fd := funcs[target.Sel.Name]
			if fd == nil {
				t.Errorf("%s %s: handler %s not found", method, path, target.Sel.Name)
				return true
			}
			muxKnown++
			routes = append(routes, registeredRoute{method: method, path: path, fd: fd})
		case "Handle":
			lit, ok := call.Args[0].(*ast.BasicLit)
			inner, ok2 := call.Args[1].(*ast.CallExpr)
			if len(call.Args) == 2 && ok && ok2 && lit.Value == `"GET /"` {
				if fn, ok := inner.Fun.(*ast.Ident); ok && fn.Name == "webHandler" {
					muxKnown++
					static++
					return true
				}
			}
			t.Errorf("mux.Handle at %v is an open route — only GET / → webHandler (static files) may skip the install token", fset.Position(call.Pos()))
		default:
			t.Errorf("unrecognized mux.%s at %v", sel.Sel.Name, fset.Position(call.Pos()))
		}
		return true
	})
	if muxIdents != muxKnown {
		t.Errorf("Handler() mentions mux %d times but only %d are a definition, a registration or checkHost — an alias or helper could hide a route", muxIdents, muxKnown)
	}
	if static != 1 {
		t.Errorf("found %d GET / → webHandler registrations, want exactly 1", static)
	}
	if len(routes) < 30 {
		t.Fatalf("walked only %d routes — the registration shape changed; update this test", len(routes))
	}
	return routes
}

// TestEveryRouteRequiresInstallToken walks Handler()'s registrations in the
// source so a new route cannot skip the rule: every API handler — reads
// included — must reach requireAuth before doing anything but inert checks.
// The static cockpit is the one open route (handlerRoutes enforces its shape).
func TestEveryRouteRequiresInstallToken(t *testing.T) {
	isAuthCheck := func(st ast.Stmt) bool {
		ifs, ok := st.(*ast.IfStmt)
		if !ok {
			return false
		}
		not, ok := ifs.Cond.(*ast.UnaryExpr)
		if !ok || not.Op != token.NOT {
			return false
		}
		call, ok := not.X.(*ast.CallExpr)
		if !ok {
			return false
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); !ok || sel.Sel.Name != "requireAuth" {
			return false
		}
		// A refused request must stop there: the guard's body ends in return.
		n := len(ifs.Body.List)
		if n == 0 {
			return false
		}
		_, returns := ifs.Body.List[n-1].(*ast.ReturnStmt)
		return returns
	}
	// inert: statements allowed ahead of the guard — a field read
	// (`g := d.License`) or a refusal that only writes an error and returns
	// (the "licensing not wired" 501s).
	inert := func(st ast.Stmt) bool {
		switch st := st.(type) {
		case *ast.AssignStmt:
			for _, rhs := range st.Rhs {
				if _, ok := rhs.(*ast.SelectorExpr); !ok {
					return false
				}
			}
			return true
		case *ast.IfStmt:
			if st.Init != nil || st.Else != nil {
				return false
			}
			calls := false
			ast.Inspect(st.Cond, func(n ast.Node) bool {
				if _, ok := n.(*ast.CallExpr); ok {
					calls = true
				}
				return !calls
			})
			if calls {
				return false
			}
			for _, b := range st.Body.List {
				switch b := b.(type) {
				case *ast.ReturnStmt:
				case *ast.ExprStmt:
					call, ok := b.X.(*ast.CallExpr)
					if !ok {
						return false
					}
					if id, ok := call.Fun.(*ast.Ident); !ok || id.Name != "httpError" {
						return false
					}
				default:
					return false
				}
			}
			return true
		}
		return false
	}
	opensWithAuth := func(fd *ast.FuncDecl) bool {
		for _, st := range fd.Body.List {
			if isAuthCheck(st) {
				return true
			}
			if !inert(st) {
				return false
			}
		}
		return false
	}
	for _, rt := range handlerRoutes(t) {
		if !opensWithAuth(rt.fd) {
			t.Errorf("%s %s (%s) does not open with requireAuth", rt.method, rt.path, rt.fd.Name.Name)
		}
	}
}

// TestReadsRequireInstallToken pins the cross-user boundary on reads: every
// GET route Handler() registers (taken from the source, so a new read is
// covered the day it lands) answers 401 to a request with no token or a
// wrong one, and the 401 carries only the error — none of the emails,
// folders or statusline commands the daemon holds. Nothing behind the guard
// runs. The same reads WITH the token return that data, so the leak check
// is not vacuous; the static cockpit stays open.
func TestReadsRequireInstallToken(t *testing.T) {
	st := store.At(t.TempDir())
	const (
		email   = "reads-guard@example.dev"
		dir     = "/Users/someone/.claude-reads-guard"
		planted = "echo planted-read"
	)
	if err := st.SaveAccounts([]store.Account{{ID: "a", Label: "a", Email: email, ConfigDir: dir}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSchedules([]store.Schedule{{ID: "s1", AccountID: "a", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	cfg := `{"version":1,"segments":[{"id":"command","options":{"command":"` + planted + `"}}],"keep":{"command":"` + planted + `"}}`
	if err := os.WriteFile(statusline.ConfigPath(st.Home()), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	reached := false
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			reached = true
			return []detect.Detected{fakeDetected(dir, email)}, nil
		},
		MovedDirs: func(context.Context) (map[string]bool, error) { reached = true; return nil, nil },
		StashList: func(context.Context) ([]pilotapi.StashEntry, error) { reached = true; return nil, nil },
		WebFS:     fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("cockpit")}},
	}
	srv := httptest.NewServer(d.Handler())
	// Drop the connections first: an unguarded stream would otherwise keep
	// its handler alive and Close would wait on it forever.
	defer func() { srv.CloseClientConnections(); srv.Close() }()

	gets := 0
	for _, rt := range handlerRoutes(t) {
		if rt.method != http.MethodGet {
			continue
		}
		gets++
		for _, tok := range []string{"", "not-the-token"} {
			for _, method := range []string{http.MethodGet, http.MethodHead} {
				resp, body := doAuthed(t, method, srv.URL+rt.path, "", tok)
				if resp.StatusCode != http.StatusUnauthorized {
					t.Errorf("%s %s with token %q = %d, want 401", method, rt.path, tok, resp.StatusCode)
					continue
				}
				if method == http.MethodHead {
					continue
				}
				var got map[string]any
				if err := json.Unmarshal([]byte(body), &got); err != nil || len(got) != 2 || got["code"] != "auth_required" {
					t.Errorf("GET %s 401 body = %s, want only {error, code: auth_required}", rt.path, body)
				}
				for _, secret := range []string{email, dir, planted} {
					if strings.Contains(body, secret) {
						t.Errorf("GET %s with token %q leaked %q", rt.path, tok, secret)
					}
				}
			}
		}
	}
	if gets < 15 {
		t.Fatalf("walked only %d GET routes, want at least 15", gets)
	}
	if reached {
		t.Error("an unauthenticated read reached detect, the moved-folder check or the stash")
	}

	// With the token the same reads carry the data the 401s withheld.
	for path, want := range map[string]string{
		"/v1/state":             email,
		"/v1/statusline/config": planted,
		"/v1/detect":            dir,
	} {
		resp, body := doAuthed(t, http.MethodGet, srv.URL+path, "", d.authToken)
		if resp.StatusCode != http.StatusOK || !strings.Contains(body, want) {
			t.Errorf("authed GET %s = %d, want 200 containing %q (body %.200s)", path, resp.StatusCode, want, body)
		}
	}
	// The static cockpit is the one route a browser loads without a header.
	resp, body := doAuthed(t, http.MethodGet, srv.URL+"/", "", "")
	if resp.StatusCode != http.StatusOK || body != "cockpit" {
		t.Errorf("GET / without a token = %d %q, want 200 cockpit", resp.StatusCode, body)
	}
}

// TestStateMutationsRequireInstallToken pins the cross-user boundary on the
// routes that reach a shell, a credential, or launchd: without this run's
// token each answers 401 and nothing behind it runs or is saved. The
// statusline PUT carries a command segment and keep.command — the statusline
// runs both through the shell on every prompt.
func TestStateMutationsRequireInstallToken(t *testing.T) {
	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{{ID: "a", Label: "a", Email: "a@example.dev"}}); err != nil {
		t.Fatal(err)
	}
	if err := st.SaveSchedules([]store.Schedule{{ID: "s1", AccountID: "a", Hour: 9}}); err != nil {
		t.Fatal(err)
	}
	reached := func(what string) { t.Errorf("an unauthenticated request reached %s", what) }
	d := &Daemon{
		Store:  st,
		Switch: func(context.Context, string) error { reached("the switcher"); return nil },
		Detect: func(context.Context) ([]detect.Detected, error) { reached("detect"); return nil, nil },
		Adopt: func(context.Context, detect.Detected, string) (store.Account, error) {
			reached("adopt")
			return store.Account{}, nil
		},
		TriggerSync: func(context.Context, []store.Schedule) error { reached("launchd sync"); return nil },
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	planted := `{"version":1,"segments":[{"id":"command","options":{"command":"echo planted"}}],"keep":{"command":"echo planted"}}`
	routes := []struct{ method, path, body string }{
		{http.MethodPut, "/v1/statusline/config", planted},
		{http.MethodPost, "/v1/switch", `{"account_id":"a"}`},
		{http.MethodPost, "/v1/adopt", `{"config_dir":"/x"}`},
		{http.MethodPut, "/v1/config", `{"autopilot":{"threshold_percent":1}}`},
		{http.MethodPost, "/v1/schedules", `{"account_id":"a","hour":10,"minute":0}`},
		{http.MethodPut, "/v1/schedules/s1", `{"hour":11,"minute":0}`},
		{http.MethodDelete, "/v1/schedules/s1", `{}`},
	}
	for _, tok := range []string{"", "not-the-token"} {
		for _, rt := range routes {
			resp, body := doAuthed(t, rt.method, srv.URL+rt.path, rt.body, tok)
			if resp.StatusCode != http.StatusUnauthorized || !strings.Contains(body, `"auth_required"`) {
				t.Errorf("%s %s with token %q = %d (%s), want 401 auth_required", rt.method, rt.path, tok, resp.StatusCode, body)
			}
		}
	}

	if _, err := os.Stat(statusline.ConfigPath(st.Home())); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("statusline config written without the token (stat: %v)", err)
	}
	if cfg, err := st.Config(); err != nil || cfg.Autopilot.ThresholdPercent != 0 {
		t.Errorf("autopilot config changed without the token: %+v (%v)", cfg.Autopilot, err)
	}
	if scheds, err := st.Schedules(); err != nil || len(scheds) != 1 || scheds[0].Hour != 9 {
		t.Errorf("schedules changed without the token: %+v (%v)", scheds, err)
	}

	// The same config WITH the token saves: the guard admits the user.
	resp, body := doAuthed(t, http.MethodPut, srv.URL+"/v1/statusline/config", planted, d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("authed PUT = %d (%s), want 200", resp.StatusCode, body)
	}
	if _, err := os.Stat(statusline.ConfigPath(st.Home())); err != nil {
		t.Fatalf("authed PUT saved nothing: %v", err)
	}
}

// guardedRoutes enumerates every license route that reveals or mutates. A
// new sensitive route belongs here — the tests below fail closed on the
// whole table.
var guardedRoutes = []struct {
	method, path, body string
}{
	{http.MethodGet, "/v1/license?reveal=1", ""},
	{http.MethodPost, "/v1/license/checkout", `{"rung":"full"}`},
	{http.MethodPost, "/v1/license/cancel", `{}`},
	{http.MethodPost, "/v1/license/recover", `{"email":"a@example.com"}`},
	{http.MethodPost, "/v1/license/recover/claim", `{"token":"tok"}`},
	{http.MethodPost, "/v1/license/marker", `{"present":true}`},
	{http.MethodPost, "/v1/login/start", `{}`},
	{http.MethodPost, "/v1/login/complete", `{"code":"c","state":"s"}`},
	{http.MethodPost, "/v1/login/browser", `{}`},
	{http.MethodPost, "/v1/stash/adopt", `{"fingerprint":"sha256:x"}`},
	{http.MethodPost, "/v1/stash/discard", `{"fingerprint":"sha256:x"}`},
}

func doAuthed(t *testing.T, method, url, body, token string) (*http.Response, string) {
	t.Helper()
	var rdr io.Reader
	if body != "" {
		rdr = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		t.Fatal(err)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	// Bounded and never reused: an unguarded stream (/v1/events) must fail
	// the test, not hang it — a HEAD on a stream leaves its handler running,
	// and a request reusing that connection would wait on it forever.
	req.Close = true
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	raw, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	return resp, string(raw)
}

// TestLicenseRoutesRequireInstallToken pins the loopback auth boundary: a
// caller who can reach 127.0.0.1 but cannot read daemon.token gets 401 from
// every revealing or mutating license route, and the worker is never touched.
func TestLicenseRoutesRequireInstallToken(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Date(2026, 7, 15, 12, 0, 0, 0, time.UTC)
	trialEnd := now.Add(8 * 24 * time.Hour)
	token := signToken(t, "key-a", proTrial(trialEnd.Add(72*time.Hour)), priv)
	store := &memLicenseStore{v: pilot.StoredLicense{
		LicenseID: "lic_guard000000secret", Entitlement: token, Status: "trialing",
		TrialEnd: &trialEnd, StoredAt: now, LastValidated: now,
	}}
	// Any worker call from an unauthenticated request is a confused-deputy
	// escape — fail the test, not just the request.
	worker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("worker reached without install token: %s %s", r.Method, r.URL.Path)
	}))
	defer worker.Close()
	d := licenseDaemon(t, worker.URL, store, pub, true, nil, now)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	for _, tok := range []string{"", "not-the-token"} {
		for _, rt := range guardedRoutes {
			resp, body := doAuthed(t, rt.method, srv.URL+rt.path, rt.body, tok)
			if resp.StatusCode != http.StatusUnauthorized {
				t.Errorf("%s %s with token %q = %d (%s), want 401", rt.method, rt.path, tok, resp.StatusCode, body)
			}
			var got map[string]string
			_ = json.Unmarshal([]byte(body), &got)
			if got["code"] != "auth_required" {
				t.Errorf("%s %s code = %q, want auth_required", rt.method, rt.path, got["code"])
			}
			if strings.Contains(body, "lic_guard000000secret") {
				t.Errorf("%s %s leaked the license id in a 401", rt.method, rt.path)
			}
		}
	}

	// The masked view takes the token too, and still hides the full id.
	resp, body := doAuthed(t, http.MethodGet, srv.URL+"/v1/license", "", "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("masked GET without a token = %d (%s), want 401", resp.StatusCode, body)
	}
	resp, body = doAuthed(t, http.MethodGet, srv.URL+"/v1/license", "", d.authToken)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("authed masked GET = %d (%s), want 200", resp.StatusCode, body)
	}
	if strings.Contains(body, "lic_guard000000secret") {
		t.Fatal("masked GET leaked the full license id")
	}
	// reveal=1 WITH the token serves the full id (worker still untouched).
	resp, body = doAuthed(t, http.MethodGet, srv.URL+"/v1/license?reveal=1", "", d.authToken)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, "lic_guard000000secret") {
		t.Fatalf("authed reveal = %d (%s)", resp.StatusCode, body)
	}
}

// TestAuthFailsClosedWithEmptyToken proves a daemon whose token generation
// failed refuses even an empty Bearer value — "" never matches "".
func TestAuthFailsClosedWithEmptyToken(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	d := licenseDaemon(t, "http://unused.invalid", &memLicenseStore{}, pub, true, nil, time.Now())
	d.authToken = ""
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/license/cancel", `{}`, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("empty-token daemon answered %d (%s), want 401", resp.StatusCode, body)
	}
}

// TestCheckHostRejectsForeignHost pins the DNS-rebinding guard: a request
// carrying a non-loopback Host never reaches any handler.
func TestCheckHostRejectsForeignHost(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	d := licenseDaemon(t, "http://unused.invalid", &memLicenseStore{}, pub, true, nil, time.Now())
	h := d.Handler()

	for _, host := range []string{"127.0.0.1:5555", "localhost:5555", "[::1]:5555", "llmpilot"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/state", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code == http.StatusForbidden {
			t.Errorf("Host %q rejected, want admitted", host)
		}
	}
	for _, host := range []string{"evil.example.com", "evil.example.com:5555", "127.0.0.1.evil.example.com"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/state", nil)
		req.Host = host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Errorf("Host %q = %d, want 403", host, rec.Code)
		}
	}
}
