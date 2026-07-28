package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"context"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/store"
)

// sandboxDoctor points every path at temp dirs: the Protocol-10 rule is that
// an env var alone is not enough, so this test additionally never registers a
// readable Keychain — the interlock refuses one under LLMPILOT_TEST, and the
// sweep reports the checks that needed it as NOT CHECKED rather than passing.
func sandboxDoctor(t *testing.T) *store.Store {
	t.Helper()
	home := t.TempDir()
	claudeHome := t.TempDir()
	t.Setenv("LLMPILOT_TEST", "1")
	t.Setenv("HOME", claudeHome)
	t.Setenv("LLMPILOT_HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(claudeHome, ".claude"))
	t.Setenv("LLMPILOT_KEYCHAIN", "")

	st := store.At(home)
	if err := st.SaveAccounts([]store.Account{
		{ID: "main", Label: "main", Email: "main@example.dev", ConfigDir: filepath.Join(claudeHome, ".claude")},
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(claudeHome, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	return st
}

func runDoctor(t *testing.T, args ...string) string {
	t.Helper()
	cmd := doctorCmd()
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	cmd.SetArgs(args)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("llmpilot doctor: %v (output: %s)", err, buf.String())
	}
	return buf.String()
}

// TestDoctorDegraded: with no daemon answering, `llmpilot doctor` reports that
// first, marks every daemon-only check NOT CHECKED, and never prints a clean
// bill. A diagnostic that stays silent about its own blind spots is worse than
// no diagnostic.
func TestDoctorDegraded(t *testing.T) {
	sandboxDoctor(t)

	var doc struct {
		doctor.Report
		Degraded bool `json:"degraded"`
	}
	if err := json.Unmarshal([]byte(runDoctor(t, "--json")), &doc); err != nil {
		t.Fatalf("decode --json: %v", err)
	}
	if !doc.Degraded {
		t.Error("no daemon answered and the report did not say it was degraded")
	}
	if len(doc.Findings) == 0 || doc.Findings[0].ID != "daemon_down" {
		t.Fatalf("the daemon being down must be the FIRST finding, got %+v", doc.Findings)
	}
	if doc.Clean {
		t.Error("a degraded sweep printed a clean bill")
	}
	notChecked := map[string]string{}
	for _, c := range doc.Checks {
		if c.State == doctor.StateNotChecked {
			notChecked[c.ID] = c.Why
		}
	}
	for _, id := range []string{doctor.CheckFrozen, doctor.CheckDeadSignIns, doctor.CheckKeptSignIns} {
		why, ok := notChecked[id]
		if !ok {
			t.Errorf("%s was not reported as not_checked with the daemon down", id)
			continue
		}
		if why == "" {
			t.Errorf("%s: not_checked with no reason at all", id)
		}
		// The EXACT reason, not merely a mention of the daemon: the sweep has
		// two of them, and each must match the finding printed above it.
		if why != "the daemon is not running, so llmpilot cannot see this" {
			t.Errorf("%s: not-checked reason = %q, want the daemon-is-not-running one", id, why)
		}
	}
	// Nothing may be claimed about the accounts only the daemon can judge.
	for _, f := range doc.Findings {
		switch f.ID {
		case "account_frozen", "signin_rejected", "stash_waiting", "stash_dead":
			t.Errorf("%s was reported with no daemon running — the CLI cannot know it", f.ID)
		}
	}

	// The human rendering says the same thing, in words.
	out := runDoctor(t)
	for _, want := range []string{
		"daemon not running",
		"The daemon is not running",
		"llmpilot daemon install",
		"Not checked (",
		"frozen accounts",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("`llmpilot doctor` output missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "No problems found — all") {
		t.Errorf("the degraded run printed an all-clear:\n%s", out)
	}
	// No secret material in terminal output either.
	for _, secret := range []string{"accessToken", "refreshToken", "sk-ant"} {
		if strings.Contains(out, secret) {
			t.Errorf("terminal output carries %q", secret)
		}
	}
}

// homeFingerprint hashes every file under a directory by NAME and CONTENT.
// Counting entries cannot see a rename — and a rename is exactly the write
// this command must never perform (`store.Retirements` quarantines an
// unreadable record that way; the doctor reads it with the non-rebuilding
// reader precisely so it cannot).
func homeFingerprint(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	if err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		out[rel] = hex.EncodeToString(sum[:])
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestDoctorReportsOnly proves the command is a diagnostic and nothing else:
// it takes no flags that act, and a run over a home whose retirement record is
// CORRUPT — the one input that makes the engine's own reader want to rebuild
// (rename) it — leaves every file exactly as it was.
func TestDoctorReportsOnly(t *testing.T) {
	st := sandboxDoctor(t)
	if err := os.WriteFile(filepath.Join(st.Home(), "retirements.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	before := homeFingerprint(t, st.Home())
	out := runDoctor(t)
	after := homeFingerprint(t, st.Home())

	for path, sum := range before {
		now, ok := after[path]
		if !ok {
			t.Errorf("the doctor DELETED (or renamed) %s", path)
			continue
		}
		if now != sum {
			t.Errorf("the doctor REWROTE %s", path)
		}
	}
	for path := range after {
		if _, ok := before[path]; !ok {
			t.Errorf("the doctor CREATED %s — a diagnostic that mutates what it diagnoses is not a diagnostic", path)
		}
	}
	// ...and it SAID the record was unreadable rather than quietly moving on.
	if !strings.Contains(out, "cannot read its record of migrated folders") {
		t.Errorf("a corrupt retirement record was not reported:\n%s", out)
	}
	for _, flag := range []string{"fix", "repair", "clean"} {
		if doctorCmd().Flags().Lookup(flag) != nil {
			t.Errorf("`llmpilot doctor` grew a --%s flag — a diagnostic that acts can break what it diagnoses", flag)
		}
	}
}

// TestDoctorSkewDoesNotSayTheDaemonIsDown: a daemon OLDER than this binary has
// no /v1/doctor route, so the embedded cockpit's catch-all answers 200 with
// index.html. Every user upgrading past this release hits exactly that. Telling
// them to start the daemon they are already running is the same class of lie
// as a false all-clear, pointed the other way — and the banner, the finding and
// every not-checked reason must tell one story.
func TestDoctorSkewDoesNotSayTheDaemonIsDown(t *testing.T) {
	for _, tc := range []struct {
		name string
		// wantSeen is the OBSERVATION that must reach the rendered finding:
		// each shape says what it actually saw, not one canned sentence.
		wantSeen string
		handler  http.HandlerFunc
	}{
		{"an older daemon serving the cockpit shell", "not the document llmpilot asked for", func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte("<!doctype html><title>llmpilot</title>"))
		}},
		{"a route that does not exist", "it answered 404", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusNotFound)
		}},
		{"a daemon whose own sweep is failing", "it answered 500", func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
		}},
		{"json that is not a health report", "without a single health check", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"unrelated":true}`))
		}},
		{"a report carrying no checks at all", "without a single health check", func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"clean":true,"problems":0,"findings":[],"checks":[]}`))
		}},
		{"a connection that opens and goes quiet", "sent no usable answer", nil},
	} {
		t.Run(tc.name, func(t *testing.T) { doctorSkewCase(t, tc.handler, tc.wantSeen) })
	}
}

