package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

// Statusline install/uninstall for Claude Code's settings.json. The one
// rule: a FOREIGN statusline is never clobbered silently — say whose it is,
// offer replace-with-backup and a one-command revert; "keep yours" is a
// first-class outcome.

// StatusLineKind classifies what currently lives in settings.json.
type StatusLineKind int

const (
	StatusLineNone StatusLineKind = iota
	StatusLineOurs
	StatusLineForeign
)

// ClassifyStatusLine inspects the actual stored command string — never a
// flag that could go stale (teardown: isInstalled pattern).
func ClassifyStatusLine(raw json.RawMessage) (StatusLineKind, string) {
	cmd := claudecfg.StatusLineCommand(raw)
	if raw == nil || string(bytes.TrimSpace(raw)) == "null" {
		return StatusLineNone, ""
	}
	if cmd == "" {
		// a statusLine value we can't read as a command is still someone's
		return StatusLineForeign, string(raw)
	}
	if isOurCommand(cmd) {
		return StatusLineOurs, cmd
	}
	return StatusLineForeign, cmd
}

// isOurCommand recognizes an install we wrote: `<binary> statusline` where
// the binary's basename IS "llmpilot" — exactly. A substring test misfires
// in both directions: a foreign script under a path containing "llmpilot"
// (verifier 7a, hit live) and a foreign tool NAMED like us, e.g.
// "llmpilot-monitor statusline" (Greptile P1 round 2, 2026-07-11) — either
// would be rewritten and its command lost. A renamed llmpilot binary reads
// as foreign, which fails safe: install/uninstall refuse rather than touch it.
func isOurCommand(cmd string) bool {
	bin, ok := strings.CutSuffix(strings.TrimSpace(cmd), " statusline")
	if !ok {
		return false
	}
	bin = strings.Trim(strings.TrimSpace(bin), `"`)
	return filepath.Base(bin) == "llmpilot"
}

// replacedPath is where the pre-install statusLine VALUE is kept so
// uninstall can splice it back without clobbering settings the user changed
// since (a full-file .orig restore would).
func replacedPath(home string) string {
	return filepath.Join(home, "statusline-replaced.json")
}

type replacedDoc struct {
	SettingsPath string          `json:"settings_path"`
	StatusLine   json.RawMessage `json:"statusLine"`
}

// InstallMode is what install does when settings.json already carries a
// FOREIGN statusline. Refuse (default) leaves it alone and says how to
// proceed; Keep coexists (their line renders above ours); Replace swaps it.
// All paths back up, and `llmpilot statusline uninstall` reverts.
type InstallMode int

const (
	InstallRefuse InstallMode = iota
	InstallKeep
	InstallReplace
)

// takeOver backs up settings.json, records the current statusLine value,
// and only THEN points statusLine at us — the restore record lands before
// anything changes, so a failure between the two steps can never leave a
// replaced line with nothing to splice back (Greptile P1 round 2,
// 2026-07-11). A failure after the record is harmless the other way:
// settings are unchanged and the record just describes the status quo.
func takeOver(dir claudecfg.Dir, home string, value, prev json.RawMessage, out io.Writer) error {
	backedUp, err := dir.BackupSettingsOnce()
	if err != nil {
		return err
	}
	if err := store.WriteJSONAtomic(replacedPath(home), replacedDoc{
		SettingsPath: dir.SettingsPath(), StatusLine: prev,
	}); err != nil {
		return err
	}
	if _, err := dir.WriteStatusLine(value); err != nil {
		return err
	}
	if backedUp {
		fmt.Fprintf(out, "backed up %s → %s\n", dir.SettingsPath(), dir.SettingsBackupPath())
	}
	return nil
}

