package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
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
	if out, err := exec.Command("plutil", "-lint", path).CombinedOutput(); err != nil {
		t.Fatalf("plutil -lint: %v\n%s", err, out)
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
