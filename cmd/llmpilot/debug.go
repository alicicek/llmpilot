package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/analytics"
	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/cli"
	"github.com/alicicek/llmpilot/internal/store"
)

func debugCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "debug",
		Short: "inspect llmpilot's data layer (read-only)",
	}
	cmd.AddCommand(debugFetchCmd(), debugAnalyticsCmd())
	return cmd
}

func debugFetchCmd() *cobra.Command {
	var fixtures bool
	var fixturesDir string
	var account string
	var asJSON bool
	cmd := &cobra.Command{
		Use:   "fetch",
		Short: "fetch usage buckets and print them",
		Long: `Fetch rate-limit buckets and print every one the endpoint reports,
including kinds this build has never heard of.

With --fixtures: recorded responses for two fake accounts (no network,
no keychain). With --account <label>: one read-only GET for that
registered account (an idle account reads its backed-up token, so it
never reads the active account by mistake). Without either: one
read-only GET for the active account — the first run from a fresh
binary triggers one macOS Keychain prompt; click "Always Allow".`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if fixtures {
				return runFixtureFetch(cmd.OutOrStdout(), fixturesDir)
			}
			if account != "" {
				return runAccountFetch(cmd, account, asJSON)
			}
			return runLiveFetch(cmd, asJSON)
		},
	}
	cmd.Flags().BoolVar(&fixtures, "fixtures", false, "use recorded fixture responses (no network, no keychain)")
	cmd.Flags().StringVar(&fixturesDir, "fixtures-dir", "testdata/fixtures", "directory holding accounts.json + usage-<label>.json")
	cmd.Flags().StringVar(&account, "account", "", "fetch a specific registered account (label, id, or email) instead of the active one")
	cmd.Flags().BoolVar(&asJSON, "json", false, "print the buckets as JSON (for scripting)")
	return cmd
}

// runAccountFetch fetches one registered account's usage using the same
// source selection the daemon uses (an idle global account reads its backup),
// so `debug fetch --account <idle>` reports that account's numbers, not the
// active account's. This is the read side of the keep-warm no-window-advance
// proof: compare an account's buckets before and after a refresh.
func runAccountFetch(cmd *cobra.Command, key string, asJSON bool) error {
	ctx := cmd.Context()
	st, err := store.Open()
	if err != nil {
		return err
	}
	acct, err := findAccount(st, key)
	if err != nil {
		return err
	}
	sw, swErr := newGlobalSwitcher(st)
	if swErr != nil {
		sw = nil // fall back to the account's own dir source
	}
	client := &anthropic.UsageClient{
		Source:    daemonTokenSource(sw, acct, activeEmail()),
		UserAgent: "claude-code/" + claudecfg.Version(ctx, claudecfg.ExecRunner),
		BaseURL:   sandboxUsageURL(),
	}
	buckets, err := client.FetchUsage(ctx)
	if err != nil {
		var se *anthropic.StatusError
		if errors.As(err, &se) {
			switch se.StatusCode {
			case 401:
				return fmt.Errorf("account %q: token expired — run a claude session in %s (or `llmpilot account add`) to refresh, then retry", acct.Label, acctDir(acct))
			case 429:
				return fmt.Errorf("account %q: rate limited; wait before retrying", acct.Label)
			}
			return se
		}
		// Not an HTTP error → there was no readable credential to send at all
		// (the account is logged out of its config dir).
		return fmt.Errorf("account %q: no readable credential in %s — it looks logged out; run a claude session there, or re-add it with `llmpilot account add`", acct.Label, acctDir(acct))
	}
	if asJSON {
		return json.NewEncoder(cmd.OutOrStdout()).Encode(buckets)
	}
	printBuckets(cmd.OutOrStdout(), fmt.Sprintf("acct %s — %s (read-only)", acct.Label, cli.MaskEmail(acct.Email)), buckets)
	return nil
}

// acctDir names an account's config dir for error text ("its config dir" when
// the account carries none).
func acctDir(a store.Account) string {
	if a.ConfigDir == "" {
		return "its config dir"
	}
	return a.ConfigDir
}

func runFixtureFetch(out io.Writer, dir string) error {
	data, err := os.ReadFile(filepath.Join(dir, "accounts.json"))
	if err != nil {
		return err
	}
	var accounts []store.Account
	if err := json.Unmarshal(data, &accounts); err != nil {
		return fmt.Errorf("parse accounts fixture: %w", err)
	}
	for i, acct := range accounts {
		raw, err := os.ReadFile(filepath.Join(dir, "usage-"+acct.Label+".json"))
		if err != nil {
			return err
		}
		buckets, err := anthropic.ParseUsage(raw)
		if err != nil {
			return fmt.Errorf("account %s: %w", acct.Label, err)
		}
		if i > 0 {
			fmt.Fprintln(out)
		}
		printBuckets(out, fmt.Sprintf("acct %s — %s (fixture)", acct.Label, acct.Email), buckets)
	}
	return nil
}

