package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/statusline"
)

func settingsDir(t *testing.T, content string) claudecfg.Dir {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if content != "" {
		if err := os.WriteFile(filepath.Join(path, "settings.json"), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return claudecfg.DirAt(path)
}

func readSettingsRaw(t *testing.T, dir claudecfg.Dir) map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(dir.SettingsPath())
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func TestInstallFreshWritesAndPreservesOtherKeys(t *testing.T) {
	dir := settingsDir(t, `{"model": "opus", "hooks": {"Stop": []}}`)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/usr/local/bin/llmpilot", InstallRefuse, &out); err != nil {
		t.Fatal(err)
	}
	doc := readSettingsRaw(t, dir)
	if got := claudecfg.StatusLineCommand(doc["statusLine"]); got != "/usr/local/bin/llmpilot statusline" {
		t.Errorf("installed command = %q", got)
	}
	if string(doc["model"]) != `"opus"` {
		t.Errorf("unrelated key mangled: %s", doc["model"])
	}
	if _, ok := doc["hooks"]; !ok {
		t.Error("hooks key lost")
	}
	if !strings.Contains(out.String(), "uninstall") {
		t.Errorf("install must print the removal path: %s", out.String())
	}
}

func TestInstallSeedsDevPresetWhenAbsentAndNeverClobbers(t *testing.T) {
	dir := settingsDir(t, "")
	home := t.TempDir()
	var out bytes.Buffer

	// Fresh install with no statusline.json → the promoted dev preset lands.
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallRefuse, &out); err != nil {
		t.Fatal(err)
	}
	cfg, err := statusline.LoadConfig(home)
	if err != nil {
		t.Fatal(err)
	}
	want := statusline.PresetByID("dev").Config
	if cfg.Preset != "dev" {
		t.Fatalf("install did not seed the dev preset: preset=%q", cfg.Preset)
	}
	if len(cfg.Segments) != len(want.Segments) {
		t.Fatalf("seeded segments = %d, want dev preset %d", len(cfg.Segments), len(want.Segments))
	}
	for i := range want.Segments {
		if cfg.Segments[i].ID != want.Segments[i].ID {
			t.Fatalf("seeded segment %d = %q, want %q", i, cfg.Segments[i].ID, want.Segments[i].ID)
		}
	}

	// A user's existing config is never clobbered on re-install.
	custom := statusline.Config{
		Version: statusline.ConfigVersion, Preset: "runway",
		Segments: []statusline.SegmentConfig{{ID: "account"}},
	}
	if err := statusline.SaveConfig(home, custom); err != nil {
		t.Fatal(err)
	}
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallRefuse, &out); err != nil {
		t.Fatal(err)
	}
	after, err := statusline.LoadConfig(home)
	if err != nil {
		t.Fatal(err)
	}
	if len(after.Segments) != 1 || after.Segments[0].ID != "account" {
		t.Fatalf("re-install clobbered the user's config: %+v", after.Segments)
	}
}

func TestInstallForeignKeepsWithoutReplace(t *testing.T) {
	foreign := `{"statusLine": {"type": "command", "command": "npx ccstatusline"}}`
	dir := settingsDir(t, foreign)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallRefuse, &out); err != nil {
		t.Fatal(err)
	}
	doc := readSettingsRaw(t, dir)
	if got := claudecfg.StatusLineCommand(doc["statusLine"]); got != "npx ccstatusline" {
		t.Errorf("foreign statusline clobbered without --replace: %q", got)
	}
	if !strings.Contains(out.String(), "npx ccstatusline") || !strings.Contains(out.String(), "--replace") {
		t.Errorf("must say whose line it is and how to replace: %s", out.String())
	}
}

