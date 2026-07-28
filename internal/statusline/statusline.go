// Package statusline is the segments engine behind `llmpilot statusline`:
// a registry of renderable segments, display tiers (plain/16/256/truecolor),
// width-aware collapse, and the statusline.json config that drives both the
// binary and the cockpit editor. The daemon's GET /v1/statusline/preview runs
// this exact renderer — preview==production is the trust property.
//
// The zero-config default renders the classic line byte-for-byte; a config
// file only ever adds.
package statusline

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/alicicek/llmpilot/internal/store"
)

// ConfigVersion is the current statusline.json schema version. Older or
// unversioned files migrate through an allowlist copy — never a blind spread
// (teardown: migrations.ts pattern).
const ConfigVersion = 1

// Config is $LLMPILOT_HOME/statusline.json. Absence means Default().
type Config struct {
	Version   int             `json:"version"`
	Preset    string          `json:"preset,omitempty"`
	Separator string          `json:"separator,omitempty"` // between segments; default " "
	Flex      string          `json:"flex,omitempty"`      // full | full-minus-40 (default) | off
	Color     string          `json:"color,omitempty"`     // auto (default) | off | 16 | 256 | truecolor
	Keep      *KeepConfig     `json:"keep,omitempty"`
	Segments  []SegmentConfig `json:"segments"`
}

// KeepConfig is the coexist mode: a pre-existing
// statusline command the user chose to KEEP — the binary runs it with the
// same stdin Claude Code sends us and prints its output ABOVE the llmpilot
// line (Claude Code renders multi-line statuslines). Set by
// `llmpilot statusline install --keep`; ecosystem precedent: ccstatusline's
// custom-command widget wrapping ccusage.
type KeepConfig struct {
	Command string `json:"command"`
}

// validKeepCommand bounds what a kept command may look like — a shell
// command line, no control bytes, sane length.
func validKeepCommand(cmd string) bool {
	return cmd != "" && len(cmd) <= 500 && !hasControl(cmd)
}

// SegmentConfig is one enabled segment instance, in render order.
type SegmentConfig struct {
	ID      string         `json:"id"`
	Options map[string]any `json:"options,omitempty"`
}

// ConfigPath is where the config lives under one llmpilot home.
func ConfigPath(home string) string { return filepath.Join(home, "statusline.json") }

// Default is the zero-config line: the classic statusline exactly. Flex is
// OFF here by construction — the classic line never collapsed, so the
// anchor "zero-config == classic line byte-exact" must hold at EVERY
// terminal width (verifier P1, 2026-07-11: full-minus-40 was silently
// dropping the account head at COLUMNS=80). Width-aware collapse stays
// opt-in for customized lines.
func Default() Config {
	return Config{
		Version:  ConfigVersion,
		Preset:   "runway",
		Flex:     FlexOff,
		Segments: []SegmentConfig{{ID: "account"}, {ID: "usage"}},
	}
}

// separator returns the configured separator, defaulted.
func (c Config) separator() string {
	if c.Separator == "" {
		return " "
	}
	return c.Separator
}

// LoadConfig reads statusline.json. It NEVER writes: a missing file is
// Default(); an unreadable or invalid file is Default() plus the error, disk
// untouched (never-clobber-on-error, teardown config.ts pattern). A readable
// file is migrated in memory through the allowlist and always usable.
func LoadConfig(home string) (Config, error) {
	data, err := os.ReadFile(ConfigPath(home))
	if errors.Is(err, os.ErrNotExist) {
		return Default(), nil
	}
	if err != nil {
		return Default(), err
	}
	var raw Config
	if err := json.Unmarshal(data, &raw); err != nil {
		return Default(), fmt.Errorf("parse %s: %w", ConfigPath(home), err)
	}
	return Migrate(raw), nil
}

