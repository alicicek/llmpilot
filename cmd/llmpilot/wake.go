package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

func wakeCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "wake", Short: "wake the mac for scheduled triggers"}

	status := &cobra.Command{
		Use:   "status",
		Short: "wake mode and the next fires",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			mode := pilotapi.WakeMode()
			switch mode {
			case "armed":
				fmt.Fprintln(out, "armed — exact wakes scheduled via pmset (lid-closed on battery is best-effort)")
			default:
				fmt.Fprintln(out, "degraded — no wake helper: a sleeping mac fires on its next wake, recorded LATE")
			}
			scheds, err := st.Schedules()
			if err != nil {
				return err
			}
			if len(scheds) == 0 {
				fmt.Fprintln(out, "no schedules — llmpilot schedule add <account> <HH:MM>")
				return nil
			}
			for _, p := range pilotapi.Plans(time.Now(), scheds, mode) {
				line := fmt.Sprintf("%s  fires %s", p.ScheduleID, p.FireAt.Local().Format("Mon 15:04"))
				if !p.WakeAt.IsZero() {
					line += fmt.Sprintf("  (wake armed %s)", p.WakeAt.Local().Format("15:04"))
				}
				fmt.Fprintln(out, line)
			}
			return nil
		},
	}

	install := &cobra.Command{
		Use:   "install",
		Short: "install the wake helper (prints the exact rule, then asks for sudo)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			prov := pilot.Get()
			if !prov.Available {
				return pilot.NotAvailable("wake scheduling")
			}
			lm, err := cliLicenseManager()
			if err != nil {
				return err
			}
			if !lm.Allowed(cmd.Context(), "wake", time.Now()) {
				return pilot.NotLicensed("wake scheduling")
			}
			return prov.WakeInstall(cmd.Context(), cmd.OutOrStdout())
		},
	}

	// Uninstall stays in the free build on purpose: whoever ends up with the
	// root-owned rule must always be able to remove it, engine or no engine.
	uninstall := &cobra.Command{
		Use:   "uninstall",
		Short: "remove the privileged wake helper (asks for sudo)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			if pilotapi.WakeMode() != "armed" {
				fmt.Fprintln(out, "nothing installed — wake is already in degraded mode")
				return nil
			}
			// Guard and action use the SAME resolved path (review P1-2),
			// and a sandbox never escalates: the interlock is code.
			path := pilotapi.WakeActivePath()
			if pilotapi.Sandboxed() {
				if path == pilotapi.SudoersPath {
					return fmt.Errorf("refusing under LLMPILOT_TEST: %s is the real helper", path)
				}
				if err := os.Remove(path); err != nil {
					return err
				}
				fmt.Fprintf(out, "removed %s (sandbox)\n", path)
				return nil
			}
			fmt.Fprintf(out, "removing %s (sudo will prompt)\n", path)
			rm := exec.CommandContext(cmd.Context(), "sudo", "rm", "--", path)
			rm.Stdin, rm.Stdout, rm.Stderr = os.Stdin, os.Stdout, os.Stderr
			if err := rm.Run(); err != nil {
				return fmt.Errorf("sudo rm failed: %w", err)
			}
			fmt.Fprintln(out, "removed — wake is in degraded mode (fires on next wake, recorded LATE)")
			return nil
		},
	}

	cmd.AddCommand(status, uninstall, install)
	return cmd
}
