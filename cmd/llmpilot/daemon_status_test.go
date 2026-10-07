package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/daemon"
)

// TestDaemonStatusDoesNotCallAnAnsweringDaemonDown: a daemon that answers 401
// (this CLI could not present its token) is running. Saying "not running —
// llmpilot daemon install" would send the user to rewrite a working launch
// agent.
func TestDaemonStatusDoesNotCallAnAnsweringDaemonDown(t *testing.T) {
	st := sandboxDoctor(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"code":"auth_required"}`))
	}))
	defer srv.Close()
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(st.Home()), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cmd := daemonStatusCmd()
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("daemon status: %v (output: %s)", err, buf.String())
	}
	out := buf.String()
	if strings.Contains(out, "not running") {
		t.Errorf("an answering daemon was called not running:\n%s", out)
	}
	if !strings.Contains(out, "answered 401") {
		t.Errorf("status does not say what it saw:\n%s", out)
	}
}
