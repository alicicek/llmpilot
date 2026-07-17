package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/anthropic"
	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/pilot"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
	"github.com/alicicek/llmpilot/web"
)

// sandboxKeychain returns the throwaway keychain file when one is forced via
// LLMPILOT_KEYCHAIN (sandbox runs); empty means the login keychain.
func sandboxKeychain() string { return os.Getenv("LLMPILOT_KEYCHAIN") }

// sandboxUsageURL lets sandbox runs (golden recordings, e2e scripts) point
// the poller at a local fixture server. Honored ONLY under LLMPILOT_TEST so
// no environment variable can ever redirect real bearer tokens off
// api.anthropic.com.
func sandboxUsageURL() string {
	if os.Getenv("LLMPILOT_TEST") == "" {
		return ""
	}
	return os.Getenv("LLMPILOT_USAGE_URL")
}

// entitlementBaseURL is the entitlement worker origin. Production hits the
// deployed worker; the local wrangler-dev loop overrides it via
// LLMPILOT_ENTITLEMENT_URL, but ONLY under the test sandbox with a throwaway
// keychain — a test endpoint must never be paired with the login Keychain
// (revocation responses are server-authoritative and carry no signature, so a
// test server could otherwise persist state into the user's real entitlement
// item). The app never holds a Stripe key; it only talks to this worker.
func entitlementBaseURL() string {
	if os.Getenv("LLMPILOT_TEST") != "" && sandboxKeychain() != "" && os.Getenv("LLMPILOT_ENTITLEMENT_URL") != "" {
		return strings.TrimRight(os.Getenv("LLMPILOT_ENTITLEMENT_URL"), "/")
	}
	return "https://api.llmpilot.dev"
}

func entitlementValidateURL() string {
	return entitlementBaseURL() + "/v1/validate"
}

func newLicenseManager(st *store.Store) *pilot.LicenseManager {
	// A missing install id fails closed everywhere (verification requires a
	// match), so licensing degrades honestly instead of running unbound.
	installID, err := st.InstallID()
	if err != nil {
		slog.Error("install id unavailable — Pro will stay off until it can be persisted", "err", err)
	}
	return &pilot.LicenseManager{
		Store:       pilot.KeychainLicenseStore{Keychain: &switcher.Keychain{File: sandboxKeychain()}},
		InstallID:   installID,
		Anchor:      &pilot.TimeAnchor{Dir: st.Home()},
		ValidateURL: entitlementValidateURL(),
		HTTP:        &http.Client{Timeout: 10 * time.Second},
	}
}

// cliLicenseManager is the one-shot license view for CLI gate checks.
func cliLicenseManager() (*pilot.LicenseManager, error) {
	st, err := store.Open()
	if err != nil {
		return nil, err
	}
	return newLicenseManager(st), nil
}

func newSwitcher(st *store.Store) (*switcher.Switcher, error) {
	dir, err := claudecfg.DefaultDir()
	if err != nil {
		return nil, err
	}
	return &switcher.Switcher{
		Dir:      dir,
		Keychain: &switcher.Keychain{File: sandboxKeychain()},
		Registry: st,
		Out:      os.Stdout,
	}, nil
}

func findAccount(st *store.Store, key string) (store.Account, error) {
	accs, err := st.Accounts()
	if err != nil {
		return store.Account{}, err
	}
	for _, a := range accs {
		if a.Label == key || a.ID == key || a.Email == key {
			return a, nil
		}
	}
	return store.Account{}, fmt.Errorf("no account %q — `llmpilot account add` registers one", key)
}

func switchCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "switch <label>",
		Short: "swap the active Claude Code account (lock-first, backed up)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			target, err := findAccount(st, args[0])
			if err != nil {
				return err
			}
			sw, err := newSwitcher(st)
			if err != nil {
				return err
			}
			if err := sw.Swap(cmd.Context(), target); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "switched to %s (%s)\n", target.Label, target.Email)
			return nil
		},
	}
}

func accountCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "account", Short: "manage registered accounts"}
	var label string
	add := &cobra.Command{
		Use:   "add",
		Short: "register the account in the active config dir (runs `claude auth login` if none)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			sw, err := newSwitcher(st)
			if err != nil {
				return err
			}
			res, err := sw.AddAccount(cmd.Context(), sw.Dir, label, switcher.ExecLoginRunner, "claude")
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "registered %s (%s) via %s\n",
				res.Account.Label, res.Account.Email, res.LoggedVia)
			return nil
		},
	}
	add.Flags().StringVar(&label, "label", "", "short name for the account (default: email local part)")
	cmd.AddCommand(add)

	// refresh runs ONE keep-warm cycle through the real engine — the
	// deterministic trigger the no-window-advance e2e drives, and a support
	// probe when an idle account looks stale. Hidden: the daemon does this
	// automatically; this is the manual/one-shot escape hatch.
	refresh := &cobra.Command{
		Use:    "refresh <account>",
		Short:  "refresh one account's OAuth token now",
		Args:   cobra.ExactArgs(1),
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			st, err := store.Open()
			if err != nil {
				return err
			}
			target, err := findAccount(st, args[0])
			if err != nil {
				return err
			}
			sw, err := newGlobalSwitcher(st)
			if err != nil {
				return err
			}
			sw.Out = cmd.ErrOrStderr() // lock transcript to stderr, never secrets
			ver := claudecfg.Version(cmd.Context(), claudecfg.ExecRunner)
			opts := keepWarmOpts(ver)
			opts.RefreshLead = 1000 * time.Hour // force: attempt regardless of how far off expiry is
			before, _ := daemonExpirySource(sw, target, activeEmail()).Expiry(cmd.Context())
			res, err := sw.KeepWarm(cmd.Context(), target, opts)
			if err != nil {
				// Classify like the daemon does: a dead lineage needs a
				// re-login, a 429 is a transient endpoint throttle (retry
				// later) — never conflate the two.
				if errors.Is(err, switcher.ErrLineageDead) {
					return fmt.Errorf("account %q: sign-in expired — log in to it again, then `llmpilot account add`", target.Label)
				}
				var re *anthropic.RefreshError
				if errors.As(err, &re) && re.StatusCode == 429 {
					return fmt.Errorf("account %q: the token endpoint is rate-limiting refreshes (HTTP 429) — transient, wait a few minutes and retry", target.Label)
				}
				return err
			}
			out := cmd.OutOrStdout()
			if res.Rotated {
				fmt.Fprintf(out, "refreshed %s — token valid until %s (was %s)\n",
					target.Label, fmtExpiry(res.Expiry), fmtExpiry(before))
				return nil
			}
			fmt.Fprintf(out, "no refresh for %s: %s (token %s)\n",
				target.Label, res.Skipped, fmtExpiry(before))
			return nil
		},
	}
	cmd.AddCommand(refresh)
	return cmd
}

// fmtExpiry renders a token expiry for the CLI without ever touching the
// token itself.
func fmtExpiry(t time.Time) string {
	if t.IsZero() {
		return "expiry unknown"
	}
	return t.Local().Format("2006-01-02 15:04")
}

// newGlobalSwitcher targets the machine-global config dir — the daemon's
// autonomous rotation must never adopt a pinned terminal's CLAUDE_CONFIG_DIR
// (review P1-1); the user-invoked `llmpilot switch` keeps honoring it.
func newGlobalSwitcher(st *store.Store) (*switcher.Switcher, error) {
	dir, err := claudecfg.GlobalDir()
	if err != nil {
		return nil, err
	}
	return &switcher.Switcher{
		Dir:      dir,
		Keychain: &switcher.Keychain{File: sandboxKeychain()},
		Registry: st,
		Out:      os.Stdout,
	}, nil
}

