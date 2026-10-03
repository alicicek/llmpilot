package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// POST /v1/statusline/install: install-token guarded, 501 until wired, 400 on
// a mode outside the vocabulary, and a foreign line answers 409 with
// NOTHING written — the daemon only ever relays the installer's own consent
// rule, it never adds a path around it.
func TestStatuslineInstallEndpoint(t *testing.T) {
	var calls []string
	d := &Daemon{Store: testStore(t)}
	d.authToken = "tok-install-test"
	d.StatuslineInstaller = func(mode string) (string, error) {
		calls = append(calls, mode)
		if mode == "" {
			return "foreign", nil
		}
		return "kept", nil
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, body := doAuthed(t, http.MethodPost, srv.URL+"/v1/statusline/install", `{"mode":""}`, "")
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthed = %d (%s), want 401", resp.StatusCode, body)
	}
	if len(calls) != 0 {
		t.Fatal("installer ran without the install token")
	}

	resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/statusline/install", `{"mode":"nuke"}`, d.authToken)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad mode = %d (%s), want 400", resp.StatusCode, body)
	}
	if len(calls) != 0 {
		t.Fatal("installer ran on an invalid mode")
	}

	resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/statusline/install", `{"mode":""}`, d.authToken)
	if resp.StatusCode != http.StatusConflict || !strings.Contains(body, `"outcome":"foreign"`) {
		t.Fatalf("foreign = %d (%s), want 409 outcome foreign", resp.StatusCode, body)
	}

	resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/statusline/install", `{"mode":"keep"}`, d.authToken)
	if resp.StatusCode != http.StatusOK || !strings.Contains(body, `"outcome":"kept"`) {
		t.Fatalf("keep = %d (%s), want 200 outcome kept", resp.StatusCode, body)
	}
	if strings.Join(calls, ",") != ",keep" {
		t.Fatalf("installer calls = %q, want exactly the refuse probe then keep", calls)
	}

	d.StatuslineInstaller = nil
	resp, body = doAuthed(t, http.MethodPost, srv.URL+"/v1/statusline/install", `{"mode":""}`, d.authToken)
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("unwired = %d (%s), want 501", resp.StatusCode, body)
	}
}
