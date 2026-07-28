package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestWriteLaunchAgentValidPlist(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, LaunchAgentLabel+".plist")
	if err := WriteLaunchAgent(path, "/usr/local/bin/llmpilot", filepath.Join(dir, "logs")); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{LaunchAgentLabel, "/usr/local/bin/llmpilot", "<string>daemon</string>", "<string>run</string>"} {
		if !strings.Contains(string(data), want) {
			t.Fatalf("plist missing %q:\n%s", want, data)
		}
	}
	if _, err := exec.LookPath("plutil"); err != nil {
		t.Skip("plutil not available (non-macOS CI)")
	}
	out, err := exec.Command("plutil", "-lint", path).CombinedOutput()
	if err != nil || !strings.Contains(string(out), "OK") {
		t.Fatalf("plutil -lint: %v\n%s", err, out)
	}
}

func TestWriteLaunchAgentEscapesXML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "test.plist")
	bin := filepath.Join(dir, `we<ird & path`, "llmpilot")
	if err := WriteLaunchAgent(path, bin, filepath.Join(dir, "logs")); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	if strings.Contains(string(data), "we<ird") {
		t.Fatalf("unescaped XML in plist:\n%s", data)
	}
	if _, err := exec.LookPath("plutil"); err == nil {
		if out, err := exec.Command("plutil", "-lint", path).CombinedOutput(); err != nil {
			t.Fatalf("plutil -lint on escaped plist: %v\n%s", err, out)
		}
	}
}

func TestWriteLaunchAgentRejectsRelativeBinary(t *testing.T) {
	if err := WriteLaunchAgent(filepath.Join(t.TempDir(), "p.plist"), "llmpilot", t.TempDir()); err == nil {
		t.Fatal("relative binary path accepted")
	}
}

// The sandbox env pinning is gated on LLMPILOT_TEST: test runs embed the
// redirections (a launchd daemon gets a clean env otherwise and would
// resolve the real home), production plists carry no env block at all.
func TestWriteLaunchAgentPinsSandboxEnvOnlyUnderTest(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.plist")

	t.Setenv("LLMPILOT_TEST", "1")
	t.Setenv("LLMPILOT_HOME", "/tmp/sandbox-home")
	if err := WriteLaunchAgent(path, "/usr/local/bin/llmpilot", dir); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "EnvironmentVariables") ||
		!strings.Contains(string(b), "/tmp/sandbox-home") {
		t.Fatalf("test-mode plist missing sandbox env pinning:\n%s", b)
	}
	if _, err := exec.LookPath("plutil"); err == nil {
		if out, err := exec.Command("plutil", "-lint", path).CombinedOutput(); err != nil {
			t.Fatalf("plutil -lint: %v\n%s", err, out)
		}
	}

	t.Setenv("LLMPILOT_TEST", "")
	if err := WriteLaunchAgent(path, "/usr/local/bin/llmpilot", dir); err != nil {
		t.Fatal(err)
	}
	b, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "EnvironmentVariables") {
		t.Fatalf("production plist must not embed environment:\n%s", b)
	}
}

// stubLaunchctl points the probe at a script that exits with the given code,
// so launchd's answers are covered without touching the real service database
// (a real register/bootstrap in a test would enroll a login item on the dev
// Mac — the same reason the app's LoginItems seam exists).
func stubLaunchctl(t *testing.T, exitCode int) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "launchctl")
	if err := os.WriteFile(p, []byte("#!/bin/sh\nexit "+strconv.Itoa(exitCode)+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := launchctlBin
	launchctlBin = p
	t.Cleanup(func() { launchctlBin = old })
}

// The app registers the agent through SMAppService, which writes no plist to
// ~/Library/LaunchAgents. Asking launchd is the only way to see that install,
// and "launchd would not tell us" must stay distinct from "not installed".
func TestLaunchAgentRegistered(t *testing.T) {
	t.Run("launchd knows the label", func(t *testing.T) {
		stubLaunchctl(t, 0)
		got, err := LaunchAgentRegistered()
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !got {
			t.Error("a registered label was reported as absent")
		}
	})
	t.Run("launchd denies the label", func(t *testing.T) {
		stubLaunchctl(t, launchdNoSuchService)
		got, err := LaunchAgentRegistered()
		if err != nil {
			t.Fatalf("exit %d is a definite answer, not an error: %v", launchdNoSuchService, err)
		}
		if got {
			t.Error("an unknown label was reported as registered")
		}
	})
	t.Run("any other exit is unknown, never a confident absent", func(t *testing.T) {
		stubLaunchctl(t, 2)
		got, err := LaunchAgentRegistered()
		if err == nil {
			t.Error("an unrecognised launchctl failure must be an error so the caller reports NOT CHECKED")
		}
		if got {
			t.Error("a failed probe must not report the agent as registered")
		}
	})
}
