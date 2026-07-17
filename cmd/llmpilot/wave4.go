package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// newTriggerSync targets the real LaunchAgents dir — except under
// LLMPILOT_TEST, where the plists land in a sandbox dir (LLMPILOT_AGENTS_DIR)
// and launchctl is echoed instead of executed: a sandbox plist must never be
// bootstrapped into the user's real launchd (it would actually fire).
func newTriggerSync(out *cobra.Command) (pilotapi.TriggerSync, error) {
	prov := pilot.Get()
	if !prov.Available {
		return nil, pilot.NotAvailable("scheduling")
	}
	lm, err := cliLicenseManager()
	if err != nil {
		return nil, err
	}
	if !lm.Allowed(out.Context(), "scheduling", time.Now()) {
		return nil, pilot.NotLicensed("scheduling")
	}
	cfg := pilotapi.TriggerSyncConfig{UID: os.Getuid(), Out: out.OutOrStdout()}
	if os.Getenv("LLMPILOT_TEST") != "" && os.Getenv("LLMPILOT_AGENTS_DIR") != "" {
		cfg.Dir = os.Getenv("LLMPILOT_AGENTS_DIR")
		cfg.Run = func(_ context.Context, name string, args ...string) ([]byte, error) {
			fmt.Fprintf(out.OutOrStdout(), "%s %s (skipped: sandbox)\n", name, strings.Join(args, " "))
			return nil, nil
		}
		return prov.NewTriggerSync(cfg), nil
	}
	dir, err := pilotapi.AgentsDir()
	if err != nil {
		return nil, err
	}
	cfg.Dir = dir
	return prov.NewTriggerSync(cfg), nil
}

// syncTriggers mirrors scheds into launchd BEFORE they're persisted — a
// failed bootstrap must not leave a saved-but-never-loaded schedule behind
// (review P2-7). A stray plist from the opposite failure order is cleaned
// by the next sync.
func syncTriggers(cmd *cobra.Command, st *store.Store, scheds []store.Schedule) error {
	l, err := newTriggerSync(cmd)
	if err != nil {
		return err
	}
	bin, err := os.Executable()
	if err != nil {
		return err
	}
	return l.Sync(cmd.Context(), bin, scheds, st.Home())
}

func parseHHMM(s string) (int, int, error) {
	h, m, ok := strings.Cut(s, ":")
	if ok {
		hour, err1 := strconv.Atoi(h)
		minute, err2 := strconv.Atoi(m)
		if err1 == nil && err2 == nil && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 {
			return hour, minute, nil
		}
	}
	return 0, 0, fmt.Errorf("time must be HH:MM (24h), got %q", s)
}

func scheduleCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "schedule", Short: "daily window triggers (start an account's 5h window on time)"}

	var model, effort string
	add := &cobra.Command{
		Use:   "add <account> <HH:MM>",
		Short: "fire a trigger on the account daily at HH:MM (default: cheapest model)",
		Long: `Fire a tiny prompt on the account daily at HH:MM so its 5-hour window
starts then. Default is the cheapest model; --model fable --effort low aims
the trigger at the Fable weekly bucket instead (only the prompted model's
bucket starts).`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			acct, err := findAccount(st, args[0])
			if err != nil {
				return err
			}
			hour, minute, err := parseHHMM(args[1])
			if err != nil {
				return err
			}
			scheds, err := st.Schedules()
			if err != nil {
				return err
			}
			sched := store.Schedule{
				ID:        store.UniqueScheduleID(scheds, acct.ID, acct.Label, hour, minute),
				AccountID: acct.ID,
				Hour:      hour,
				Minute:    minute,
				Model:     model,
				Effort:    effort,
			}
			for _, sc := range scheds {
				if sc.ID == sched.ID {
					fmt.Fprintf(cmd.OutOrStdout(), "already scheduled: %s\n", sc.ID)
					return nil
				}
			}
			next := append(scheds, sched)
			if err := syncTriggers(cmd, st, next); err != nil {
				return err
			}
			if err := st.SaveSchedules(next); err != nil {
				return err
			}
			desc := ""
			if model != "" {
				desc = " (" + model
				if effort != "" {
					desc += " " + effort
				}
				desc += ")"
			}
			fmt.Fprintf(cmd.OutOrStdout(), "scheduled %s — %s daily at %02d:%02d%s\n",
				sched.ID, acct.Label, hour, minute, desc)
			return nil
		},
	}
	add.Flags().StringVar(&model, "model", "", "trigger model (default cheapest; fable aims the Fable bucket)")
	add.Flags().StringVar(&effort, "effort", "", "trigger effort (e.g. low)")

	list := &cobra.Command{
		Use:   "list",
		Short: "show schedules",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			scheds, err := st.Schedules()
			if err != nil {
				return err
			}
			if len(scheds) == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "no schedules — llmpilot schedule add <account> <HH:MM>")
				return nil
			}
			accs, err := st.Accounts()
			if err != nil {
				return err
			}
			labels := map[string]string{}
			for _, a := range accs {
				labels[a.ID] = a.Label
			}
			for _, sc := range scheds {
				label := labels[sc.AccountID]
				if label == "" {
					label = sc.AccountID + " (unregistered!)"
				}
				fmt.Fprintf(cmd.OutOrStdout(), "%02d:%02d  %s  %s\n", sc.Hour, sc.Minute, sc.ID, label)
			}
			return nil
		},
	}

	remove := &cobra.Command{
		Use:   "remove <id>",
		Short: "remove a schedule and its launchd job",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			scheds, err := st.Schedules()
			if err != nil {
				return err
			}
			kept := scheds[:0]
			for _, sc := range scheds {
				if sc.ID != args[0] {
					kept = append(kept, sc)
				}
			}
			if len(kept) == len(scheds) {
				return fmt.Errorf("no schedule %q — `llmpilot schedule list` shows them", args[0])
			}
			// kept aliases scheds' backing array — safe: SaveSchedules only
			// runs after the sync already removed the plist.
			if err := syncTriggers(cmd, st, kept); err != nil {
				return err
			}
			if err := st.SaveSchedules(kept); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "removed %s\n", args[0])
			return nil
		},
	}

	fire := &cobra.Command{
		Use:   "fire <id>",
		Short: "run one schedule's trigger now (what the launchd job execs)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			prov := pilot.Get()
			if !prov.Available {
				return pilot.NotAvailable("scheduling")
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			if !newLicenseManager(st).Allowed(cmd.Context(), "scheduling", time.Now()) {
				return pilot.NotLicensed("scheduling")
			}
			ver := claudecfg.Version(cmd.Context(), claudecfg.ExecRunner)
			f := prov.NewFirer(pilotapi.FirerConfig{
				Store: st,
				Out:   cmd.OutOrStdout(),
				Fetch: func(ctx context.Context, a store.Account) ([]store.Bucket, error) {
					c := &anthropic.UsageClient{
						Source:    tokenSourceFor(a),
						UserAgent: "claude-code/" + ver,
						BaseURL:   sandboxUsageURL(),
					}
					return c.FetchUsage(ctx)
				},
				// The identity guard reads through the claudecfg adapter —
				// the engine never learns Claude Code's config layout.
				Identity: func(configDir string) string {
					acct, err := claudecfg.DirAt(configDir).OAuthAccount()
					if err != nil || acct == nil {
						return ""
					}
					return acct.EmailAddress
				},
			})
			return f.Fire(cmd.Context(), args[0])
		},
	}

	cmd.AddCommand(add, list, remove, fire)
	return cmd
}

func logCmd() *cobra.Command {
	var n int
	cmd := &cobra.Command{
		Use:   "log",
		Short: "the autopilot's event log (switches, triggers, wakes)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			evs, err := st.Events(n)
			if err != nil {
				return err
			}
			if len(evs) == 0 {
				fmt.Fprintln(cmd.OutOrStdout(), "no events yet — the autopilot logs switches and triggers here")
				return nil
			}
			for _, e := range evs {
				late := ""
				if e.Late {
					late = "  LATE"
				}
				fmt.Fprintf(cmd.OutOrStdout(), "%s  %-15s %s%s\n",
					e.At.Local().Format("01-02 15:04"), e.Kind, e.Message, late)
			}
			return nil
		},
	}
	cmd.Flags().IntVarP(&n, "lines", "n", 50, "how many recent events")
	return cmd
}

// macNotify posts a notification-center banner. Body/title are our own
// generated strings; %q escaping matches AppleScript string literals.
func macNotify(ctx context.Context, title, body string) {
	script := fmt.Sprintf("display notification %q with title %q", body, title)
	_ = exec.CommandContext(ctx, "osascript", "-e", script).Run()
}