func newDaemon(st *store.Store) *daemon.Daemon {
	ver := claudecfg.Version(context.Background(), claudecfg.ExecRunner)
	sw, swErr := newGlobalSwitcher(st)
	d := &daemon.Daemon{
		Store: st,
		Log:   slog.Default(),
		Fetch: func(ctx context.Context, a store.Account) ([]store.Bucket, error) {
			c := &anthropic.UsageClient{
				Source:    daemonTokenSource(sw, a, activeEmail()),
				UserAgent: "claude-code/" + ver,
				BaseURL:   sandboxUsageURL(),
			}
			return c.FetchUsage(ctx)
		},
		Expiry: func(ctx context.Context, a store.Account) (time.Time, error) {
			return daemonExpirySource(sw, a, activeEmail()).Expiry(ctx)
		},
		Refresh: func(ctx context.Context, a store.Account) error {
			// Delegated: run `claude auth status` under the ACCOUNT'S config
			// dir — CLAUDE_CONFIG_DIR steers which keychain entry the CLI
			// touches. Read-only in CC 2.1.205 — refreshIdle verifies the
			// expiry moved and surfaces an honest note when it didn't.
			cmd := exec.CommandContext(ctx, "claude", "auth", "status", "--json")
			if a.ConfigDir != "" {
				// strip any inherited pin first: getenv takes the FIRST
				// duplicate, so append-only env could refresh the wrong
				// account (review P1-1, same trap as the trigger fire path).
				cmd.Env = append(envWithout(os.Environ(), "CLAUDE_CONFIG_DIR"),
					"CLAUDE_CONFIG_DIR="+a.ConfigDir)
			}
			return cmd.Run()
		},
		Active: func(context.Context) string {
			email := activeEmail()
			if email == "" {
				return ""
			}
			accs, err := st.Accounts()
			if err != nil {
				return ""
			}
			for _, a := range accs {
				if a.Email == email {
					return a.ID
				}
			}
			return ""
		},
		ActiveEmail: func(context.Context) string { return activeEmail() },
		WebFS:       web.Dist(),
		Detect:      func(context.Context) ([]detect.Detected, error) { return detect.Dirs() },
		Adopt: func(ctx context.Context, det detect.Detected, label string) (store.Account, error) {
			// AddAccount ignores a switcher's own Dir field (it takes dir as an
			// explicit param) — this throwaway Switcher exists only to carry
			// the Keychain interlock and the registry, same as newSwitcher.
			sw := &switcher.Switcher{
				Keychain: &switcher.Keychain{File: sandboxKeychain()},
				Registry: st,
				Out:      os.Stderr, // adopt transcript goes to the daemon log, not the API
			}
			res, err := sw.AddAccount(ctx, det.Dir, label, nil, "claude")
			if err != nil {
				return store.Account{}, err
			}
			return res.Account, nil
		},
	}
	license := newLicenseManager(st)
	if swErr == nil {
		sw.Out = os.Stderr // swap transcripts go to the daemon log, not the API
		kwOpts := keepWarmOpts(ver)
		d.Switch = func(ctx context.Context, id string) error {
			target, err := findAccount(st, id)
			if err != nil {
				return err
			}
			// Switch-time freshen: if the target's stored token is already
			// near expiry, refresh it now so the switch lands a live
			// credential. A TRANSIENT failure never blocks the switch (the
			// engine no-ops when the token is fresh, and Swap re-reads the
			// backup under its locks either way). A DEAD lineage does block
			// it: installing a credential we know cannot refresh would strand
			// the user on an unauthorized session — and becoming active would
			// clear the honest "sign-in expired" note (Codex P2, 2026-07-16).
			if _, err := sw.KeepWarm(ctx, target, kwOpts); err != nil {
				if errors.Is(err, switcher.ErrLineageDead) {
					return fmt.Errorf("account %q: sign-in expired — log in to it again, then `llmpilot account add`", target.Label)
				}
				slog.Warn("switch-time freshen", "account", target.ID, "err", err)
			}
			return sw.Swap(ctx, target)
		}
		d.Freshen = func(ctx context.Context, a store.Account) (bool, error) {
			return sw.FreshenBackup(ctx, switcher.Identity{ID: a.ID, Email: a.Email})
		}
		d.KeepWarm = func(ctx context.Context, a store.Account) (daemon.KeepWarmStatus, error) {
			res, err := sw.KeepWarm(ctx, a, kwOpts)
			if errors.Is(err, switcher.ErrLineageDead) {
				return daemon.KeepWarmStatus{Dead: true, Fingerprint: res.Fingerprint, Expiry: res.Expiry}, nil
			}
			if err != nil {
				return daemon.KeepWarmStatus{}, err
			}
			return daemon.KeepWarmStatus{Rotated: res.Rotated, Fingerprint: res.Fingerprint, Expiry: res.Expiry}, nil
		}
		d.Fingerprint = func(ctx context.Context, a store.Account) (string, error) {
			return sw.Fingerprint(ctx, a)
		}
		d.Pinned = accountIsPinned
	}
	// Autopilot rotation: ON by default, tuned by config.json. A corrupt
	// config is surfaced loudly and falls back to defaults — the brain never
	// dies over a settings file. The engine itself is build-selected: source
	// builds have no policy/scheduler/wake and every path says so honestly.
	cfg, cfgErr := st.Config()
	if cfgErr != nil {
		slog.Warn("config unreadable — autopilot on defaults", "err", cfgErr)
	}
	prov := pilot.Get()
	// The licensing surface is wired on every build. Source builds report
	// "unavailable" and refuse checkout; official builds sell Pro and activate
	// silently through the background poller. The daemon is the sole writer of
	// the entitlement Keychain item either way.
	d.License = &daemon.LicenseGate{
		Manager:   license,
		Client:    daemon.NewEntitlementClient(entitlementBaseURL(), license.InstallID, &http.Client{Timeout: 15 * time.Second}),
		Available: prov.Available,
	}
	if prov.Available {
		d.EntitlementAllowed = func(feature string, now time.Time) bool {
			return license.Allowed(context.Background(), feature, now)
		}
		d.EntitlementDue = func(now time.Time) bool {
			return license.Due(context.Background(), now)
		}
		d.Revalidate = func(ctx context.Context) (daemon.EntitlementValidation, error) {
			status, err := license.Revalidate(ctx)
			return daemon.EntitlementValidation{Status: status}, err
		}
		d.Pilot = prov.NewPolicy(pilotapi.ParamsFrom(cfg.Autopilot))
	}
	if os.Getenv("LLMPILOT_TEST") == "" {
		d.NotifyUser = macNotify
		if prov.Available {
			armer := prov.NewArmer(pilotapi.ArmerConfig{Store: st, Log: slog.Default()})
			d.WakeSync = armer.Sync
		}
		// Cockpit schedule writes must land in launchd too — the API syncs
		// through this before persisting (Greptile P1: without it a
		// cockpit-created schedule never fired). Sandboxed daemons leave it
		// nil: a test plist must never be bootstrapped into real launchd.
		bin, binErr := os.Executable()
		agentsDir, dirErr := pilotapi.AgentsDir()
		switch {
		case !prov.Available:
			d.TriggerSync = func(context.Context, []store.Schedule) error {
				return pilot.NotAvailable("scheduling")
			}
		case binErr != nil || dirErr != nil:
			slog.Error("launchd trigger sync UNAVAILABLE — schedule changes will be refused",
				"bin_err", binErr, "dir_err", dirErr)
			// Refuse rather than silently succeed: a mutation that saved
			// without syncing would leave launchd firing the OLD set
			// (Greptile P1 round 2, 2026-07-11).
			d.TriggerSync = func(context.Context, []store.Schedule) error {
				return fmt.Errorf("launchd sync unavailable (executable: %v, agents dir: %v) — restart the daemon", binErr, dirErr)
			}
		default:
			l := prov.NewTriggerSync(pilotapi.TriggerSyncConfig{UID: os.Getuid(), Dir: agentsDir, Out: os.Stderr})
			d.TriggerSync = func(ctx context.Context, scheds []store.Schedule) error {
				if !license.Allowed(ctx, "scheduling", time.Now()) {
					return pilot.NotLicensed("scheduling")
				}
				return l.Sync(ctx, bin, scheds, st.Home())
			}
		}
	} else {
		d.NotifyUser = func(_ context.Context, title, body string) {
			slog.Info("notification (sandbox, not shown)", "title", title, "body", body)
		}
	}
	return d
}