// TestDoctorSlowDaemonIsNotOfferedAHardKill: BUSY is not STALE. The health
// sweep is the daemon's most expensive route, so a daemon working through a
// large fleet lands here — and `launchctl kickstart -k` would stop it
// mid-rotation. The report must say what it observed and offer nothing to
// press.
func TestDoctorSlowDaemonIsNotOfferedAHardKill(t *testing.T) {
	st := sandboxDoctor(t)
	prev := doctorTimeout
	doctorTimeout = 150 * time.Millisecond
	t.Cleanup(func() { doctorTimeout = prev })
	if prev < 2*time.Second {
		t.Errorf("the shipped doctor timeout is %v — a diagnostic must outlast a busy daemon's sweep", prev)
	}

	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-release:
		case <-r.Context().Done():
		}
	}))
	t.Cleanup(func() { close(release); srv.Close() })
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(st.Home()), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var doc doctor.Report
	if err := json.Unmarshal([]byte(runDoctor(t, "--json")), &doc); err != nil {
		t.Fatalf("decode --json: %v", err)
	}
	var skew *doctor.Finding
	for i, f := range doc.Findings {
		if f.ID == "daemon_unreachable" {
			skew = &doc.Findings[i]
		}
		if f.ID == "daemon_down" {
			t.Error("a daemon that accepted the connection was reported as not running")
		}
	}
	if skew == nil {
		t.Fatalf("nothing reported about the daemon: %+v", doc.Findings)
	}
	if !strings.Contains(skew.Detail, "did not answer in time") {
		t.Errorf("the finding does not say what was observed: %q", skew.Detail)
	}
	if strings.Contains(skew.Detail, "older than this copy") {
		t.Errorf("a busy daemon was diagnosed as a stale one: %q", skew.Detail)
	}
	if skew.Remedy.Verb != doctor.VerbNone || skew.Remedy.Command != "" {
		t.Errorf("a busy daemon was offered %+v — a hard kill would stop it mid-work", skew.Remedy)
	}
	// A daemon that is doing its job, just slowly, is not "the fleet is not
	// working right now" — and a red badge over a healthy fleet trains people
	// to ignore the real ones.
	if skew.Severity != doctor.Warning {
		t.Errorf("a busy daemon was graded %q, want warning", skew.Severity)
	}

	out := runDoctor(t)
	if strings.Contains(out, "kickstart") {
		t.Errorf("the terminal offered a hard kill to a busy daemon:\n%s", out)
	}
}

