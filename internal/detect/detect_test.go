package detect

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

func writeOAuth(t *testing.T, path, email string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	doc := map[string]any{"oauthAccount": map[string]any{"emailAddress": email}}
	data, _ := json.Marshal(doc)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDirsFindsDefaultAndSiblings(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")

	// default layout: dir ~/.claude, config file is the SIBLING ~/.claude.json
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeOAuth(t, filepath.Join(home, ".claude.json"), "main@example.dev")
	// custom dir: config file lives INSIDE the dir
	writeOAuth(t, filepath.Join(home, ".claude-alt", ".claude.json"), "alt@example.dev")
	// never logged in: present but no oauthAccount
	if err := os.MkdirAll(filepath.Join(home, ".claude-empty"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".claude-empty", ".claude.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	// a stray FILE matching the glob must not blow up detection
	if err := os.WriteFile(filepath.Join(home, ".claude-notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := Dirs()
	if err != nil {
		t.Fatal(err)
	}
	emails := map[string]string{}
	for _, d := range got {
		emails[d.Account.EmailAddress] = d.Dir.Path()
	}
	if len(got) != 2 {
		t.Fatalf("detected %d dirs (%v), want 2", len(got), emails)
	}
	if emails["main@example.dev"] != filepath.Join(home, ".claude") {
		t.Errorf("default dir not detected: %v", emails)
	}
	if emails["alt@example.dev"] != filepath.Join(home, ".claude-alt") {
		t.Errorf("alt dir not detected: %v", emails)
	}
}

func TestDirsHonorsClaudeConfigDir(t *testing.T) {
	home := t.TempDir()
	other := filepath.Join(t.TempDir(), "pinned")
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", other)
	writeOAuth(t, filepath.Join(other, ".claude.json"), "pin@example.dev")

	got, err := Dirs()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].Account.EmailAddress != "pin@example.dev" {
		t.Fatalf("detected = %+v, want the pinned dir only", got)
	}
}

func TestSuggestLabel(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeOAuth(t, filepath.Join(home, ".claude-alt", ".claude.json"), "alt@example.dev")
	writeOAuth(t, filepath.Join(home, ".claude.json"), "main@example.dev")
	if err := os.MkdirAll(filepath.Join(home, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", "")

	dirs, err := Dirs()
	if err != nil || len(dirs) != 2 {
		t.Fatalf("detect: %v %+v", err, dirs)
	}
	byEmail := map[string]Detected{}
	for _, d := range dirs {
		byEmail[d.Account.EmailAddress] = d
	}

	// an already-registered label always wins — init never renames
	existing := []store.Account{{ID: "acct-x", Label: "keepcove", Email: "main@example.dev"}}
	if got := SuggestLabel(byEmail["main@example.dev"], existing); got != "keepcove" {
		t.Errorf("existing label: got %q, want keepcove", got)
	}
	// custom dirs suggest their suffix
	if got := SuggestLabel(byEmail["alt@example.dev"], nil); got != "alt" {
		t.Errorf("suffix label: got %q, want alt", got)
	}
	// default dir with no registration: empty → registration defaults to email local part
	if got := SuggestLabel(byEmail["main@example.dev"], nil); got != "" {
		t.Errorf("default-dir label: got %q, want \"\"", got)
	}
}