// activeEmail is the raw email logged into the machine-GLOBAL config dir,
// "" if none. Global on purpose: the daemon's view of "active" must not
// follow a pinned terminal's env (review P1-1).
func activeEmail() string {
	dir, err := claudecfg.GlobalDir()
	if err != nil {
		return ""
	}
	acct, err := dir.OAuthAccount()
	if err != nil || acct == nil {
		return ""
	}
	return acct.EmailAddress
}

// envWithout returns env minus every entry for key.
func envWithout(env []string, key string) []string {
	kept := make([]string, 0, len(env))
	for _, e := range env {
		if !strings.HasPrefix(e, key+"=") {
			kept = append(kept, e)
		}
	}
	return kept
}

func tokenSourceFor(a store.Account) anthropic.TokenSource {
	svc := a.KeychainService
	if svc == "" {
		svc = claudecfg.DirAt(a.ConfigDir).KeychainService()
	}
	return anthropic.FirstSource{
		&anthropic.KeychainSource{Service: svc, Keychain: sandboxKeychain()},
		&anthropic.FileSource{Path: claudecfg.DirAt(a.ConfigDir).CredentialsFilePath()},
	}
}

func expirySourceFor(a store.Account) *anthropic.KeychainSource {
	svc := a.KeychainService
	if svc == "" {
		svc = claudecfg.DirAt(a.ConfigDir).KeychainService()
	}
	return &anthropic.KeychainSource{Service: svc, Keychain: sandboxKeychain()}
}

// sandboxRefreshURL redirects the OAuth token endpoint to a local fixture
// server, honored ONLY under LLMPILOT_TEST (like sandboxUsageURL) so no env
// var can ever send a real refresh token off platform.claude.com.
func sandboxRefreshURL() string {
	if os.Getenv("LLMPILOT_TEST") == "" {
		return ""
	}
	return os.Getenv("LLMPILOT_REFRESH_URL")
}

// globalDirPath is the machine-global config dir (the swap-managed slot),
// matching newGlobalSwitcher. "" only when the home dir can't be resolved.
func globalDirPath() string {
	dir, err := claudecfg.GlobalDir()
	if err != nil {
		return ""
	}
	return dir.Path()
}

