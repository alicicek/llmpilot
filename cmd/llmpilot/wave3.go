package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/cli"
	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/statusline"
	"github.com/alicicek/llmpilot/internal/store"
)

// localState assembles a daemon.State straight from the cache files — the
// degraded path when no daemon answers. Same shape, honestly older data.
func localState(ctx context.Context, st *store.Store) (*daemon.State, error) {
	d := &daemon.Daemon{Store: st, Active: func(context.Context) string {
		dir, err := claudecfg.DefaultDir()
		if err != nil {
			return ""
		}
		oa, err := dir.OAuthAccount()
		if err != nil || oa == nil {
			return ""
		}
		accs, err := st.Accounts()
		if err != nil {
			return ""
		}
		for _, a := range accs {
			if a.Email == oa.EmailAddress {
				return a.ID
			}
		}
		return ""
	}}
	state, err := d.State(ctx)
	if err != nil {
		return nil, err
	}
	return &state, nil
}

func statusCmd() *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "status",
		Short: "the fleet: every account's runway, active account marked",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			degraded := false
			state, err := (&cli.Client{Home: st.Home()}).State(cmd.Context())
			if errors.Is(err, cli.ErrDaemonDown) {
				degraded = true
				state, err = localState(cmd.Context(), st)
			}
			if err != nil {
				return err
			}
			if asJSON {
				doc := struct {
					daemon.State
					Degraded bool `json:"degraded,omitempty"`
				}{State: *state, Degraded: degraded}
				enc := json.NewEncoder(out)
				enc.SetIndent("", "  ")
				return enc.Encode(doc)
			}
			if degraded {
				fmt.Fprintln(out, "daemon not running — llmpilot daemon install · cached data below")
			}
			cli.RenderFleet(out, state, time.Now(), time.Local)
			return nil
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print the state document as JSON")
	return cmd
}

func accountsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "accounts",
		Short: "registered accounts and where they live",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			accs, err := st.Accounts()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			if len(accs) == 0 {
				fmt.Fprintln(out, "no accounts registered — llmpilot init detects existing claude logins")
				return nil
			}
			activeID := ""
			if state, err := localState(cmd.Context(), st); err == nil {
				activeID = state.ActiveID
			}
			tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
			for i, a := range accs {
				marker := " "
				if a.ID == activeID {
					marker = "*"
				}
				pinned := ""
				if a.Pinned {
					pinned = "pinned"
				}
				fmt.Fprintf(tw, "%s %d/%d\t%s\t%s\t%s\t%s\n",
					marker, i+1, len(accs), a.Label, cli.MaskEmail(a.Email), a.ConfigDir, pinned)
			}
			return tw.Flush()
		},
	}
}

// statuslineTier resolves the render tier: NO_COLOR always wins (presence,
// not value — checked here where os.LookupEnv exists), then the config pin,
// then TERM/COLORTERM autodetection.
func statuslineTier(cfg statusline.Config) statusline.Tier {
	if _, set := os.LookupEnv("NO_COLOR"); set {
		return statusline.TierPlain
	}
	return statusline.ResolveTier(cfg.Color, os.Getenv)
}

// statuslineWidth reads COLUMNS (Claude Code exports it ≥2.1.153) with a
// tput fallback; 0 = unknown, which disables the flex collapse.
func statuslineWidth() int {
	if v := os.Getenv("COLUMNS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	if term := os.Getenv("TERM"); term != "" && term != "dumb" {
		if out, err := exec.Command("tput", "cols").Output(); err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(out))); err == nil && n > 0 {
				return n
			}
		}
	}
	return 0
}

func statuslineCmd() *cobra.Command {
	var privacy bool
	cmd := &cobra.Command{
		Use:   "statusline",
		Short: "one-line runway readout for Claude Code's statusLine hook",
		Long: `Reads Claude Code's statusline JSON on stdin, cache files directly (no
daemon round-trip), and prints one line. Customize segments in the cockpit
(Settings → Statusline) or $LLMPILOT_HOME/statusline.json; zero config renders
the classic runway line. Wire it up with: llmpilot statusline install`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var stdin []byte
			if f, ok := cmd.InOrStdin().(*os.File); ok {
				// Only read a pipe: a human running this in a terminal must
				// not hang on a TTY read.
				if fi, err := f.Stat(); err == nil && fi.Mode()&os.ModeCharDevice == 0 {
					stdin, _ = io.ReadAll(io.LimitReader(f, 1<<20))
				}
			} else {
				stdin, _ = io.ReadAll(io.LimitReader(cmd.InOrStdin(), 1<<20))
			}
			st, err := store.Open()
			if err != nil {
				st = nil // degraded: the line renders from stdin floor alone
			}
			dir, err := claudecfg.DefaultDir()
			if err != nil {
				dir = claudecfg.DirAt("")
			}
			cfg := statusline.Default()
			home := ""
			if st != nil {
				home = st.Home()
				cfg, _ = statusline.LoadConfig(home) // corrupt file → defaults, disk untouched
			}
			opts := cli.StatuslineOptions{
				Store:   st,
				Dir:     dir,
				Stdin:   stdin,
				Privacy: privacy,
				Config:  cfg,
				Width:   statuslineWidth(),
				Tier:    statuslineTier(cfg),
				Exec:    cli.StatuslineExec(150*time.Millisecond, stdin),
				// A kept statusline is a whole program (often an npx spawn) —
				// it gets a budget of its own, not the segment budget.
				KeepExec: cli.StatuslineExec(time.Second, stdin),
			}
			if home != "" {
				opts.History = cli.StatuslineHistory(home)
				opts.DaemonUp = cli.StatuslineDaemonUp(home)
			}
			fmt.Fprintln(cmd.OutOrStdout(), cli.StatuslineOutput(opts))
			return nil
		},
	}
	cmd.Flags().BoolVar(&privacy, "privacy", false, "alias mode: show acct n/m instead of the email")
	cmd.AddCommand(statuslineInstallCmd(), statuslineUninstallCmd(), statuslinePresetCmd())
	return cmd
}

