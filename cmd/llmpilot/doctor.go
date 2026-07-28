package main

// `llmpilot doctor` — the read-only health sweep, report-only like
// `claude doctor`. It asks the daemon first (so the terminal prints exactly
// what the cockpit shows) and falls back to a local sweep when nothing
// answers, where every daemon-only check reports NOT CHECKED rather than
// passing.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/cli"
	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// doctorReaders is the ONE place the sweep is bound to real local reads —
// used by the daemon it constructs and by the CLI's degraded fallback. A
// second copy would drift, and then the terminal and the cockpit would
// disagree about whether the fleet is healthy.
//
// Every reader here LOOKS: llmpilot's own Keychain service, the config dirs'
// .claude.json files, the budget document, the launch agent and settings.json.
// None of them writes, locks, refreshes or dials.
func doctorReaders(st *store.Store, sw *switcher.Switcher) daemon.DoctorLocal {
	local := daemon.DoctorLocal{
		Install: installFacts,
		// Metadata only — the sweep never opens the token Keychain service.
		SetupTokens: (&setuptoken.Store{Home: st.Home()}).List,
	}
	if sw == nil {
		return local
	}
	local.Backups = sw.Keychain
	local.Foreign = sw.ForeignSignIns
	local.Budget = sw.BudgetSnapshot
	return local
}

// installFacts reads the install health. A fact it cannot read is reported as
// an error string, never as "fine" — the sweep turns that into NOT CHECKED.
func installFacts() (doctor.InstallFacts, error) {
	var f doctor.InstallFacts
	path, err := daemon.LaunchAgentPath()
	switch {
	case err != nil:
		f.LaunchAgentErr = fmt.Sprintf("llmpilot could not work out where the login item lives: %v", err)
	default:
		f.LaunchAgentPath = path
		_, err := os.Stat(path)
		switch {
		case err == nil:
			f.LaunchAgentInstalled = true
		case errors.Is(err, os.ErrNotExist):
			f.LaunchAgentInstalled = false
		default:
			f.LaunchAgentErr = fmt.Sprintf("llmpilot could not read the login item: %v", err)
		}
	}
	dir, err := claudecfg.DefaultDir()
	if err != nil {
		f.StatusLineErr = fmt.Sprintf("llmpilot could not find Claude Code's settings: %v", err)
		return f, nil
	}
	raw, err := dir.StatusLine()
	if err != nil {
		f.StatusLineErr = fmt.Sprintf("llmpilot could not read %s: %v", dir.SettingsPath(), err)
		return f, nil
	}
	kind, command := cli.ClassifyStatusLine(raw)
	switch kind {
	case cli.StatusLineOurs:
		f.StatusLine = doctor.StatusLineOurs
	case cli.StatusLineForeign:
		f.StatusLine = doctor.StatusLineForeign
		// ClassifyStatusLine falls back to the RAW settings value when it
		// cannot read a command out of it. That blob is arbitrary user content
		// — hand over only a value we actually parsed as a command, and let the
		// engine reduce even that to a program name.
		if claudecfg.StatusLineCommand(raw) != "" {
			f.StatusLineOwner = command
		}
	default:
		f.StatusLine = doctor.StatusLineNone
	}
	return f, nil
}

// doctorTimeout is generous on purpose: this is a user-invoked diagnostic, and
// GET /v1/doctor is the most expensive route the daemon serves (one Keychain
// read per account). The statusline's sub-second budget here would report a
// busy daemon as a missing one. A var so a test can drive the slow path
// without sleeping for it.
var doctorTimeout = 5 * time.Second

