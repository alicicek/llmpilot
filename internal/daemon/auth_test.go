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
	"time"

	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
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

// guardedReads are the only GET routes that take the install token. Every
// other GET must stay open: the apps read them without a bearer (the native
// first-run screen reads /v1/detect bare).
var guardedReads = map[string]bool{
	"/v1/notices":              true,
	"/v1/login/browser/status": true,
}

// TestEveryRouteGuardsByMethod walks Handler()'s registrations in the source
// so a new route cannot skip the rule: every non-GET handler must reach
// requireAuth before doing anything but inert checks, and a GET handler must
// do so only when listed in guardedReads. It reads the code instead of calling handlers, so no handler
// body (Keychain sweeps, network calls) runs.
func TestEveryRouteGuardsByMethod(t *testing.T) {
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
		sel, ok := call.Fun.(*ast.SelectorExpr)
		return ok && sel.Sel.Name == "requireAuth"
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
	routes := 0
	ast.Inspect(handler, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || len(call.Args) != 2 {
			return true
		}
		if sel, ok := call.Fun.(*ast.SelectorExpr); !ok || sel.Sel.Name != "HandleFunc" {
			return true
		}
		lit, ok := call.Args[0].(*ast.BasicLit)
		target, ok2 := call.Args[1].(*ast.SelectorExpr)
		if !ok || !ok2 {
			t.Errorf("unrecognized registration at %v", fset.Position(call.Pos()))
			return true
		}
		method, path, _ := strings.Cut(strings.Trim(lit.Value, `"`), " ")
		fd := funcs[target.Sel.Name]
		if fd == nil {
			t.Errorf("%s %s: handler %s not found", method, path, target.Sel.Name)
			return true
		}
		routes++
		wantAuth := method != http.MethodGet || guardedReads[path]
		if got := opensWithAuth(fd); got != wantAuth {
			t.Errorf("%s %s (%s) opens with requireAuth = %v, want %v", method, path, fd.Name.Name, got, wantAuth)
		}
		return true
	})
	if routes < 30 {
		t.Fatalf("walked only %d routes — the registration shape changed; update this test", routes)
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
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
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

	// The masked read-only view stays open — the statusline/menu bar tier.
	resp, body := doAuthed(t, http.MethodGet, srv.URL+"/v1/license", "", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("masked GET = %d (%s), want 200", resp.StatusCode, body)
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