func runLiveFetch(cmd *cobra.Command, asJSON bool) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	dir, err := claudecfg.DefaultDir()
	if err != nil {
		return err
	}
	who := "unknown account"
	if acct, err := dir.OAuthAccount(); err == nil && acct != nil && acct.EmailAddress != "" {
		who = cli.MaskEmail(acct.EmailAddress)
	}

	client := &anthropic.UsageClient{
		Source: anthropic.FirstSource{
			&anthropic.KeychainSource{Service: dir.KeychainService()},
			&anthropic.FileSource{Path: dir.CredentialsFilePath()},
		},
		UserAgent: "claude-code/" + claudecfg.Version(ctx, claudecfg.ExecRunner),
	}
	buckets, err := client.FetchUsage(ctx)
	if err != nil {
		var se *anthropic.StatusError
		if errors.As(err, &se) {
			switch se.StatusCode {
			case 401:
				return fmt.Errorf("%w — token expired or missing; run any `claude` session once to refresh, then retry", se)
			case 429:
				return fmt.Errorf("%w — rate limited; wait before retrying (llmpilot backs off up to 30m)", se)
			}
		}
		return err
	}
	if asJSON {
		return json.NewEncoder(out).Encode(buckets)
	}
	printBuckets(out, fmt.Sprintf("acct %s (live, read-only, as of %s)",
		who, time.Now().UTC().Format("15:04:05 MST")), buckets)
	return nil
}

func debugAnalyticsCmd() *cobra.Command {
	var configDir, accountID string
	cmd := &cobra.Command{
		Use:   "analytics",
		Short: "aggregate local transcript token usage per model and day",
		Long: `Walk a Claude config dir's projects/ transcripts and print token
totals by model and day. Reads transcripts only; writes nothing but its
own cache under $LLMPILOT_HOME. Transcripts carry no effort and no cost
fields, so those dimensions are deliberately absent.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			out := cmd.OutOrStdout()
			if configDir == "" {
				d, err := claudecfg.DefaultDir()
				if err != nil {
					return err
				}
				configDir = d.Path()
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			cachePath, err := st.AnalyticsCachePath(accountID)
			if err != nil {
				return err
			}
			agg, err := analytics.Scan(configDir, cachePath)
			if err != nil {
				return err
			}

			fmt.Fprintf(out, "analytics — %d transcript files (%d parsed, %d cached) under %s\n",
				agg.FilesTotal, agg.FilesParsed, agg.FilesReused, configDir)
			fmt.Fprintln(out, "note: transcripts carry no effort and no cost fields — token totals only")
			fmt.Fprintln(out)

			tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', tabwriter.AlignRight)
			fmt.Fprintln(tw, "model\tmessages\tinput\toutput\tcache-create\tcache-read\t")
			for _, c := range agg.TotalsByModel() {
				fmt.Fprintf(tw, "%s\t%d\t%d\t%d\t%d\t%d\t\n",
					c.Model, c.Messages, c.Tokens.Input, c.Tokens.Output,
					c.Tokens.CacheCreation, c.Tokens.CacheRead)
			}
			if err := tw.Flush(); err != nil {
				return err
			}

			fmt.Fprintln(out, "\nby day:")
			twd := tabwriter.NewWriter(out, 0, 0, 2, ' ', tabwriter.AlignRight)
			for _, c := range agg.Cells {
				fmt.Fprintf(twd, "%s\t%s\t%d msgs\t%d in\t%d out\t\n",
					c.Day, c.Model, c.Messages, c.Tokens.Input, c.Tokens.Output)
			}
			return twd.Flush()
		},
	}
	cmd.Flags().StringVar(&configDir, "config-dir", "", "Claude config dir to scan (default: the active one)")
	cmd.Flags().StringVar(&accountID, "account-id", "default", "cache key for this scan")
	return cmd
}

func printBuckets(out io.Writer, header string, buckets []store.Bucket) {
	fmt.Fprintln(out, header)
	if len(buckets) == 0 {
		fmt.Fprintln(out, "  no buckets reported")
		return
	}
	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	for _, b := range buckets {
		kind := b.Kind
		if b.Scope != "" {
			kind += "[" + b.Scope + "]"
		}
		sev := b.Severity
		if sev == "" {
			sev = "-"
		}
		reset := "-"
		if b.ResetsAt != nil {
			reset = "resets " + b.ResetsAt.UTC().Format("2006-01-02 15:04 MST")
		}
		active := ""
		if b.Active {
			active = "active"
		}
		fmt.Fprintf(tw, "  %s\t%s%%\t%s\t%s\t%s\n",
			kind, strconv.FormatFloat(b.Percent, 'f', -1, 64), sev, reset, active)
	}
	_ = tw.Flush()
}
