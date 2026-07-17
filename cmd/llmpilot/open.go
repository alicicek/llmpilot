package main

import (
	"fmt"
	"os/exec"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/cli"
	"github.com/alicicek/llmpilot/internal/store"
)

// openBrowser is swapped in tests; production uses macOS `open`.
var openBrowser = func(url string) error {
	return exec.Command("open", url).Run()
}

func openCmd() *cobra.Command {
	var printOnly bool
	cmd := &cobra.Command{
		Use:   "open",
		Short: "open the cockpit in the browser (fallback path — the menu bar app hosts it natively)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			c := &cli.Client{Home: st.Home()}
			url, err := c.CockpitURL(cmd.Context())
			if err != nil {
				return err
			}
			if printOnly {
				fmt.Fprintln(cmd.OutOrStdout(), url)
				return nil
			}
			// Print the bare origin: the fragment carries the install token,
			// which does not belong in terminal scrollback.
			base, _ := c.LoopbackURL(cmd.Context())
			fmt.Fprintf(cmd.OutOrStdout(), "cockpit → %s\n", base)
			return openBrowser(url)
		},
	}
	cmd.Flags().BoolVar(&printOnly, "print", false, "print the URL instead of opening it")
	return cmd
}