// accountIsPinned reports whether a lives in its own config dir (its live
// credential is in its own Keychain service) rather than the global slot.
func accountIsPinned(a store.Account) bool {
	return a.ConfigDir != "" && claudecfg.DirAt(a.ConfigDir).Path() != globalDirPath()
}

// daemonTokenSource selects the credential source for polling a's usage. A
// GLOBAL-dir account that is currently idle is read from its BACKUP, not the
// global Keychain slot (which holds the ACTIVE account's credential) — that
// misattribution is what blinded idle accounts on the dashboard. Active and
// pinned accounts read their own live credential.
func daemonTokenSource(sw *switcher.Switcher, a store.Account, activeEmail string) anthropic.TokenSource {
	if sw != nil && !accountIsPinned(a) && a.Email != activeEmail {
		return switcher.BackupTokenSource{Switcher: sw, AccountID: a.ID}
	}
	return tokenSourceFor(a)
}

// daemonExpirySource mirrors daemonTokenSource for the keep-warm loop's expiry
// reads — an idle global account's expiry comes from its backup, never the
// active slot.
func daemonExpirySource(sw *switcher.Switcher, a store.Account, activeEmail string) anthropic.ExpirySource {
	if sw != nil && !accountIsPinned(a) && a.Email != activeEmail {
		return switcher.BackupTokenSource{Switcher: sw, AccountID: a.ID}
	}
	return expirySourceFor(a)
}

// keepWarmOpts builds the direct-refresh options: a RefreshClient that speaks
// the OAuth token endpoint (confined to internal/anthropic) with the same
// User-Agent the usage poller sends. The endpoint/client_id live in the
// adapter; here we only inject the call.
func keepWarmOpts(ver string) switcher.KeepWarmOpts {
	return switcher.KeepWarmOpts{
		RefreshLead: daemon.DefaultRefreshLead,
		Refresh: func(ctx context.Context, refreshToken string) (anthropic.RefreshResult, error) {
			rc := &anthropic.RefreshClient{
				BaseURL:   sandboxRefreshURL(),
				UserAgent: "claude-code/" + ver,
			}
			return rc.Refresh(ctx, refreshToken)
		},
	}
}

// newDemoDaemon serves the masked demo fleet (LLMPILOT_DEMO=1) from a throwaway
// store: no Keychain, no network, no launchd. Onboarding shows the product
// working before any account is registered, and launch media render from the
// same source. Fetch/Switch/Wake stay nil so nothing polls or mutates.
func newDemoDaemon() (*daemon.Daemon, func(), error) {
	dir, err := os.MkdirTemp("", "llmpilot-demo-")
	if err != nil {
		return nil, nil, err
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	st := store.At(dir)
	active, err := daemon.SeedDemo(st, time.Now())
	if err != nil {
		cleanup()
		return nil, nil, err
	}
	d := &daemon.Daemon{
		Store:   st,
		Log:     slog.Default(),
		WebFS:   web.Dist(),
		Active:  func(context.Context) string { return active },
		License: &daemon.LicenseGate{Available: false},
	}
	return d, cleanup, nil
}

func daemonCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "daemon", Short: "the always-on brain"}

	run := &cobra.Command{
		Use:   "run",
		Short: "run the daemon in the foreground",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx, stop := signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)
			defer stop()
			if os.Getenv("LLMPILOT_DEMO") == "1" {
				d, cleanup, err := newDemoDaemon()
				if err != nil {
					return err
				}
				defer cleanup()
				slog.Info("demo mode — serving the masked demo fleet, read-only")
				if err := d.Serve(ctx); err != nil && !errors.Is(err, context.Canceled) {
					return err
				}
				return nil
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			err = newDaemon(st).Serve(ctx)
			if errors.Is(err, context.Canceled) {
				return nil
			}
			return err
		},
	}

	install := &cobra.Command{
		Use:   "install",
		Short: "install the launchd agent (dev.llmpilot.daemon)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			bin, err := os.Executable()
			if err != nil {
				return err
			}
			plist, err := daemon.LaunchAgentPath()
			if err != nil {
				return err
			}
			st, err := store.Open()
			if err != nil {
				return err
			}
			if err := daemon.WriteLaunchAgent(plist, bin, st.Home()); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(),
				"launch agent written: %s\nload it now:  launchctl bootstrap gui/%d %s\nunload with:  launchctl bootout gui/%d/%s\n",
				plist, os.Getuid(), plist, os.Getuid(), daemon.LaunchAgentLabel)
			return nil
		},
	}
	cmd.AddCommand(run, install, daemonStatusCmd())
	return cmd
}
