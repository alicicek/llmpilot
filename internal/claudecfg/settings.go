package claudecfg

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// settings.json is a Claude Code surface — every byte of knowledge about its
// layout stays in this adapter. llmpilot touches EXACTLY one key
// ("statusLine") and preserves everything else verbatim.

// SettingsPath is <dir>/settings.json (inside the config dir for default and
// custom dirs alike).
func (d Dir) SettingsPath() string { return filepath.Join(d.path, "settings.json") }

// SettingsBackupPath is the .orig full-file backup made before the first
// llmpilot write (teardown: installStatusLine's pattern).
func (d Dir) SettingsBackupPath() string { return d.SettingsPath() + ".orig" }

// readSettings parses settings.json into raw keys. Missing file = empty
// settings; a corrupt file is an error (never guess-and-rewrite user config).
func (d Dir) readSettings() (map[string]json.RawMessage, error) {
	data, err := os.ReadFile(d.SettingsPath())
	if errors.Is(err, os.ErrNotExist) {
		return map[string]json.RawMessage{}, nil
	}
	if err != nil {
		return nil, err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", d.SettingsPath(), err)
	}
	if doc == nil {
		doc = map[string]json.RawMessage{}
	}
	return doc, nil
}

// StatusLine returns the raw statusLine value (nil when unset).
func (d Dir) StatusLine() (json.RawMessage, error) {
	doc, err := d.readSettings()
	if err != nil {
		return nil, err
	}
	return doc["statusLine"], nil
}

// CommandStatusLine builds the statusLine value Claude Code expects for a
// command-type statusline — the ONE place its shape is written. Binary paths
// with spaces are quoted (the command runs in a shell).
func CommandStatusLine(binPath string) (value json.RawMessage, command string, err error) {
	quoted := binPath
	if strings.ContainsAny(binPath, " \t") {
		quoted = `"` + binPath + `"`
	}
	command = quoted + " statusline"
	value, err = json.Marshal(map[string]string{"type": "command", "command": command})
	return value, command, err
}

// StatusLineCommand extracts the command string from a raw statusLine value
// ("" when unset or not a command-type statusline).
func StatusLineCommand(raw json.RawMessage) string {
	if raw == nil {
		return ""
	}
	var v struct {
		Type    string `json:"type"`
		Command string `json:"command"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		return ""
	}
	return v.Command
}

// WriteStatusLine splices ONE key: value == nil deletes statusLine, anything
// else sets it. Every other setting's VALUE passes through verbatim
// (json.RawMessage), but the file is re-marshaled — top-level key order and
// indentation are normalized (the .orig backup keeps the original bytes).
// The write is atomic (tempfile+rename in the settings dir). Returns the
// previous raw value so callers can offer a revert.
func (d Dir) WriteStatusLine(value json.RawMessage) (prev json.RawMessage, err error) {
	doc, err := d.readSettings()
	if err != nil {
		return nil, err
	}
	prev = doc["statusLine"]
	if value == nil {
		delete(doc, "statusLine")
	} else {
		doc["statusLine"] = value
	}
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	dir := filepath.Dir(d.SettingsPath())
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	tmp, err := os.CreateTemp(dir, ".settings-*")
	if err != nil {
		return nil, err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		_ = tmp.Close()
		return nil, err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return nil, err
	}
	if err := tmp.Close(); err != nil {
		return nil, err
	}
	return prev, os.Rename(tmp.Name(), d.SettingsPath())
}

// BackupSettingsOnce copies settings.json to .orig if no backup exists yet —
// an older backup is the user's real "before llmpilot" state and is never
// overwritten. Reports whether a backup was made (false = one already
// existed or there is no settings.json to back up).
func (d Dir) BackupSettingsOnce() (bool, error) {
	if _, err := os.Stat(d.SettingsBackupPath()); err == nil {
		return false, nil
	}
	data, err := os.ReadFile(d.SettingsPath())
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, os.WriteFile(d.SettingsBackupPath(), data, 0o600)
}
