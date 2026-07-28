package main

// `llmpilot token` — long-lived headless tokens (the `claude setup-token` /
// CLAUDE_CODE_OAUTH_TOKEN class) as a UTILITY, never a fleet lane: no
// registry row, no switch verb, no refresh machinery. Token bytes live in
// llmpilot's own Keychain service and leave it exactly one way — the
// clipboard, on an explicit copy. No verb prints a token, ever.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// tokenStoreFor binds the token store to the real Keychain and clipboard. A
// var so tests swap in fakes and run every verb with a live-shaped token.
var tokenStoreFor = func(st *store.Store) *setuptoken.Store {
	return &setuptoken.Store{
		Home:     st.Home(),
		Keychain: &switcher.Keychain{File: sandboxKeychain()},
	}
}

// tokenInput reads the pasted token. On a terminal the echo is off (the token
// must not land in scrollback); piped input reads one line, so CI-ish
// scripting (`llmpilot token add < file`) works headlessly. A var: the
// no-echo path needs a real TTY, so tests inject their own reader.
var tokenInput = func(cmd *cobra.Command) ([]byte, error) {
	if term.IsTerminal(int(os.Stdin.Fd())) {
		fmt.Fprint(cmd.OutOrStdout(), "Token (input hidden): ")
		defer fmt.Fprintln(cmd.OutOrStdout())
		return term.ReadPassword(int(os.Stdin.Fd()))
	}
	// Piped: one line from the SAME stream the TTY check looked at. A read
	// error must surface, not silently return a truncated token that still
	// passes the prefix check and could --replace a good one; the cap keeps
	// `token add < /dev/zero` from appending forever.
	var line []byte
	buf := make([]byte, 1)
	for len(line) < 4096 {
		n, err := os.Stdin.Read(buf)
		if n > 0 {
			if buf[0] == '\n' {
				return line, nil
			}
			line = append(line, buf[0])
		}
		if err == io.EOF {
			return line, nil
		}
		if err != nil {
			return nil, err
		}
	}
	return nil, errors.New("pasted input is too long to be a token")
}

// declaredExpiry renders the honesty register once: the 1-year lifetime is
// what Claude Code declared at mint time, never server truth.
func declaredExpiry(m setuptoken.Meta, now time.Time) string {
	// Expired keys on the INSTANT: day-rounding once held a lapsed token at
	// "0d left" for a whole day (adversarial review P1).
	if m.Expired(now) {
		return fmt.Sprintf("passed its declared expiry %s (1-year per Claude Code — declared, not verified)", m.ExpiresAt.Format("2 Jan 2006"))
	}
	return fmt.Sprintf("expires ~%s (%dd left; 1-year per Claude Code — declared, not verified)", m.ExpiresAt.Format("2 Jan 2006"), m.DaysLeft(now))
}

func tokenCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "token",
		Short: "manage long-lived headless tokens (CI / CLAUDE_CODE_OAUTH_TOKEN)",
		Long: `Stores the long-lived tokens ` + "`claude setup-token`" + ` mints — for CI secrets
and headless machines — in llmpilot's own Keychain, and reminds you before
one expires. These tokens are a utility, not an account: they cannot be
switched, refreshed or kept warm, and they never join the fleet.`,
	}
	cmd.AddCommand(tokenAddCmd(), tokenListCmd(), tokenCopyCmd(), tokenRemoveCmd())
	return cmd
}

func tokenAddCmd() *cobra.Command {
	var label string
	var replace bool
	cmd := &cobra.Command{
		Use:   "add",
		Short: "store a setup token (guides the mint, then takes a paste)",
		Long: `Guides you through minting a token with ` + "`claude setup-token`" + ` and stores
the paste in llmpilot's own Keychain. On a terminal the paste is hidden;
piped input (llmpilot token add < file) also works for scripting — mind
your shell's history and scrollback if you echo the token to get it there.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			// Refuse a bad label BEFORE the paste is consumed — a refusal
			// after would make the user re-paste a live secret.
			if _, err := setuptoken.ValidateLabel(label); err != nil {
				return err
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			fmt.Fprintln(out, "To mint a token, run this in another terminal:")
			fmt.Fprintln(out)
			fmt.Fprintln(out, "  claude setup-token")
			fmt.Fprintln(out)
			fmt.Fprintln(out, "Complete the sign-in it opens, then paste the token it prints.")
			tok, err := tokenInput(cmd)
			if err != nil {
				return fmt.Errorf("read the pasted token: %w", err)
			}
			meta, err := tokenStoreFor(st).Add(cmd.Context(), label, tok, replace)
			if err != nil {
				return err
			}
			fmt.Fprintf(out, "Stored %q in the Keychain — it %s.\n", meta.Label, declaredExpiry(meta, time.Now()))
			fmt.Fprintf(out, "Copy it out with: llmpilot token copy %s\n", meta.Label)
			return nil
		},
	}
	cmd.Flags().StringVar(&label, "label", "default", "name for this token (e.g. ci)")
	cmd.Flags().BoolVar(&replace, "replace", false, "rotate: overwrite the token already stored under this label")
	return cmd
}

func tokenListCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "list stored tokens with days to expiry",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			tokens, err := tokenStoreFor(st).List()
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			if len(tokens) == 0 {
				fmt.Fprintln(out, "No tokens stored. Mint one with `claude setup-token`, then run: llmpilot token add")
				return nil
			}
			now := time.Now()
			for _, m := range tokens {
				fmt.Fprintf(out, "%-16s %s\n", m.Label, declaredExpiry(m, now))
			}
			// Probed 2026-07-26 (HTTP 403): the usage endpoint refuses the
			// inference-only scope these tokens carry, so llmpilot cannot
			// show usage for them — said here so nobody goes looking.
			fmt.Fprintln(out, "\nSetup tokens cannot report usage: Claude's usage endpoint refuses their inference-only scope.")
			return nil
		},
	}
}

func tokenCopyCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "copy [label]",
		Short: "copy a token to the clipboard for a CI secret",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			label := "default"
			if len(args) == 1 {
				label = args[0]
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			meta, err := tokenStoreFor(st).Copy(cmd.Context(), label)
			if err != nil {
				return err
			}
			out := cmd.OutOrStdout()
			fmt.Fprintf(out, "Copied %q to the clipboard — it %s.\n", label, declaredExpiry(meta, time.Now()))
			fmt.Fprintln(out, "The clipboard can be read by clipboard managers and may sync to your other devices: paste it where it goes, then clear it (pbcopy </dev/null).")
			return nil
		},
	}
}

func tokenRemoveCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "remove <label>",
		Short: "delete a stored token and its record",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			if err := tokenStoreFor(st).Remove(cmd.Context(), args[0]); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Removed %q — the Keychain item and its record are gone.\n", args[0])
			return nil
		},
	}
}