func TestInstallReplaceBacksUpAndUninstallRestores(t *testing.T) {
	foreign := `{"statusLine": {"type": "command", "command": "npx ccstatusline"}, "theme": "dark"}`
	dir := settingsDir(t, foreign)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallReplace, &out); err != nil {
		t.Fatal(err)
	}
	if got := claudecfg.StatusLineCommand(readSettingsRaw(t, dir)["statusLine"]); got != "/bin/llmpilot statusline" {
		t.Errorf("replace did not install: %q", got)
	}
	orig, err := os.ReadFile(dir.SettingsBackupPath())
	if err != nil || string(orig) != foreign {
		t.Errorf(".orig backup wrong: %s (%v)", orig, err)
	}

	// The user changes an unrelated setting AFTER install; uninstall must
	// splice the old statusline back without clobbering that change.
	doc := readSettingsRaw(t, dir)
	doc["theme"] = json.RawMessage(`"light"`)
	data, _ := json.MarshalIndent(doc, "", "  ")
	if err := os.WriteFile(dir.SettingsPath(), data, 0o600); err != nil {
		t.Fatal(err)
	}

	out.Reset()
	if err := UninstallStatusline(dir, home, &out); err != nil {
		t.Fatal(err)
	}
	after := readSettingsRaw(t, dir)
	if got := claudecfg.StatusLineCommand(after["statusLine"]); got != "npx ccstatusline" {
		t.Errorf("uninstall did not restore the replaced line: %q", got)
	}
	if string(after["theme"]) != `"light"` {
		t.Errorf("uninstall clobbered a post-install settings change: %s", after["theme"])
	}
}

func TestUninstallPlainRemovalAndForeignNoop(t *testing.T) {
	dir := settingsDir(t, `{"statusLine": {"type": "command", "command": "/bin/llmpilot statusline"}}`)
	home := t.TempDir()
	var out bytes.Buffer
	if err := UninstallStatusline(dir, home, &out); err != nil {
		t.Fatal(err)
	}
	if raw := readSettingsRaw(t, dir)["statusLine"]; raw != nil {
		t.Errorf("statusLine not removed: %s", raw)
	}

	foreignDir := settingsDir(t, `{"statusLine": {"type": "command", "command": "someone-elses"}}`)
	out.Reset()
	if err := UninstallStatusline(foreignDir, home, &out); err != nil {
		t.Fatal(err)
	}
	if got := claudecfg.StatusLineCommand(readSettingsRaw(t, foreignDir)["statusLine"]); got != "someone-elses" {
		t.Errorf("uninstall touched a foreign statusline: %q", got)
	}
	if !strings.Contains(out.String(), "not ours") {
		t.Errorf("foreign uninstall must say why it kept it: %s", out.String())
	}
}

func TestInstallCorruptSettingsRefusesLoudly(t *testing.T) {
	dir := settingsDir(t, `{broken json`)
	var out bytes.Buffer
	err := InstallStatusline(dir, t.TempDir(), "/bin/llmpilot", InstallRefuse, &out)
	if err == nil {
		t.Fatal("corrupt settings.json must refuse, never guess-and-rewrite")
	}
	data, _ := os.ReadFile(dir.SettingsPath())
	if string(data) != `{broken json` {
		t.Error("corrupt settings.json was modified")
	}
}

func TestClassifyStatusLine(t *testing.T) {
	cases := []struct {
		raw  string
		kind StatusLineKind
	}{
		{"", StatusLineNone},
		{`{"type":"command","command":"~/go/bin/llmpilot statusline"}`, StatusLineOurs},
		{`{"type":"command","command":"npx ccstatusline"}`, StatusLineForeign},
		{`{"type":"static","text":"hi"}`, StatusLineForeign},
		// a FOREIGN script under a path that merely contains "llmpilot"
		// must never read as ours (classification bug caught live 2026-07-11)
		{`{"type":"command","command":"/tmp/x-llmpilot/their-statusline.sh"}`, StatusLineForeign},
		// a foreign tool NAMED like us must not be claimed (Greptile r2 P1)
		{`{"type":"command","command":"/usr/local/bin/llmpilot-monitor statusline"}`, StatusLineForeign},
		// our binary at a spaced path is written quoted — still ours
		{`{"type":"command","command":"\"/Applications/llm tools/llmpilot\" statusline"}`, StatusLineOurs},
		{`null`, StatusLineNone},
	}
	for _, c := range cases {
		var raw json.RawMessage
		if c.raw != "" {
			raw = json.RawMessage(c.raw)
		}
		if kind, _ := ClassifyStatusLine(raw); kind != c.kind {
			t.Errorf("classify(%s) = %v, want %v", c.raw, kind, c.kind)
		}
	}
}