// InstallStatusline wires `<binary> statusline` into settings.json.
// A foreign line is never clobbered silently — see InstallMode.
func InstallStatusline(dir claudecfg.Dir, home, binPath string, mode InstallMode, out io.Writer) error {
	raw, err := dir.StatusLine()
	if err != nil {
		return err
	}
	value, command, err := claudecfg.CommandStatusLine(binPath)
	if err != nil {
		return err
	}
	// First-run pick (owner 2026-07-11): seed the promoted DEV preset so a new
	// user gets the rich line, not the bare classic default. Only when no
	// statusline.json exists — an existing config is never clobbered, and the
	// no-file bare output stays byte-exact.
	if err := seedDevPreset(home); err != nil {
		return err
	}

	kind, existing := ClassifyStatusLine(raw)
	switch kind {
	case StatusLineOurs:
		if existing == command {
			fmt.Fprintln(out, "already installed — nothing to do")
			return nil
		}
		if _, err := dir.WriteStatusLine(value); err != nil {
			return err
		}
		fmt.Fprintf(out, "updated our statusline command in %s\n", dir.SettingsPath())
		return nil
	case StatusLineForeign:
		switch mode {
		case InstallKeep:
			if claudecfg.StatusLineCommand(raw) == "" {
				fmt.Fprintf(out, "the existing statusline is not a command (%s) — nothing runnable to keep.\n"+
					"  replace it instead: llmpilot statusline install --replace\n", existing)
				return nil
			}
			cfg, _ := statusline.LoadConfig(home) // corrupt file → defaults; keep still lands
			cfg.Keep = &statusline.KeepConfig{Command: existing}
			if err := statusline.SaveConfig(home, cfg); err != nil {
				return fmt.Errorf("can't keep this command in statusline.json: %w", err)
			}
			if err := takeOver(dir, home, value, raw, out); err != nil {
				return err
			}
			fmt.Fprintf(out, "kept your statusline — it renders above the llmpilot line:\n  %s\n"+
				"  revert fully: llmpilot statusline uninstall\n", existing)
			return nil
		case InstallReplace:
			if err := takeOver(dir, home, value, raw, out); err != nil {
				return err
			}
			fmt.Fprintf(out, "replaced the existing statusline (%s)\n"+
				"  revert any time: llmpilot statusline uninstall\n", existing)
			fmt.Fprintf(out, "installed: %s\n", command)
			return nil
		default:
			fmt.Fprintf(out, "settings.json already has a statusline — keeping it.\n  current: %s\n"+
				"  run it above the llmpilot line:  llmpilot statusline install --keep\n"+
				"  or replace it (backup + revert): llmpilot statusline install --replace\n", existing)
			return nil
		}
	default:
		if _, err := dir.BackupSettingsOnce(); err != nil {
			return err
		}
		if _, err := dir.WriteStatusLine(value); err != nil {
			return err
		}
		if mode == InstallKeep {
			fmt.Fprintln(out, "no existing statusline to keep — installed the llmpilot line")
		}
		fmt.Fprintf(out, "installed into %s:\n  \"statusLine\": {\"type\": \"command\", \"command\": %q}\n"+
			"  remove any time: llmpilot statusline uninstall\n", dir.SettingsPath(), command)
		return nil
	}
}

// seedDevPreset writes the promoted "dev" preset to statusline.json when none
// exists yet. An existing config (any user customization) is left untouched, and
// the no-file bare render is never affected — only a fresh install seeds it.
func seedDevPreset(home string) error {
	if _, err := os.Stat(statusline.ConfigPath(home)); err == nil {
		return nil // config exists — never clobber it
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dev := statusline.PresetByID("dev")
	if dev == nil {
		return nil
	}
	return statusline.SaveConfig(home, dev.Config)
}

// UninstallStatusline removes our line. If install replaced a foreign one,
// that exact value is spliced back.
func UninstallStatusline(dir claudecfg.Dir, home string, out io.Writer) error {
	raw, err := dir.StatusLine()
	if err != nil {
		return err
	}
	kind, existing := ClassifyStatusLine(raw)
	switch kind {
	case StatusLineNone:
		fmt.Fprintln(out, "no statusline installed — nothing to do")
		return nil
	case StatusLineForeign:
		fmt.Fprintf(out, "the current statusline is not ours — leaving it alone.\n  current: %s\n", existing)
		return nil
	}

	var restore json.RawMessage // nil = plain removal
	var doc replacedDoc
	data, err := os.ReadFile(replacedPath(home))
	switch {
	case err == nil:
		if jsonErr := json.Unmarshal(data, &doc); jsonErr == nil && doc.SettingsPath == dir.SettingsPath() {
			restore = doc.StatusLine
		}
	case !errors.Is(err, os.ErrNotExist):
		return err
	}

	if _, err := dir.WriteStatusLine(restore); err != nil {
		return err
	}
	_ = os.Remove(replacedPath(home))
	// A coexist install recorded the restored command as keep.command; with
	// the original statusline back in charge, a stale keep would double-render
	// it on any future install — clear it.
	if restore != nil {
		if cfg, err := statusline.LoadConfig(home); err == nil && cfg.Keep != nil &&
			cfg.Keep.Command == claudecfg.StatusLineCommand(restore) {
			cfg.Keep = nil
			if err := statusline.SaveConfig(home, cfg); err != nil {
				fmt.Fprintf(out, "note: couldn't clear keep from statusline.json: %v\n", err)
			}
		}
		fmt.Fprintf(out, "removed our statusline and restored the previous one:\n  %s\n",
			claudecfg.StatusLineCommand(restore))
		return nil
	}
	fmt.Fprintf(out, "removed our statusline from %s\n", dir.SettingsPath())
	if _, err := os.Stat(dir.SettingsBackupPath()); err == nil {
		// The record of what install replaced is gone, so nothing was spliced
		// back — but the pre-llmpilot file still exists. Say so.
		fmt.Fprintf(out, "your pre-llmpilot settings are still at %s if anything is missing\n",
			dir.SettingsBackupPath())
	}
	return nil
}
