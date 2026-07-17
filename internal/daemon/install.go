package daemon

import (
	"encoding/xml"
	"fmt"
	"os"
	"path/filepath"
)

// LaunchAgentLabel is forever-ish once users have plists on disk —
// reverse-DNS from day one.
const LaunchAgentLabel = "dev.llmpilot.daemon"

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
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
</dict>
</plist>
`

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
		xmlEscape(filepath.Join(logDir, "daemon.err.log")))
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