func doctorSkewCase(t *testing.T, handler http.HandlerFunc, wantSeen string) {
	t.Helper()
	st := sandboxDoctor(t)
	var srv *httptest.Server
	if handler != nil {
		srv = httptest.NewServer(handler)
	} else {
		// Accept the connection, answer nothing, hang up: something IS there.
		srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hj, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("no hijacker")
			}
			conn, _, err := hj.Hijack()
			if err != nil {
				t.Fatal(err)
			}
			_ = conn.Close()
		}))
	}
	defer srv.Close()
	port := srv.URL[strings.LastIndexByte(srv.URL, ':')+1:]
	if err := os.WriteFile(daemon.PortFilePath(st.Home()), []byte(port+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var doc struct {
		doctor.Report
		Degraded bool `json:"degraded"`
	}
	if err := json.Unmarshal([]byte(runDoctor(t, "--json")), &doc); err != nil {
		t.Fatalf("decode --json: %v", err)
	}
	ids := map[string]doctor.Finding{}
	for _, f := range doc.Findings {
		ids[f.ID] = f
	}
	if _, ok := ids["daemon_down"]; ok {
		t.Error("a daemon that answered was reported as not running")
	}
	skew, ok := ids["daemon_unreachable"]
	if !ok {
		t.Fatalf("nothing reported about the daemon at all: %+v", doc.Findings)
	}
	// Declared, not proven: all llmpilot knows is that SOMETHING replied.
	if !strings.Contains(skew.Detail, "Something is listening") {
		t.Errorf("the finding asserts more than llmpilot knows: %q", skew.Detail)
	}
	// The rendered finding must carry THIS shape's observation — a literal in
	// place of the accessor satisfies every other assertion here.
	if !strings.Contains(skew.Detail, wantSeen) {
		t.Errorf("the finding does not say what was seen (%q):\n%s", wantSeen, skew.Detail)
	}
	if doc.Clean {
		t.Error("a sweep with no daemon facts printed a clean bill")
	}

	// The remedy must be a command that actually bounces a LOADED daemon —
	// `daemon install` only writes the launch agent, so pointing there would
	// loop this user through a no-op.
	if skew.Remedy.Command != daemon.RestartCommand() {
		t.Errorf("restart command = %q, want %q", skew.Remedy.Command, daemon.RestartCommand())
	}
	// ...and that command must name the agent, in a domain launchctl accepts,
	// with the uid RESOLVED (tcsh and fish do not define $UID).
	want := fmt.Sprintf("launchctl kickstart -k gui/%d/%s", os.Getuid(), daemon.LaunchAgentLabel)
	if skew.Remedy.Command != want {
		t.Errorf("restart command = %q, want %q", skew.Remedy.Command, want)
	}
	if skew.Severity != doctor.Critical {
		t.Errorf("severity = %q, want critical", skew.Severity)
	}
	if skew.Remedy.Label != "Restart the daemon" {
		t.Errorf("remedy label = %q, want it to match the command it carries", skew.Remedy.Label)
	}

	out := runDoctor(t)
	if strings.Contains(out, "daemon not running") {
		t.Errorf("the banner still says the daemon is not running:\n%s", out)
	}
	if !strings.Contains(out, "did not answer with a health report") {
		t.Errorf("the banner does not say what actually happened:\n%s", out)
	}
	// The coverage reasons must not contradict the finding above them — and
	// each must SAY something: an empty reason is a not-checked entry that
	// explains nothing, which the package's own rule forbids.
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "the daemon is not running, so llmpilot cannot see this") {
			t.Errorf("a not-checked reason contradicts the finding: %q", line)
		}
	}
	for _, c := range doc.Checks {
		if c.State != doctor.StateNotChecked {
			continue
		}
		switch c.ID {
		case doctor.CheckFrozen, doctor.CheckDeadSignIns, doctor.CheckKeptSignIns:
			if c.Why != "llmpilot could not get an answer from the daemon, so it cannot see this" {
				t.Errorf("%s: reason = %q, want the could-not-get-an-answer one", c.ID, c.Why)
			}
		}
	}
}