// Migrate normalizes any config version to the current schema by copying
// ONLY allowlisted fields with valid values: known segment IDs, known option
// keys of the right type, known flex/color values. Junk is dropped, never
// round-tripped. It handles unversioned (pre-1) files and is lenient with
// newer-versioned files (known fields still render; nothing is saved back).
func Migrate(raw Config) Config {
	out := Config{Version: ConfigVersion, Preset: raw.Preset}
	if raw.Separator != "" && len(raw.Separator) <= 8 && !hasControl(raw.Separator) {
		out.Separator = raw.Separator
	}
	switch raw.Flex {
	case FlexFull, FlexFullMinus40, FlexOff:
		out.Flex = raw.Flex
	}
	switch raw.Color {
	case "auto", "off", "16", "256", "truecolor":
		out.Color = raw.Color
	}
	if raw.Keep != nil && validKeepCommand(raw.Keep.Command) {
		out.Keep = &KeepConfig{Command: raw.Keep.Command}
	}
	for _, sc := range raw.Segments {
		seg, ok := registry[sc.ID]
		if !ok {
			continue
		}
		clean := SegmentConfig{ID: sc.ID}
		for _, spec := range seg.Options {
			v, present := sc.Options[spec.Key]
			if !present || !spec.valid(v) {
				continue
			}
			if clean.Options == nil {
				clean.Options = map[string]any{}
			}
			clean.Options[spec.Key] = v
		}
		out.Segments = append(out.Segments, clean)
	}
	if len(out.Segments) == 0 {
		out.Segments = Default().Segments
		if out.Preset == "" {
			out.Preset = "runway"
		}
	}
	return out
}

// Validate is the STRICT check for configs arriving over the API or CLI —
// loading stays lenient, saving refuses junk so the file on disk is always
// exactly what the user chose.
func Validate(c Config) error {
	if c.Version != 0 && c.Version != ConfigVersion {
		return fmt.Errorf("unsupported config version %d (current %d)", c.Version, ConfigVersion)
	}
	if len(c.Segments) == 0 {
		return errors.New("at least one segment is required")
	}
	if len(c.Separator) > 8 {
		return fmt.Errorf("separator too long (%d chars, max 8)", len(c.Separator))
	}
	if hasControl(c.Separator) {
		return errors.New("separator must not contain control characters")
	}
	if c.Keep != nil && !validKeepCommand(c.Keep.Command) {
		return errors.New("keep.command must be a non-empty command line (≤500 chars, no control characters)")
	}
	switch c.Flex {
	case "", FlexFull, FlexFullMinus40, FlexOff:
	default:
		return fmt.Errorf("unknown flex mode %q", c.Flex)
	}
	switch c.Color {
	case "", "auto", "off", "16", "256", "truecolor":
	default:
		return fmt.Errorf("unknown color setting %q", c.Color)
	}
	for _, sc := range c.Segments {
		seg, ok := registry[sc.ID]
		if !ok {
			return fmt.Errorf("unknown segment %q", sc.ID)
		}
		for key, v := range sc.Options {
			spec := seg.option(key)
			if spec == nil {
				return fmt.Errorf("segment %q has no option %q", sc.ID, key)
			}
			if !spec.valid(v) {
				return fmt.Errorf("segment %q option %q: invalid value %v", sc.ID, key, v)
			}
		}
	}
	return nil
}

// SaveConfig validates and writes statusline.json atomically.
func SaveConfig(home string, c Config) error {
	if err := Validate(c); err != nil {
		return err
	}
	c.Version = ConfigVersion
	return store.WriteJSONAtomic(ConfigPath(home), c)
}

// hasControl reports whether a string carries control bytes (raw ESC,
// newlines, NUL…) — none may reach the one-line statusline contract, whether
// from a hand-edited config or the API.
func hasControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}

// Preset is one named starting configuration, rendered as a candidate card
// in the cockpit editor.
type Preset struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Desc   string `json:"desc"`
	Config Config `json:"config"`
}

// Built-in presets; `dev` is the promoted default, `runway` is the
// zero-config layout. "runway" ships as the zero-config default — that is
// anchor-pinned to the classic line, independent of the choice.
func Presets() []Preset {
	return []Preset{
		{
			ID: "runway", Name: "Runway", Desc: "account head + usage buckets — the classic line",
			Config: Default(),
		},
		{
			ID: "pilot", Name: "Pilot", Desc: "runway plus the daemon-backed fleet: burn wall, next rotation, autopilot state",
			Config: Config{Version: ConfigVersion, Preset: "pilot", Segments: []SegmentConfig{
				{ID: "account"}, {ID: "usage"}, {ID: "burn"}, {ID: "rotation"}, {ID: "autopilot"},
			}},
		},
		{
			ID: "dev", Name: "Dev", Desc: "dir (branch) · model · context · cost, with the usage runway",
			Config: Config{Version: ConfigVersion, Preset: "dev", Segments: []SegmentConfig{
				{ID: "dir"}, {ID: "model"}, {ID: "context"}, {ID: "cost"}, {ID: "usage"},
			}},
		},
	}
}

// PresetByID returns the named preset, nil if unknown.
func PresetByID(id string) *Preset {
	for _, p := range Presets() {
		if p.ID == id {
			return &p
		}
	}
	return nil
}
