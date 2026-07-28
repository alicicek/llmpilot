package daemon

import (
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// LaunchAgentLabel is forever-ish once users have plists on disk —
// reverse-DNS from day one.
const LaunchAgentLabel = "dev.llmpilot.daemon"

// launchdNoSuchService is launchd's exit code for a label it does not know.
// Any OTHER non-zero exit means we could not determine the state, which is a
// different answer from "not installed" and must not be collapsed into it.
const launchdNoSuchService = 113

// launchctlBin is a seam: tests point it at a stub that mimics launchd's exit
// codes, so the probe is covered without touching the real service database.
var launchctlBin = "/bin/launchctl"

// LaunchAgentRegistered asks launchd whether the daemon's label exists in the
// caller's GUI domain.
//
// This is the ONLY way to see the modern install. The menu bar app registers
// the agent through SMAppService from the plist inside its own bundle, which
// writes NOTHING to ~/Library/LaunchAgents — so a file check alone reports
// every app-installed fleet as "no login item", and sends the user to a
// `daemon install` that is a no-op for an already-loaded agent.
//
// Returns (false, nil) only when launchd positively denies knowing the label.
// An unparseable failure returns an error so the caller can report NOT CHECKED
// rather than a confident, wrong "missing".
func LaunchAgentRegistered() (bool, error) {
	target := fmt.Sprintf("gui/%d/%s", os.Getuid(), LaunchAgentLabel)
	if err := exec.Command(launchctlBin, "print", target).Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if ee.ExitCode() == launchdNoSuchService {
				return false, nil
			}
			return false, fmt.Errorf("launchctl print %s exited %d", target, ee.ExitCode())
		}
		return false, err
	}
	return true, nil
}

const plistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + LaunchAgentLabel + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>daemon</string>
		<string>run</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>dev.llmpilot.menubar</string>
	</array>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>%s
</dict>
</plist>
`

// testEnvXML pins the sandbox redirections into the agent plist under
// LLMPILOT_TEST: launchd starts the daemon with a clean environment, so
// without this a launchd-bootstrapped daemon inside a test would resolve
// the REAL home and real keychain (the Protocol-10 hazard class).
// Production installs get no EnvironmentVariables block at all.
func testEnvXML() string {
	if os.Getenv("LLMPILOT_TEST") == "" {
		return ""
	}
	keys := []string{
		"LLMPILOT_TEST", "LLMPILOT_HOME", "HOME", "CLAUDE_CONFIG_DIR",
		"LLMPILOT_KEYCHAIN", "LLMPILOT_USAGE_URL", "LLMPILOT_DEBUG_LOG",
	}
	var b []byte
	b = append(b, "\n\t<key>EnvironmentVariables</key>\n\t<dict>"...)
	for _, k := range keys {
		v, ok := os.LookupEnv(k)
		if !ok {
			continue
		}
		b = append(b, fmt.Sprintf("\n\t\t<key>%s</key>\n\t\t<string>%s</string>",
			xmlEscape(k), xmlEscape(v))...)
	}
	b = append(b, "\n\t</dict>"...)
	return string(b)
}

// RestartCommand is what actually bounces a LOADED agent. `daemon install`
// writes the plist and stops; `launchctl bootstrap` fails on an agent that is
// already bootstrapped. kickstart -k kills the running copy and starts a fresh
// one from the plist on disk, which is the incantation that has fixed every
// stuck-daemon case this project has hit.
// The uid is RESOLVED here, never left as $UID: tcsh and fish do not define
// that variable (tcsh aborts the line; fish expands it to empty), and this
// string exists to be pasted into whatever shell the user has.
func RestartCommand() string {
	return fmt.Sprintf("launchctl kickstart -k gui/%d/%s", os.Getuid(), LaunchAgentLabel)
}

// LaunchAgentPath is where the plist lands for the current user.
func LaunchAgentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", LaunchAgentLabel+".plist"), nil
}

// WriteLaunchAgent renders the plist for the given llmpilot binary path and
// writes it at path (0644 — launchd requires the file be readable). logDir
// receives the daemon's stdout/stderr files.
func WriteLaunchAgent(path, binaryPath, logDir string) error {
	if !filepath.IsAbs(binaryPath) {
		return fmt.Errorf("launch agent needs an absolute binary path, got %q", binaryPath)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return err
	}
	content := fmt.Sprintf(plistTemplate,
		xmlEscape(binaryPath),
		xmlEscape(filepath.Join(logDir, "daemon.log")),
		xmlEscape(filepath.Join(logDir, "daemon.err.log")),
		testEnvXML())
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil { //nolint:gosec // launchd must read it
		return err
	}
	return os.Rename(tmp, path)
}

func xmlEscape(s string) string {
	var buf []byte
	b := &bufWriter{&buf}
	_ = xml.EscapeText(b, []byte(s))
	return string(buf)
}

type bufWriter struct{ b *[]byte }

func (w *bufWriter) Write(p []byte) (int, error) {
	*w.b = append(*w.b, p...)
	return len(p), nil
}