func statuslineInstallCmd() *cobra.Command {
	var replace, keep bool
	cmd := &cobra.Command{
		Use:   "install",
		Short: "wire the statusline into Claude Code's settings.json",
		Long: `Sets settings.json's statusLine to this binary. An existing foreign
statusline is never clobbered silently: without a flag it is left alone and
shown. --keep runs it ABOVE the llmpilot line (coexist); --replace swaps it
out. Both back up (settings.json.orig + the exact value) and one command
reverts: llmpilot statusline uninstall`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			dir, err := claudecfg.DefaultDir()
			if err != nil {
				return err
			}
			bin, err := os.Executable()
			if err != nil {
				return err
			}
			mode := cli.InstallRefuse
			switch {
			case keep:
				mode = cli.InstallKeep
			case replace:
				mode = cli.InstallReplace
			}
			return cli.InstallStatusline(dir, st.Home(), bin, mode, cmd.OutOrStdout())
		},
	}
	cmd.Flags().BoolVar(&replace, "replace", false, "take over an existing foreign statusline (with backup + revert)")
	cmd.Flags().BoolVar(&keep, "keep", false, "keep an existing foreign statusline — it renders above the llmpilot line")
	return cmd
}

func statuslineUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall",
		Short: "remove our statusline from settings.json (restores a replaced one)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			dir, err := claudecfg.DefaultDir()
			if err != nil {
				return err
			}
			return cli.UninstallStatusline(dir, st.Home(), cmd.OutOrStdout())
		},
	}
}

func statuslinePresetCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "preset [name]",
		Short: "list presets, or write one to statusline.json",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			if len(args) == 0 {
				for _, p := range statusline.Presets() {
					fmt.Fprintf(out, "%-8s %s\n", p.ID, p.Desc)
				}
				return nil
			}
			p := statusline.PresetByID(args[0])
			if p == nil {
				return fmt.Errorf("no preset %q — `llmpilot statusline preset` lists them", args[0])
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			if err := statusline.SaveConfig(st.Home(), p.Config); err != nil {
				return err
			}
			fmt.Fprintf(out, "statusline.json now uses the %s preset\n", p.ID)
			return nil
		},
	}
}

func initCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "detect existing claude logins and register them",
		Long: `Scan for Claude Code config dirs with a logged-in account (~/.claude,
~/.claude-*, $CLAUDE_CONFIG_DIR), register each, and capture its credential
into llmpilot's own Keychain backups. Reading each account's credential asks
macOS once per account — click "Always Allow" so later reads stay silent.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			st, err := store.Open()
			if err != nil {
				return err
			}
			detected, err := cli.DetectDirs()
			if err != nil {
				return err
			}
			if len(detected) == 0 {
				return errors.New("no claude logins found — run `claude` once to log in, then retry")
			}
			existing, err := st.Accounts()
			if err != nil {
				return err
			}
			sw, err := newSwitcher(st)
			if err != nil {
				return err
			}
			sw.Out = io.Discard // init prints its own summary, not swap logs
			registered := 0
			for _, d := range detected {
				label := cli.SuggestLabel(d, existing)
				res, err := sw.AddAccount(cmd.Context(), d.Dir, label, nil, "claude")
				if err != nil {
					fmt.Fprintf(out, "  %s: skipped — %v\n", d.Dir.Path(), err)
					continue
				}
				registered++
				fmt.Fprintf(out, "  %s → %s (%s)\n",
					d.Dir.Path(), res.Account.Label, cli.MaskEmail(res.Account.Email))
			}
			if registered == 0 {
				return errors.New("found logins but registered none — see the lines above")
			}
			fmt.Fprintf(out, "%d account(s) registered\n\n", registered)
			state, err := localState(cmd.Context(), st)
			if err != nil {
				return err
			}
			cli.RenderFleet(out, state, time.Now(), time.Local)
			return nil
		},
	}
}

func daemonStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "is the daemon up?",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			state, err := (&cli.Client{Home: st.Home()}).State(cmd.Context())
			if errors.Is(err, cli.ErrDaemonDown) {
				fmt.Fprintln(out, "daemon not running — llmpilot daemon install (or foreground: llmpilot daemon run)")
				return nil
			}
			if err != nil {
				return err
			}
			age := cli.FormatAge(time.Since(state.AsOf))
			port := "-"
			if raw, err := os.ReadFile(daemon.PortFilePath(st.Home())); err == nil {
				port = strings.TrimSpace(string(raw))
			}
			fmt.Fprintf(out, "daemon running — %d account(s), state as of %s\nsocket %s\nport   %s\n",
				len(state.Accounts), age, daemon.SocketPath(st.Home()), port)
			return nil
		},
	}
}
