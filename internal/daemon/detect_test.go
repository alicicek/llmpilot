package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
)

func fakeDetected(configDir, email string) detect.Detected {
	return detect.Detected{
		Dir:     claudecfg.DirAt(configDir),
		Account: &claudecfg.OAuthAccount{EmailAddress: email},
	}
}

// TestDetectNotWired proves GET /v1/detect answers 501 when Detect is nil —
// same "not wired" discipline as handleSwitch.
func TestDetectNotWired(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/detect")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

func TestDetectMarksRegistered(t *testing.T) {
	st := testStore(t) // registers accounts "a" (a@example.dev) and "b"
	accs, _ := st.Accounts()
	accs[0].ConfigDir = "/fake/dir-a"
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{
				fakeDetected("/fake/dir-a", "a@example.dev"),     // already registered (by dir)
				fakeDetected("/fake/dir-new", "new@example.dev"), // not registered
			}, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/detect")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var out []struct {
		ConfigDir  string `json:"config_dir"`
		Email      string `json:"email"`
		Registered bool   `json:"registered"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out) != 2 {
		t.Fatalf("detected = %+v", out)
	}
	byEmail := map[string]bool{}
	for _, o := range out {
		byEmail[o.Email] = o.Registered
	}
	if !byEmail["a@example.dev"] {
		t.Errorf("a@example.dev should be registered: %+v", out)
	}
	if byEmail["new@example.dev"] {
		t.Errorf("new@example.dev should NOT be registered: %+v", out)
	}
}

func TestAdoptNotWired(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/adopt", "application/json", strings.NewReader(`{"config_dir":"/x"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

// TestAdoptFlow drives POST /v1/adopt end to end against a stub Adopt that
// behaves like the real switcher.AddAccount: it actually registers the
// account, so a second adopt of the same dir must 409.
func TestAdoptFlow(t *testing.T) {
	st := testStore(t)
	adoptCalls := 0
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{fakeDetected("/fake/dir-new", "new@example.dev")}, nil
		},
		Adopt: func(_ context.Context, det detect.Detected, label string) (store.Account, error) {
			adoptCalls++
			acct := store.Account{ID: "acct-new", Label: label, Email: det.Account.EmailAddress, ConfigDir: det.Dir.Path()}
			accs, err := st.Accounts()
			if err != nil {
				return store.Account{}, err
			}
			if err := st.SaveAccounts(append(accs, acct)); err != nil {
				return store.Account{}, err
			}
			return acct, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	// wrong content-type → 415
	badCT, err := http.Post(srv.URL+"/v1/adopt", "text/plain", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = badCT.Body.Close()
	if badCT.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415", badCT.StatusCode)
	}

	// unknown config dir → 404
	notFound, err := http.Post(srv.URL+"/v1/adopt", "application/json", strings.NewReader(`{"config_dir":"/nope"}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = notFound.Body.Close()
	if notFound.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", notFound.StatusCode)
	}

	// success → 201, account returned, actually registered
	ok, err := http.Post(srv.URL+"/v1/adopt", "application/json", strings.NewReader(`{"config_dir":"/fake/dir-new"}`))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(ok.Body)
	_ = ok.Body.Close()
	if ok.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d, body = %s", ok.StatusCode, body)
	}
	var acct store.Account
	if err := json.Unmarshal(body, &acct); err != nil {
		t.Fatal(err)
	}
	if acct.Email != "new@example.dev" || acct.ID != "acct-new" {
		t.Fatalf("adopted account = %+v", acct)
	}
	if adoptCalls != 1 {
		t.Fatalf("adoptCalls = %d, want 1", adoptCalls)
	}

	// re-adopt the same dir → 409
	again, err := http.Post(srv.URL+"/v1/adopt", "application/json", strings.NewReader(`{"config_dir":"/fake/dir-new"}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = again.Body.Close()
	if again.StatusCode != http.StatusConflict {
		t.Fatalf("re-adopt status = %d, want 409", again.StatusCode)
	}
}
