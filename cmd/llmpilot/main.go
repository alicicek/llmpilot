// Command llmpilot is "your Claude accounts, on autopilot": a multi-account
// Claude Code companion for macOS.
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// version is stamped by goreleaser at release time.
var version = "dev"

func main() {
	if err := rootCmd().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func rootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:           "llmpilot",
		Short:         "your Claude accounts, on autopilot",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(debugCmd(), switchCmd(), accountCmd(), daemonCmd(),
		statusCmd(), accountsCmd(), statuslineCmd(), initCmd(),
		scheduleCmd(), logCmd(), wakeCmd(), openCmd(), doctorCmd(),
		tokenCmd())
	return root
}