// TestDoctorUnreachableFallbackNeverOffersTheNoOp: if a future caller sets the
// reason and forgets the remedy, the report must say it has nothing rather
// than reinstate `llmpilot daemon install` — the command that does nothing to
// a loaded agent, which is the bug this whole branch exists to remove.
func TestDoctorUnreachableFallbackNeverOffersTheNoOp(t *testing.T) {
	rep := doctor.Run(context.Background(), doctor.Inputs{
		Accounts:          func() ([]store.Account, error) { return nil, nil },
		DaemonUnreachable: "something answered",
	})
	var found bool
	for _, f := range rep.Findings {
		if f.ID != "daemon_unreachable" {
			continue
		}
		found = true
		if f.Remedy.Command != "" {
			t.Errorf("the fallback offered a command (%q) — it cannot know one works", f.Remedy.Command)
		}
		if f.Remedy.Verb != doctor.VerbNone {
			t.Errorf("fallback verb = %q, want none", f.Remedy.Verb)
		}
	}
	if !found {
		t.Fatal("no finding at all for an unreachable daemon")
	}
}

// The bug this pins: a correct app install registers the agent through
// SMAppService from the plist inside the bundle, so ~/Library/LaunchAgents is
// empty. Statting that path alone reported "llmpilot will not start at login"
// on every such Mac, and sent the user to `daemon install` — a no-op for an
// already-loaded agent, so the warning could never be cleared.
func TestInstallFactsSeesSMAppServiceRegistration(t *testing.T) {
	t.Setenv("HOME", t.TempDir()) // no legacy plist: the app-install shape
	old := launchAgentRegistered
	t.Cleanup(func() { launchAgentRegistered = old })

	t.Run("registered with launchd counts as installed", func(t *testing.T) {
		launchAgentRegistered = func() (bool, error) { return true, nil }
		f, err := installFacts()
		if err != nil {
			t.Fatal(err)
		}
		if !f.LaunchAgentInstalled {
			t.Error("an SMAppService registration was reported as no login item")
		}
		if f.LaunchAgentErr != "" {
			t.Errorf("unexpected error fact: %s", f.LaunchAgentErr)
		}
	})

	t.Run("launchd denying the label is genuinely missing", func(t *testing.T) {
		launchAgentRegistered = func() (bool, error) { return false, nil }
		f, err := installFacts()
		if err != nil {
			t.Fatal(err)
		}
		if f.LaunchAgentInstalled {
			t.Error("no plist and no launchd registration must read as missing")
		}
		if f.LaunchAgentErr != "" {
			t.Errorf("a definite denial is not an error: %s", f.LaunchAgentErr)
		}
	})

	t.Run("an unreadable probe is NOT CHECKED, not missing", func(t *testing.T) {
		launchAgentRegistered = func() (bool, error) { return false, errors.New("launchctl exploded") }
		f, err := installFacts()
		if err != nil {
			t.Fatal(err)
		}
		if f.LaunchAgentInstalled {
			t.Error("a failed probe must not claim the agent is installed")
		}
		if f.LaunchAgentErr == "" {
			t.Error("a failed probe must surface an error so the sweep reports NOT CHECKED rather than a false alarm")
		}
	})
}