func TestInstallKeepCoexistsAndUninstallRevertsFully(t *testing.T) {
	foreign := `{"statusLine": {"type": "command", "command": "npx ccstatusline"}}`
	dir := settingsDir(t, foreign)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallKeep, &out); err != nil {
		t.Fatal(err)
	}
	// settings.json now points at us…
	if got := claudecfg.StatusLineCommand(readSettingsRaw(t, dir)["statusLine"]); got != "/bin/llmpilot statusline" {
		t.Errorf("keep install did not take over settings.json: %q", got)
	}
	// …and statusline.json carries their command as the kept line.
	cfg, err := statusline.LoadConfig(home)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Keep == nil || cfg.Keep.Command != "npx ccstatusline" {
		t.Errorf("keep not recorded in statusline.json: %+v", cfg.Keep)
	}
	if !strings.Contains(out.String(), "above the llmpilot line") {
		t.Errorf("keep install must explain the coexist layout: %s", out.String())
	}

	out.Reset()
	if err := UninstallStatusline(dir, home, &out); err != nil {
		t.Fatal(err)
	}
	if got := claudecfg.StatusLineCommand(readSettingsRaw(t, dir)["statusLine"]); got != "npx ccstatusline" {
		t.Errorf("uninstall did not restore the kept line to settings.json: %q", got)
	}
	after, err := statusline.LoadConfig(home)
	if err != nil {
		t.Fatal(err)
	}
	if after.Keep != nil {
		t.Errorf("uninstall left a stale keep in statusline.json: %+v", after.Keep)
	}
}

func TestInstallKeepWithNothingToKeepInstallsNormally(t *testing.T) {
	dir := settingsDir(t, `{}`)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallKeep, &out); err != nil {
		t.Fatal(err)
	}
	if got := claudecfg.StatusLineCommand(readSettingsRaw(t, dir)["statusLine"]); got != "/bin/llmpilot statusline" {
		t.Errorf("install missing: %q", got)
	}
	cfg, _ := statusline.LoadConfig(home)
	if cfg.Keep != nil {
		t.Errorf("nothing existed to keep, yet keep was recorded: %+v", cfg.Keep)
	}
	if !strings.Contains(out.String(), "no existing statusline to keep") {
		t.Errorf("must say there was nothing to keep: %s", out.String())
	}
}

func TestInstallKeepRefusesNonCommandStatusline(t *testing.T) {
	dir := settingsDir(t, `{"statusLine": {"type": "static", "text": "hi"}}`)
	home := t.TempDir()
	var out bytes.Buffer
	if err := InstallStatusline(dir, home, "/bin/llmpilot", InstallKeep, &out); err != nil {
		t.Fatal(err)
	}
	// nothing runnable to keep: settings.json untouched, no keep recorded
	if got := string(readSettingsRaw(t, dir)["statusLine"]); !strings.Contains(got, "static") {
		t.Errorf("non-command statusline was touched: %s", got)
	}
	if cfg, _ := statusline.LoadConfig(home); cfg.Keep != nil {
		t.Errorf("unrunnable statusline recorded as keep: %+v", cfg.Keep)
	}
	if !strings.Contains(out.String(), "nothing runnable to keep") {
		t.Errorf("must explain why keep refused: %s", out.String())
	}
}