func doctorCmd() *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "doctor",
		Short: "check the fleet and name what is wrong",
		Long: `Looks at everything llmpilot already knows — the accounts, the sign-ins on
this Mac, the refresh budget, the daemon and the install — and reports what is
wrong, what it could not check, and the one thing that fixes each finding.

The doctor only looks. It never switches, refreshes, signs in or writes.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			degradedNote := ""
			// Both transports are tried, so the per-attempt budget would be
			// spent TWICE. This is the budget for the whole command: the
			// second transport gets whatever the first left.
			ctx, cancel := context.WithTimeout(cmd.Context(), doctorTimeout+time.Second)
			defer cancel()
			rep, err := (&cli.Client{Home: st.Home(), Timeout: doctorTimeout}).Doctor(ctx)
			if errors.Is(err, cli.ErrDaemonDown) {
				degradedNote = "daemon not running — the checks that need it are listed as not checked below"
				in := localDoctorInputs(st)
				switch {
				case errors.Is(err, cli.ErrDaemonSlow):
					// BUSY is not STALE. The health sweep is the most
					// expensive route the daemon serves, so a daemon working
					// through a big fleet lands here — and handing that user a
					// hard kill would stop a rotation mid-flight. There is
					// nothing to restart and nothing to press.
					in.DaemonUnreachable = "llmpilot's daemon accepted the connection but did not answer in time — the health sweep is the most expensive thing it does, so a busy daemon can miss the deadline."
					in.RestartRemedy = doctor.Remedy{
						Verb:  doctor.VerbNone,
						Label: "Nothing to press — run this again in a moment",
					}
					// A busy daemon is still doing its job: this is a warning
					// about what llmpilot could not see, not a critical about
					// a fleet that has stopped working.
					in.DaemonUnreachableSeverity = doctor.Warning
					degradedNote = "the daemon did not answer in time — the checks that need it are listed as not checked below"
				case errors.Is(err, cli.ErrDaemonAnswered):
					// Something IS listening where the daemon listens — most
					// likely a daemon older than this binary, possibly a
					// leftover port file. Telling that user to start a daemon
					// they may already be running is the same lie as a false
					// all-clear, aimed the other way. It is DECLARED, not
					// proven: all llmpilot knows is that something replied.
					in.DaemonUnreachable = "Something is listening where llmpilot's daemon listens: " +
						cli.AnsweredReason(err) +
						". That is usually a daemon older than this copy of llmpilot, or one whose own health check is failing. " +
						"(If you started it yourself with `llmpilot daemon run`, restart that process instead.)"
					// `daemon install` only WRITES the launch agent: for an
					// agent launchd has already loaded it changes nothing, so
					// pointing there would loop the user through a no-op. A
					// daemon started with `llmpilot daemon run` is not in
					// launchd at all, which the copy says out loud.
					in.RestartRemedy = doctor.Remedy{
						Verb:    doctor.VerbInstallDaemon,
						Label:   "Restart the daemon",
						Command: daemon.RestartCommand(),
					}
					degradedNote = "the daemon did not answer with a health report — the checks that need it are listed as not checked below"
				}
				local := doctor.Run(cmd.Context(), in)
				rep, err = &local, nil
			}
			if err != nil {
				return err
			}
			if asJSON {
				doc := struct {
					doctor.Report
					Degraded bool `json:"degraded,omitempty"`
				}{Report: *rep, Degraded: degradedNote != ""}
				enc := json.NewEncoder(out)
				enc.SetIndent("", "  ")
				return enc.Encode(doc)
			}
			cli.RenderDoctor(out, rep, degradedNote)
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print the report as JSON")
	return cmd
}

// localDoctorInputs is the degraded sweep: the same readers the daemon uses,
// with no daemon facts at all. A switcher that will not build costs the checks
// that need it — they report NOT CHECKED, which is the honest answer.
func localDoctorInputs(st *store.Store) doctor.Inputs {
	sw, err := newGlobalSwitcher(st)
	if err != nil {
		sw = nil
	}
	if sw == nil {
		return daemon.DoctorInputs(st, accountIsPinned, nil, doctorReaders(st, nil), time.Now)
	}
	return daemon.DoctorInputs(st, accountIsPinned, sw.MovedDirs, doctorReaders(st, sw), time.Now)
}
