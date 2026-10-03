package claudecfg

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWriteStatusLineKeepsASymlinkedSettingsFile: a settings.json kept as a
// link into a dotfiles repo stays a link after a statusline write, and the
// new value lands in the file it points at.
func TestWriteStatusLineKeepsASymlinkedSettingsFile(t *testing.T) {
	dotfiles := t.TempDir()
	target := filepath.Join(dotfiles, "claude-settings.json")
	if err := os.WriteFile(target, []byte(`{"theme":"dark"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfgDir := t.TempDir()
	if err := os.Symlink(target, filepath.Join(cfgDir, "settings.json")); err != nil {
		t.Fatal(err)
	}
	d := DirAt(cfgDir)

	if _, err := d.WriteStatusLine(json.RawMessage(`{"type":"command","command":"llmpilot statusline"}`)); err != nil {
		t.Fatal(err)
	}

	fi, err := os.Lstat(d.SettingsPath())
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("settings.json was replaced by a plain file (mode %v)", fi.Mode())
	}
	raw, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if doc["statusLine"] == nil || string(doc["theme"]) != `"dark"` {
		t.Fatalf("link target not updated in place: %s", raw)
	}
}

// TestWriteStatusLineThroughAReadOnlyLinkNamesTheTarget: a link into a
// folder llmpilot cannot write (a read-only, generated config) fails with an
// error naming where the line has to go, and the link is left alone.
func TestWriteStatusLineThroughAReadOnlyLinkNamesTheTarget(t *testing.T) {
	store := t.TempDir()
	target := filepath.Join(store, "settings.json")
	if err := os.WriteFile(target, []byte(`{}`), 0o444); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(store, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(store, 0o755) })
	cfgDir := t.TempDir()
	if err := os.Symlink(target, filepath.Join(cfgDir, "settings.json")); err != nil {
		t.Fatal(err)
	}
	d := DirAt(cfgDir)

	_, err := d.WriteStatusLine(json.RawMessage(`{"type":"command","command":"llmpilot statusline"}`))
	if err == nil || !strings.Contains(err.Error(), target) {
		t.Fatalf("err = %v, want one naming %s", err, target)
	}
	if fi, lerr := os.Lstat(d.SettingsPath()); lerr != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("the link was replaced (%v)", lerr)
	}
}
