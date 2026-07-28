// Package doctor answers one question honestly: is this fleet actually
// working? It runs a read-only sweep over everything llmpilot already knows —
// the registry, its own backups, the retirement record, the refresh budget,
// the daemon's live view, and the install — and returns a ranked list of
// findings, each naming what happened and the one verb that fixes it.
//
// Three rules shape every line of this package:
//
//  1. The doctor only ever LOOKS. It never writes a file, takes a lock,
//     refreshes a token, charges the refresh budget or dials the network.
//     Every input is an injected READER, so the property is structural and
//     TestDoctorIsReadOnly proves it against a real sandbox tree.
//  2. NOT CHECKED is a first-class result. A sweep that could not run a check
//     says so, names why, and can never report a clean bill — a false
//     all-clear is the worst thing this package could ship.
//  3. Declared is not proven. The same email (or the same account UUID) is
//     PROOF of one identity; a shared organization UUID only SUGGESTS one
//     subscription pool. The copy always says which one it is.
//
// Keychain posture: the sweep reads llmpilot's OWN backup service and nothing
// else — an authorization dialog at 02:00 is a product failure, and a
// diagnostic that provokes one is worse than useless. The one question about
// a foreign folder ("did a move empty it?") is answered by the caller's
// injected MovedDirs reader — the clone guard's own check: an attribute-only
// `security dump-keychain` (no -d, so no authorization dialog can fire) plus a
// key-presence read of that folder's credentials file. This package issues
// neither call itself, and asks the question at all only when a migration
// exists to re-check.
package doctor

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// Severity reuses the SHIPPED vocabulary (web/src/board/severity.ts maps
// "critical" and "warning" onto the design system's reserved meaning colors).
// This package invents no new severity and no new hue.
type Severity string

const (
	// Critical: the fleet is not doing its job right now.
	Critical Severity = "critical"
	// Warning: something will bite, or already limits what llmpilot can do.
	Warning Severity = "warning"
	// Info: a fact worth knowing that is not a problem — a pinned lane is a
	// FEATURE, and its finding never implies the user did something wrong.
	Info Severity = "info"
)

func severityRank(s Severity) int {
	switch s {
	case Critical:
		return 0
	case Warning:
		return 1
	default:
		return 2
	}
}

// Remedy is the ONE verb that resolves a finding. Verb is a machine key every
// surface maps to a control the engine already accepts (never a new one);
// Command is the CLI equivalent. VerbNone means there is nothing to press —
// said out loud rather than rendering a button that would 409.
type Remedy struct {
	Verb    string `json:"verb"`
	Label   string `json:"label"`
	Target  string `json:"target,omitempty"`
	Command string `json:"command,omitempty"`
}

// The remedy verbs. Every one of these maps to a verb that already exists:
// nothing here asks a surface to invent a control the engine would refuse.
const (
	VerbNone              = "none"               // nothing to press; Label says why
	VerbMoveIntoFleet     = "move_into_fleet"    // POST /v1/adopt/move
	VerbSignInAgain       = "sign_in_again"      // the in-app sign-in (W12)
	VerbSwitch            = "switch"             // POST /v1/switch
	VerbReviewStash       = "review_stash"       // the kept-sign-ins panel (P2)
	VerbInstallDaemon     = "install_daemon"     // llmpilot daemon install
	VerbInstallStatusline = "install_statusline" // llmpilot statusline install
	VerbRegisterAccount   = "register_account"   // llmpilot init / adopt
)

// Finding is one problem (or one note), stated as what happened plus the one
// verb that fixes it. Accounts carries LABELS, never emails: the payload
// names accounts and folders, never a token, a fingerprint or a credential.
type Finding struct {
	ID       string   `json:"id"`
	Check    string   `json:"check"`
	Severity Severity `json:"severity"`
	Title    string   `json:"title"`
	Detail   string   `json:"detail"`
	Accounts []string `json:"accounts"`
	Remedy   Remedy   `json:"remedy"`
}

// CheckState is the honest outcome of one check.
type CheckState string

const (
	// StateOK: the check ran and found nothing wrong.
	StateOK CheckState = "ok"
	// StateFinding: the check ran and produced at least one finding.
	StateFinding CheckState = "finding"
	// StateNotChecked: the check could NOT run. Why says so in one sentence.
	// A report carrying one of these is never clean.
	StateNotChecked CheckState = "not_checked"
)

// Check is one entry in the sweep's coverage list — what was looked at, and
// whether it could be looked at. The all-clear renders this list so "no
// problems found" can never be read as "everything was checked".
type Check struct {
	ID    string     `json:"id"`
	Title string     `json:"title"`
	State CheckState `json:"state"`
	Why   string     `json:"why,omitempty"`
}

// Report is the whole sweep. Findings and Checks are NEVER null — a nil slice
// marshalled as JSON null killed a whole surface's decode once.
type Report struct {
	AsOf time.Time `json:"as_of"`
	// Clean is the all-clear, and it is deliberately hard to earn: no
	// critical or warning finding AND every check actually ran. An
	// informational finding (a watched lane, an uninstalled statusline) does
	// not deny it; a NOT-CHECKED result always does.
	Clean bool `json:"clean"`
	// Problems counts critical + warning findings — the number a surface
	// leads with.
	Problems int       `json:"problems"`
	Findings []Finding `json:"findings"`
	Checks   []Check   `json:"checks"`
}

// StatusLineState is what currently owns Claude Code's statusline.
type StatusLineState string

const (
	StatusLineUnknown StatusLineState = ""        // could not be read → not checked
	StatusLineOurs    StatusLineState = "ours"    //
	StatusLineNone    StatusLineState = "none"    //
	StatusLineForeign StatusLineState = "foreign" //
)

// InstallFacts is the local install health. The caller gathers it (the
// LaunchAgent path lives in internal/daemon and the statusline classifier in
// internal/cli, neither of which this package may import), so both callers
// share ONE gatherer rather than two that could drift.
type InstallFacts struct {
	LaunchAgentInstalled bool
	LaunchAgentPath      string
	// LaunchAgentErr / StatusLineErr non-empty mean the fact could not be
	// read: the check reports NOT CHECKED with this sentence, never "fine".
	LaunchAgentErr string
	StatusLine     StatusLineState
	// StatusLineOwner is the foreign command string, so the copy can name
	// whose line it is instead of accusing the user of nothing in particular.
	StatusLineOwner string
	StatusLineErr   string
}

// DaemonFacts are the things ONLY a live daemon knows: its in-memory stale
// map, its token notes, its quarantine and the stash it serves. A nil
// *DaemonFacts means the daemon is down — every check that needs it reports
// NOT CHECKED, and the sweep leads with the daemon finding itself.
type DaemonFacts struct {
	Stale       map[string]bool
	TokenNote   map[string]string
	Quarantined map[string]bool
	Stash       []pilotapi.StashEntry
	// StashErr, when non-empty, means the kept sign-ins could NOT be read (an
	// unwired or failing stash). An empty list would otherwise be
	// indistinguishable from "nothing is waiting" — and a dead kept sign-in
	// would vanish into an all-clear.
	StashErr string
}

// Keychain is the sweep's ONLY Keychain access: llmpilot's own backup
// service, read for the identity block stored beside each credential. The
// sweep never asks for another service — TestDoctorReadsOnlyOwnKeychain
// fails on any read outside it.
type Keychain interface {
	GetAccount(ctx context.Context, service, account string) ([]byte, error)
}

// Inputs is every read the sweep performs. All are optional except Accounts:
// a nil reader is not an excuse to guess — the checks that need it report NOT
// CHECKED.
type Inputs struct {
	// Now defaults to time.Now.
	Now func() time.Time

	// Accounts is the registry. nil or failing = the sweep says it cannot
	// read llmpilot's own account list, which is itself a critical finding.
	Accounts func() ([]store.Account, error)

	// Backups reads the identity block llmpilot stored beside each account's
	// credential (SaveBackup). The credential bytes in that payload are never
	// touched, never returned and never logged.
	Backups Keychain

	// Snapshot is one account's cached usage — percentages and reset stamps
	// only, the corroboration input for a shared-pool finding.
	Snapshot func(accountID string) (*store.UsageSnapshot, error)

	// Foreign lists config dirs OUTSIDE the fleet that hold a sign-in
	// (switcher.ForeignSignIns — .claude.json reads, no Keychain at all).
	Foreign func(ctx context.Context) ([]switcher.ForeignSignIn, error)

	// MovedDirs reports which folders a move retired AND that still hold no
	// sign-in (switcher.MovedDirs). Without it, a folder llmpilot migrated
	// cannot be cleared, so it is reported NOT CHECKED rather than assumed
	// empty (assuming empty is how a real second copy would go unseen).
	MovedDirs func(ctx context.Context) (map[string]bool, error)

	// Retirements is llmpilot's record of migrated folders and its
	// clone-suspect marks.
	Retirements func() (store.Retirements, error)

	// Budget is the read-only view of the refresh budget and the global 429
	// breaker. Reading it takes no lock and charges nothing.
	Budget func() (switcher.BudgetSnapshot, error)

	// Install is the local install health (LaunchAgent + statusline).
	Install func() (InstallFacts, error)

	// Pinned is the engine's own pinned rule (an account living in its own
	// config dir). nil = treat nothing as pinned.
	Pinned func(store.Account) bool

	// Daemon carries the live daemon's facts; nil means the daemon is down.
	Daemon *DaemonFacts

	// DaemonUnreachable, when set on a nil-Daemon sweep, is WHY the daemon's
	// facts are missing when the daemon is demonstrably alive (it answered,
	// but not with a health report — a version skew). Without it the report
	// would tell a user with a running daemon to start one.
	DaemonUnreachable string

	// DaemonUnreachableSeverity lets the caller grade the shape it saw: a
	// daemon that is merely BUSY is still doing its job, so it is a warning,
	// not the critical "the fleet is not working right now". Empty = critical.
	DaemonUnreachableSeverity Severity

	// RestartRemedy is what to offer for DaemonUnreachable. The caller supplies
	// the whole remedy because the shapes differ: a stale daemon needs a
	// restart (and the command that bounces a loaded agent lives in
	// internal/daemon, not here), while a merely BUSY one must never be handed
	// a hard kill. Zero value = no remedy is offered at all, which is honest;
	// pointing at a command that does nothing is not.
	RestartRemedy Remedy

	// SetupTokens reads the stored headless-token records (metadata only —
	// this check never touches the token Keychain service). nil or failing =
	// NOT CHECKED, never "no tokens": an expiring CI token that vanishes into
	// an all-clear breaks a pipeline a year after anyone thought about it.
	SetupTokens func() ([]setuptoken.Meta, error)
}

// Check IDs — stable keys every surface can key off.
const (
	CheckDaemon        = "daemon"
	CheckLoginItem     = "login_item"
	CheckStatusLine    = "statusline"
	CheckFleet         = "fleet"
	CheckDuplicates    = "duplicate_accounts"
	CheckSharedPool    = "shared_subscription"
	CheckOtherSignIns  = "other_signins"
	CheckFrozen        = "frozen_accounts"
	CheckDeadSignIns   = "dead_signins"
	CheckKeptSignIns   = "kept_signins"
	CheckMigrations    = "migrations"
	CheckRefreshBudget = "refresh_budget"
	CheckWatchedLanes  = "watched_lanes"
	CheckSetupTokens   = "setup_tokens"
)

// daemonDown is the one sentence every daemon-only check gives as its reason,
// so the report never has two ways of saying the same thing. When the daemon
// is alive but unreachable, the reason changes with it — a report that says
// "the daemon is not running" three times under a finding that says it IS
// running is one true sentence surrounded by false ones.
const daemonDown = "the daemon is not running, so llmpilot cannot see this"

const daemonSilent = "llmpilot could not get an answer from the daemon, so it cannot see this"

func (s *sweep) daemonBlind() string {
	if s.in.DaemonUnreachable != "" {
		return daemonSilent
	}
	return daemonDown
}

// sweep accumulates one run. Checks are appended in a fixed order; findings
// are sorted by severity and then by that same order, so two runs over the
// same state print identically.
type sweep struct {
	in    Inputs
	now   time.Time
	ctx   context.Context
	items []Check
	found []Finding
	rank  map[string]int

	// The retirement record is read ONCE and shared: two checks need it, and
	// the reader is deliberately the non-rebuilding one (a rebuild renames the
	// file, and this package never writes).
	rec     store.Retirements
	recErr  error
	recRead bool
}

func (s *sweep) retirements() (store.Retirements, error) {
	if !s.recRead {
		s.recRead = true
		if s.in.Retirements == nil {
			s.recErr = errors.New("this sweep had no way to read llmpilot's record of migrated folders")
		} else {
			s.rec, s.recErr = s.in.Retirements()
		}
	}
	return s.rec, s.recErr
}

func (s *sweep) open(id, title string) {
	s.rank[id] = len(s.items)
	s.items = append(s.items, Check{ID: id, Title: title, State: StateOK})
}

func (s *sweep) at(id string) *Check { return &s.items[s.rank[id]] }

// notChecked marks a check that could not run. It never overwrites a reason
// already recorded: the first honest sentence wins.
func (s *sweep) notChecked(id, why string) {
	c := s.at(id)
	c.State = StateNotChecked
	if c.Why == "" {
		c.Why = why
	}
}

// add records a finding and flips its check to "finding" unless the check
// already reported NOT CHECKED — a check can find something AND still have
// been unable to look everywhere, and the incomplete coverage outranks.
func (s *sweep) add(f Finding) {
	if f.Accounts == nil {
		f.Accounts = []string{}
	}
	s.found = append(s.found, f)
	if c := s.at(f.Check); c.State == StateOK {
		c.State = StateFinding
	}
}

// Run performs the whole read-only sweep. It never returns an error: a reader
// that fails becomes a NOT-CHECKED result or a finding, because a sweep that
// 500s tells the user nothing about their fleet.
func Run(ctx context.Context, in Inputs) Report {
	now := time.Now()
	if in.Now != nil {
		now = in.Now()
	}
	s := &sweep{in: in, now: now, ctx: ctx, rank: map[string]int{}}

	// Check titles NAME what was looked at rather than asserting an outcome:
	// they are printed under "Checked" and under "Not checked", and a title
	// that reads as a verdict would contradict the finding right above it.
	s.open(CheckDaemon, "the daemon")
	s.open(CheckLoginItem, "the login item")
	s.open(CheckStatusLine, "Claude Code's statusline")
	s.open(CheckFleet, "registered accounts")
	s.open(CheckDuplicates, "duplicate sign-ins")
	s.open(CheckSharedPool, "shared subscriptions")
	s.open(CheckOtherSignIns, "sign-ins outside the fleet")
	s.open(CheckFrozen, "frozen accounts")
	s.open(CheckDeadSignIns, "rejected sign-ins")
	s.open(CheckKeptSignIns, "kept sign-ins")
	s.open(CheckMigrations, "migrated folders")
	s.open(CheckRefreshBudget, "the refresh budget")
	s.open(CheckWatchedLanes, "watched lanes")
	s.open(CheckSetupTokens, "setup tokens")

	accounts, accountsOK := s.loadAccounts()
	ids := identities(ctx, in, accounts)

	s.checkDaemon()
	s.checkInstall()
	if accountsOK {
		s.checkFleet(accounts)
		s.checkDuplicates(accounts, ids)
		s.checkSharedPool(accounts, ids)
		s.checkOtherSignIns(accounts)
		s.checkFrozen(accounts)
		s.checkDead(accounts)
		s.checkMigrations(accounts)
		s.checkBudget(accounts)
		s.checkWatched(accounts)
	}
	s.checkStash()
	s.checkSetupTokens()

	sort.SliceStable(s.found, func(i, j int) bool {
		a, b := s.found[i], s.found[j]
		if ra, rb := severityRank(a.Severity), severityRank(b.Severity); ra != rb {
			return ra < rb
		}
		return s.rank[a.Check] < s.rank[b.Check]
	})

	rep := Report{AsOf: now.UTC(), Findings: s.found, Checks: s.items, Clean: true}
	if rep.Findings == nil {
		rep.Findings = []Finding{}
	}
	for _, f := range rep.Findings {
		if f.Severity == Critical || f.Severity == Warning {
			rep.Problems++
			rep.Clean = false
		}
	}
	for _, c := range rep.Checks {
		if c.State == StateNotChecked {
			rep.Clean = false
		}
	}
	return rep
}

// loadAccounts reads the registry. An unreadable registry is a critical
// finding AND leaves every account-shaped check NOT CHECKED — llmpilot
// failing to read its own list must never look like an empty, healthy fleet.
func (s *sweep) loadAccounts() ([]store.Account, bool) {
	if s.in.Accounts == nil {
		s.blindWithoutAccounts("llmpilot was asked for a sweep without a way to read its account list")
		return nil, false
	}
	accs, err := s.in.Accounts()
	if err != nil {
		s.add(Finding{
			ID: "registry_unreadable", Check: CheckFleet, Severity: Critical,
			Title:  "llmpilot cannot read its own account list",
			Detail: fmt.Sprintf("Reading the registry failed: %v. Until it reads, nothing here knows which accounts exist.", err),
			Remedy: Remedy{Verb: VerbNone, Label: "Check the file llmpilot keeps its accounts in, then run this again"},
		})
		s.blindWithoutAccounts("llmpilot could not read its account list")
		return nil, false
	}
	return accs, true
}

func (s *sweep) blindWithoutAccounts(why string) {
	for _, id := range []string{
		CheckFleet, CheckDuplicates, CheckSharedPool, CheckOtherSignIns, CheckFrozen,
		CheckDeadSignIns, CheckMigrations, CheckRefreshBudget, CheckWatchedLanes,
	} {
		s.notChecked(id, why)
	}
}

// identity is what llmpilot stored beside one account's credential. Missing
// reports that the backup could not be read at all; NoOrg reports the
// LOAD-BEARING gap: organizationUuid is optional on both write paths, and an
// account without one is UNCHECKABLE for a shared subscription.
type identity struct {
	acct    *claudecfg.OAuthAccount
	missing string
}

// identities reads each account's stored identity block out of llmpilot's own
// backup service. Only the oauthAccount field is decoded — the credential in
// that payload is never touched, and nothing from it reaches a finding.
func identities(ctx context.Context, in Inputs, accounts []store.Account) map[string]identity {
	out := map[string]identity{}
	if in.Backups == nil {
		for _, a := range accounts {
			out[a.ID] = identity{missing: "llmpilot's own credential store was not readable during this sweep"}
		}
		return out
	}
	for _, a := range accounts {
		raw, err := in.Backups.GetAccount(ctx, switcher.BackupService, a.ID)
		if err != nil {
			out[a.ID] = identity{missing: fmt.Sprintf("llmpilot has no readable backup for %s", a.Label)}
			continue
		}
		var payload struct {
			OAuthAccount *claudecfg.OAuthAccount `json:"oauthAccount"`
		}
		if err := json.Unmarshal(raw, &payload); err != nil || payload.OAuthAccount == nil {
			out[a.ID] = identity{missing: fmt.Sprintf("llmpilot stored no account details for %s", a.Label)}
			continue
		}
		out[a.ID] = identity{acct: payload.OAuthAccount}
	}
	return out
}

func (s *sweep) checkDaemon() {
	if s.in.Daemon != nil {
		return
	}
	if s.in.DaemonUnreachable != "" {
		// It IS running — it just could not answer. Telling this user to start
		// a daemon they are already running is the same class of lie as a
		// false all-clear, pointed the other way.
		remedy := s.in.RestartRemedy
		if remedy.Label == "" {
			// A caller that set the reason but no remedy gets an honest "we
			// have nothing for you" — never the command that does nothing.
			remedy = Remedy{Verb: VerbNone, Label: "Nothing to press — llmpilot could not work out how to reach the daemon"}
		}
		severity := s.in.DaemonUnreachableSeverity
		if severity == "" {
			severity = Critical
		}
		s.add(Finding{
			ID: "daemon_unreachable", Check: CheckDaemon, Severity: severity,
			Title:  "llmpilot cannot read the daemon's health report",
			Detail: s.in.DaemonUnreachable + " The checks that need the daemon could not run below.",
			Remedy: remedy,
		})
		return
	}
	s.add(Finding{
		ID: "daemon_down", Check: CheckDaemon, Severity: Critical,
		Title:  "The daemon is not running",
		Detail: "Nothing is watching your accounts: no usage is being polled, no window is being caught, and the checks that need the daemon could not run below.",
		Remedy: Remedy{Verb: VerbInstallDaemon, Label: "Start the daemon", Command: "llmpilot daemon install"},
	})
}

func (s *sweep) checkInstall() {
	if s.in.Install == nil {
		s.notChecked(CheckLoginItem, "this sweep had no way to look at the login item")
		s.notChecked(CheckStatusLine, "this sweep had no way to look at Claude Code's settings")
		return
	}
	facts, err := s.in.Install()
	if err != nil {
		s.notChecked(CheckLoginItem, fmt.Sprintf("reading the install failed: %v", err))
		s.notChecked(CheckStatusLine, fmt.Sprintf("reading the install failed: %v", err))
		return
	}
	switch {
	case facts.LaunchAgentErr != "":
		s.notChecked(CheckLoginItem, facts.LaunchAgentErr)
	case !facts.LaunchAgentInstalled:
		s.add(Finding{
			ID: "login_item_missing", Check: CheckLoginItem, Severity: Warning,
			Title:  "llmpilot will not start at login",
			Detail: "There is no launch agent for the daemon, so the next time you log out the fleet stops being watched until you start it by hand.",
			Remedy: Remedy{Verb: VerbInstallDaemon, Label: "Install the daemon", Command: "llmpilot daemon install"},
		})
	}
	switch {
	case facts.StatusLineErr != "":
		s.notChecked(CheckStatusLine, facts.StatusLineErr)
	case facts.StatusLine == StatusLineUnknown:
		s.notChecked(CheckStatusLine, "llmpilot could not tell what owns Claude Code's statusline")
	case facts.StatusLine == StatusLineNone:
		s.add(Finding{
			ID: "statusline_absent", Check: CheckStatusLine, Severity: Info,
			Title:  "Claude Code is not showing your runway",
			Detail: "The statusline is not installed, so your limits are only visible here and in the cockpit.",
			Remedy: Remedy{Verb: VerbInstallStatusline, Label: "Install the statusline", Command: "llmpilot statusline install"},
		})
	case facts.StatusLine == StatusLineForeign:
		// Only the NAME of the program, never its arguments: a statusline
		// command is arbitrary user content on an unguarded endpoint, and
		// arguments are where secrets live (`mytool --api-key=…`). The name is
		// all this copy needs to tell the user whose line it is.
		owner := toolName(facts.StatusLineOwner)
		if owner == "" {
			owner = "another tool"
		}
		s.add(Finding{
			ID: "statusline_foreign", Check: CheckStatusLine, Severity: Info,
			Title:  "Another tool owns your Claude Code statusline",
			Detail: fmt.Sprintf("settings.json runs %s. llmpilot leaves it alone; the install command backs it up and can put ours above or instead of it.", owner),
			Remedy: Remedy{Verb: VerbInstallStatusline, Label: "Install the statusline", Command: "llmpilot statusline install"},
		})
	}
}

func (s *sweep) checkFleet(accounts []store.Account) {
	if len(accounts) > 0 {
		return
	}
	s.add(Finding{
		ID: "no_accounts", Check: CheckFleet, Severity: Info,
		Title:  "No accounts are registered yet",
		Detail: "llmpilot has nothing to watch or switch between until at least one Claude sign-in is registered.",
		Remedy: Remedy{Verb: VerbRegisterAccount, Label: "Register the sign-ins on this Mac", Command: "llmpilot init"},
	})
}

// checkDuplicates finds two lanes that are ONE sign-in. Same email — or the
// same account UUID in the stored identity — is PROOF, not a guess, and the
// copy says so.
func (s *sweep) checkDuplicates(accounts []store.Account, ids map[string]identity) {
	byEmail := map[string][]store.Account{}
	byUUID := map[string][]store.Account{}
	for _, a := range accounts {
		if e := strings.ToLower(strings.TrimSpace(a.Email)); e != "" {
			byEmail[e] = append(byEmail[e], a)
		}
		if id := ids[a.ID]; id.acct != nil && id.acct.AccountUUID != "" {
			byUUID[id.acct.AccountUUID] = append(byUUID[id.acct.AccountUUID], a)
		}
	}
	reported := map[string]bool{}
	report := func(group []store.Account, proof string) {
		labels := labelsOf(group)
		key := strings.Join(labels, "\x00")
		if len(group) < 2 || reported[key] {
			return
		}
		reported[key] = true
		s.add(Finding{
			ID: "duplicate_identity", Check: CheckDuplicates, Severity: Critical,
			Title: fmt.Sprintf("%s are the same Claude account", joinLabels(labels)),
			Detail: fmt.Sprintf("They are one sign-in (%s), so they share one set of limits: switching between them buys you no runway at all.",
				proof),
			Accounts: labels,
			Remedy:   Remedy{Verb: VerbNone, Label: "Keep one lane — the other cannot add runway"},
		})
	}
	for _, group := range sortedGroups(byEmail) {
		report(group, "same sign-in email")
	}
	for _, group := range sortedGroups(byUUID) {
		report(group, "same Claude account id")
	}
	// The email half always runs; the account-id half needs what llmpilot
	// stored beside the credential. Two rows with DIFFERENT emails can still
	// be one Claude account, so an unreadable identity leaves this check
	// genuinely incomplete — and the coverage list must not claim otherwise.
	var blind []string
	for _, a := range accounts {
		if ids[a.ID].acct == nil {
			blind = append(blind, a.Label)
		}
	}
	if len(blind) > 0 {
		sort.Strings(blind)
		s.notChecked(CheckDuplicates, fmt.Sprintf(
			"llmpilot could not read what it stored for %s, so it could only compare sign-in emails for %s",
			joinLabels(blind), pluralThem(len(blind))))
	}
}

func pluralThem(n int) string {
	if n == 1 {
		return "it"
	}
	return "them"
}

// checkSharedPool reports accounts that probably draw on ONE subscription:
// different sign-ins under the same organization. That is DECLARED, never
// proven — it is upgraded to corroborated only when their cached snapshots
// move in lockstep (identical percent AND identical reset instant).
//
// The load-bearing honesty trap lives here: organizationUuid is optional on
// both write paths, so an account without one is UNCHECKABLE. Reporting that
// silence as "no collision" would be a false all-clear, so the check reports
// NOT CHECKED and names the accounts it could not check.
func (s *sweep) checkSharedPool(accounts []store.Account, ids map[string]identity) {
	if len(accounts) == 0 {
		return
	}
	byOrg := map[string][]store.Account{}
	var unchecked []string
	for _, a := range accounts {
		id := ids[a.ID]
		switch {
		case id.acct == nil:
			unchecked = append(unchecked, a.Label)
		case id.acct.OrganizationUUID == "":
			unchecked = append(unchecked, a.Label)
		default:
			byOrg[id.acct.OrganizationUUID] = append(byOrg[id.acct.OrganizationUUID], a)
		}
	}
	for _, group := range sortedGroups(byOrg) {
		if len(group) < 2 {
			continue
		}
		// Same organization + same email is already the duplicate finding
		// above; only distinct sign-ins are a shared-pool question.
		if distinctEmails(group) < 2 {
			continue
		}
		labels := labelsOf(group)
		detail := fmt.Sprintf("%s sign in under the same organization, which usually means one subscription and one pool of limits. That is not proof — llmpilot reads it from what Claude stored, and it never asks the network to confirm.",
			joinLabels(labels))
		if s.lockstep(group) {
			detail = fmt.Sprintf("%s sign in under the same organization, and their cached limits currently match exactly — same percentage, same reset time. That is consistent with one shared pool, where switching between them would buy no runway. It is still not proof: llmpilot never asks the network to confirm.",
				joinLabels(labels))
		}
		s.add(Finding{
			ID: "shared_subscription", Check: CheckSharedPool, Severity: Warning,
			Title:    fmt.Sprintf("%s probably share one subscription", joinLabels(labels)),
			Detail:   detail,
			Accounts: labels,
			Remedy:   Remedy{Verb: VerbNone, Label: "Nothing to press — expect one pool of limits, not two"},
		})
	}
	if len(unchecked) > 0 {
		sort.Strings(unchecked)
		s.notChecked(CheckSharedPool, fmt.Sprintf(
			"llmpilot has no organization id stored for %s, so it cannot tell whether they share a subscription — sign in to them again to record one",
			joinLabels(unchecked)))
	}
}

// lockstep reports whether every account in the group has a cached bucket of
// the same kind at the same percentage with the same reset instant — the only
// corroboration allowed, since it costs no network call.
func (s *sweep) lockstep(group []store.Account) bool {
	if s.in.Snapshot == nil {
		return false
	}
	type key struct {
		kind, scope string
		percent     float64
		resets      string
	}
	// EVERY cached bucket has to agree, not merely one. Two accounts whose
	// five-hour windows happen to align while their weekly buckets differ are
	// evidence AGAINST one shared pool — and the sentence this gates says the
	// limits "match exactly". Corroboration is meant to be hard to earn.
	var first map[key]bool
	for _, a := range group {
		snap, err := s.in.Snapshot(a.ID)
		if err != nil || snap == nil || len(snap.Buckets) == 0 {
			return false
		}
		seen := map[key]bool{}
		for _, b := range snap.Buckets {
			if b.ResetsAt == nil {
				continue
			}
			seen[key{b.Kind, b.Scope, b.Percent, b.ResetsAt.UTC().Format(time.RFC3339)}] = true
		}
		if len(seen) == 0 {
			return false
		}
		if first == nil {
			first = seen
			continue
		}
		if len(seen) != len(first) {
			return false
		}
		for k := range seen {
			if !first[k] {
				return false
			}
		}
	}
	return len(first) > 0
}

// checkOtherSignIns surfaces what the rotation guard already computes and
// never tells anyone: an account whose sign-in is ALSO live in a folder
// outside the fleet. llmpilot refuses to refresh such an account (refreshing
// one copy kills the other), so the user sees a fleet going quietly cold with
// no explanation. Here it gets a name and the verb that resolves it.
func (s *sweep) checkOtherSignIns(accounts []store.Account) {
	if s.in.Foreign == nil {
		s.notChecked(CheckOtherSignIns, "this sweep had no way to look at the other Claude folders on this Mac")
		return
	}
	foreign, err := s.in.Foreign(s.ctx)
	if err != nil {
		s.notChecked(CheckOtherSignIns, fmt.Sprintf("looking at the other Claude folders failed: %v", err))
		return
	}
	byEmail := map[string]store.Account{}
	for _, a := range accounts {
		if e := strings.ToLower(strings.TrimSpace(a.Email)); e != "" {
			byEmail[e] = a
		}
	}
	// A folder a move retired keeps its identity block forever (llmpilot
	// never blanks a foreign folder's), so without the migrated-and-empty
	// answer every migrated folder would be reported as a live second copy
	// for the rest of time.
	rec, recErr := s.retirements()
	if recErr != nil {
		s.notChecked(CheckOtherSignIns, "llmpilot could not read its record of migrated folders, so a folder it migrated may be named below as if it were a second sign-in")
	}
	retired := map[string]bool{}
	for _, d := range rec.Dirs {
		if d.Complete {
			retired[normDir(d.ConfigDir)] = true
		}
	}
	// The migrated-and-empty question costs an attribute-only Keychain
	// enumeration in the caller (the clone guard's own question, which cannot
	// fire an authorization dialog), so it is asked ONLY when a migration
	// exists at all — no migrations, nothing to re-check.
	moved := map[string]bool{}
	movedKnown := len(retired) == 0
	switch {
	case len(retired) == 0:
	case s.in.MovedDirs == nil:
		s.notChecked(CheckOtherSignIns, "llmpilot could not re-check the folders it migrated, so a folder signed into again would not show up here")
	default:
		m, err := s.in.MovedDirs(s.ctx)
		if err != nil {
			s.notChecked(CheckOtherSignIns, fmt.Sprintf("llmpilot could not re-check the folders it migrated: %v", err))
			break
		}
		movedKnown = true
		for dir := range m {
			moved[normDir(dir)] = true
		}
	}
	sort.Slice(foreign, func(i, j int) bool { return foreign[i].Dir < foreign[j].Dir })
	for _, f := range foreign {
		acct, ok := byEmail[strings.ToLower(strings.TrimSpace(f.Email))]
		if !ok {
			continue // another sign-in on this Mac, not a second copy of ours
		}
		dir := normDir(f.Dir)
		if movedKnown && moved[dir] {
			continue // a move emptied it and it is still empty — nothing to say
		}
		if !movedKnown && retired[dir] {
			continue // covered by the NOT-CHECKED reason recorded above
		}
		s.add(Finding{
			ID: "signin_live_elsewhere", Check: CheckOtherSignIns, Severity: Warning,
			Title: fmt.Sprintf("%s is also signed in outside the fleet", acct.Label),
			Detail: fmt.Sprintf("The same sign-in is live in %s. Refreshing one copy of a sign-in kills the other, so llmpilot will not refresh %s while both exist — its numbers will drift out of date.",
				f.Dir, acct.Label),
			Accounts: []string{acct.Label},
			Remedy: Remedy{
				Verb: VerbMoveIntoFleet, Label: "Move into the fleet",
				Target: f.Dir, Command: "llmpilot open",
			},
		})
	}
}

// checkFrozen surfaces the honest stale state (P1): an account whose stored
// sign-in expired while idle is served from its last-known snapshot forever,
// and only using it wakes it.
func (s *sweep) checkFrozen(accounts []store.Account) {
	if s.in.Daemon == nil {
		s.notChecked(CheckFrozen, s.daemonBlind())
		return
	}
	for _, a := range accounts {
		if !s.in.Daemon.Stale[a.ID] {
			continue
		}
		if s.in.Daemon.Quarantined[a.ID] {
			// Claude has REJECTED this account's stored sign-in: it is not
			// merely frozen, and the rejected finding below carries the only
			// remedy that works. Reporting it here too would offer a switch
			// that cannot succeed.
			continue
		}
		remedy := Remedy{Verb: VerbSwitch, Label: "Switch to it", Target: a.ID, Command: "llmpilot switch " + a.Label}
		if s.in.Pinned == nil || s.isPinned(a) {
			// A watched lane cannot be a switch target — the engine refuses
			// it — so offering the verb here would be offering a 409. With no
			// pinned rule wired the sweep cannot tell, and an unknown target
			// gets the same conservative answer.
			remedy = Remedy{Verb: VerbNone, Label: "Use it in Claude Code to wake it"}
		}
		s.add(Finding{
			ID: "account_frozen", Check: CheckFrozen, Severity: Warning,
			Title: fmt.Sprintf("%s is showing its last known numbers", a.Label),
			Detail: "Its stored sign-in expired while it sat idle, so llmpilot froze the numbers rather than guess. " +
				"They stay frozen until the account is used or switched to — llmpilot never refreshes an idle account on a timer.",
			Accounts: []string{a.Label},
			Remedy:   remedy,
		})
	}
	// A token note that stale and quarantine do not already explain is worth
	// repeating verbatim rather than paraphrasing.
	for _, a := range accounts {
		note := s.in.Daemon.TokenNote[a.ID]
		if note == "" || s.in.Daemon.Stale[a.ID] || s.in.Daemon.Quarantined[a.ID] {
			continue
		}
		s.add(Finding{
			ID: "token_note", Check: CheckFrozen, Severity: Info,
			Title:    fmt.Sprintf("llmpilot has a note about %s", a.Label),
			Detail:   note,
			Accounts: []string{a.Label},
			Remedy:   Remedy{Verb: VerbNone, Label: "Nothing to press — the note clears itself when the account is used"},
		})
	}
}

func (s *sweep) checkDead(accounts []store.Account) {
	if s.in.Daemon == nil {
		s.notChecked(CheckDeadSignIns, s.daemonBlind())
		return
	}
	for _, a := range accounts {
		if !s.in.Daemon.Quarantined[a.ID] {
			continue
		}
		s.add(Finding{
			ID: "signin_rejected", Check: CheckDeadSignIns, Severity: Critical,
			Title: fmt.Sprintf("Claude rejected the stored sign-in for %s", a.Label),
			Detail: "llmpilot will not install or refresh it again — a rejected sign-in cannot be revived, only replaced. " +
				"Sign in to this account again and llmpilot picks it back up.",
			Accounts: []string{a.Label},
			Remedy:   Remedy{Verb: VerbSignInAgain, Label: "Sign in again", Target: a.ID, Command: "llmpilot open"},
		})
	}
}

// checkStash surfaces the sign-ins a swap preserved because it could not
// attribute them (P2). It never names a fingerprint: the stash panel already
// holds those, and this payload carries none.
func (s *sweep) checkStash() {
	if s.in.Daemon == nil {
		s.notChecked(CheckKeptSignIns, s.daemonBlind())
		return
	}
	if s.in.Daemon.StashErr != "" {
		s.notChecked(CheckKeptSignIns, s.in.Daemon.StashErr)
		return
	}
	live, dead := 0, 0
	for _, e := range s.in.Daemon.Stash {
		if e.Dead {
			dead++
			continue
		}
		live++
	}
	if live > 0 {
		s.add(Finding{
			ID: "stash_waiting", Check: CheckKeptSignIns, Severity: Info,
			Title:  fmt.Sprintf("%s waiting to be adopted or discarded", plural(live, "kept sign-in is", "kept sign-ins are")),
			Detail: "A switch found a sign-in in the shared slot that belongs to no registered account, so it kept it instead of overwriting it.",
			Remedy: Remedy{Verb: VerbReviewStash, Label: "Review kept sign-ins", Command: "llmpilot open"},
		})
	}
	if dead > 0 {
		s.add(Finding{
			ID: "stash_dead", Check: CheckKeptSignIns, Severity: Warning,
			Title:  fmt.Sprintf("%s can no longer be adopted", plural(dead, "kept sign-in", "kept sign-ins")),
			Detail: "Claude rejected the sign-in llmpilot kept, so adopting it would restore something already dead. Signing in to that account again is the only way back.",
			Remedy: Remedy{Verb: VerbSignInAgain, Label: "Sign in again", Command: "llmpilot open"},
		})
	}
}

// checkMigrations reports the bookkeeping the "Move into the fleet" migration
// leaves behind: an unproven retirement freezes refreshes for that account
// until a fresh sign-in, and a rebuilt record silently un-freezes them.
func (s *sweep) checkMigrations(accounts []store.Account) {
	rec, err := s.retirements()
	if err != nil {
		s.notChecked(CheckMigrations, fmt.Sprintf("llmpilot's record of migrated folders could not be read: %v", err))
		if errors.Is(err, store.ErrRecordUnreadable) {
			s.add(Finding{
				ID: "retirement_record_unreadable", Check: CheckMigrations, Severity: Warning,
				Title: "llmpilot cannot read its record of migrated folders",
				Detail: "That record is what keeps a folder llmpilot migrated from looking like a second live sign-in, and what remembers a migration it could not finish. " +
					"Until it reads, refreshes may be paused for accounts that came from those folders.",
				Remedy: Remedy{Verb: VerbNone, Label: "Nothing to press — signing in to an affected account again clears it"},
			})
		}
		return
	}
	labels := map[string]string{}
	for _, a := range accounts {
		labels[a.ID] = a.Label
	}
	suspects := append([]string{}, rec.CloneSuspect...)
	sort.Strings(suspects)
	for _, id := range suspects {
		label := labels[id]
		if label == "" {
			label = "an account llmpilot no longer lists"
		}
		where := ""
		for _, d := range rec.Dirs {
			if d.AccountID == id && !d.Complete {
				where = d.ConfigDir
				break
			}
		}
		detail := "A migration could not prove the old copy was gone, so llmpilot refuses to refresh this account: refreshing one copy of a sign-in kills the other."
		if where != "" {
			detail = fmt.Sprintf("A migration could not prove the copy in %s was gone, so llmpilot refuses to refresh this account: refreshing one copy of a sign-in kills the other.", where)
		}
		s.add(Finding{
			ID: "clone_suspect", Check: CheckMigrations, Severity: Warning,
			Title:    fmt.Sprintf("%s may still exist in two places", label),
			Detail:   detail + " Signing in to the account again mints a new sign-in and clears this.",
			Accounts: []string{label},
			Remedy:   Remedy{Verb: VerbSignInAgain, Label: "Sign in again", Target: id, Command: "llmpilot open"},
		})
	}
}

// checkBudget reports the two things that silently withhold a refresh: the
// per-account 2-per-24h cap and the global breaker a token-endpoint 429
// trips. Neither is anyone's fault and neither has a button — both say when
// they clear.
func (s *sweep) checkBudget(accounts []store.Account) {
	if s.in.Budget == nil {
		s.notChecked(CheckRefreshBudget, "this sweep had no way to read the refresh budget")
		return
	}
	b, err := s.in.Budget()
	if err != nil {
		s.notChecked(CheckRefreshBudget, fmt.Sprintf("the refresh budget could not be read: %v", err))
		return
	}
	if b.TrippedAt != nil {
		if clears := b.TrippedAt.Add(switcher.BreakerCooldown); clears.After(s.now) {
			s.add(Finding{
				ID: "refresh_breaker_open", Check: CheckRefreshBudget, Severity: Warning,
				Title: "Refreshes are paused for every account",
				Detail: fmt.Sprintf("Claude rate-limited a token refresh at %s, so llmpilot stopped refreshing rather than probe a limit it cannot see. Switching still works; the accounts it switches to just may not be freshened. This clears at %s.",
					localStamp(*b.TrippedAt, s.now), localStamp(clears, s.now)),
				Remedy: Remedy{Verb: VerbNone, Label: fmt.Sprintf("Nothing to press — it clears at %s", localStamp(clears, s.now))},
			})
		}
	}
	for _, a := range accounts {
		var recent []time.Time
		for _, at := range b.Attempts[a.ID] {
			if s.now.Sub(at) < switcher.RefreshBudgetWindow {
				recent = append(recent, at)
			}
		}
		if len(recent) < switcher.RefreshBudgetMax {
			continue
		}
		sort.Slice(recent, func(i, j int) bool { return recent[i].Before(recent[j]) })
		frees := recent[0].Add(switcher.RefreshBudgetWindow)
		s.add(Finding{
			ID: "refresh_budget_spent", Check: CheckRefreshBudget, Severity: Info,
			Title: fmt.Sprintf("%s has used both of its refreshes for today", a.Label),
			Detail: fmt.Sprintf("llmpilot allows %d token refreshes per account per day — refreshing more than that is what gets an account rate-limited. The next one frees at %s.",
				switcher.RefreshBudgetMax, localStamp(frees, s.now)),
			Accounts: []string{a.Label},
			Remedy:   Remedy{Verb: VerbNone, Label: fmt.Sprintf("Nothing to press — the next refresh frees at %s", localStamp(frees, s.now))},
		})
	}
}

// checkWatched names the watched (pinned) lanes. This is a FEATURE, not a
// fault: the copy says what the account is FOR and points at the verb that
// makes it switchable, and never suggests the user did something wrong.
func (s *sweep) checkWatched(accounts []store.Account) {
	if s.in.Pinned == nil {
		// Without the engine's own pinned rule the sweep cannot tell a watched
		// lane from a switchable one. Saying nothing would read as "none" —
		// and worse, the frozen remedy below would offer a switch the engine
		// refuses. Report the blind spot.
		s.notChecked(CheckWatchedLanes, "llmpilot could not work out which accounts sign in from their own folder")
		return
	}
	for _, a := range accounts {
		if !s.isPinned(a) {
			continue
		}
		s.add(Finding{
			ID: "watched_lane", Check: CheckWatchedLanes, Severity: Info,
			Title: fmt.Sprintf("%s is watched, not switchable", a.Label),
			Detail: fmt.Sprintf("It signs in from its own folder (%s), so llmpilot watches its limits and never installs it into the shared slot. Moving it into the fleet is what makes it switchable.",
				a.ConfigDir),
			Accounts: []string{a.Label},
			Remedy: Remedy{
				Verb: VerbMoveIntoFleet, Label: "Move into the fleet",
				Target: a.ConfigDir, Command: "llmpilot open",
			},
		})
	}
}

// setupTokenWarning is how close to the DECLARED expiry the reminder fires.
// A CI token dies quietly — thirty days is enough to mint and rotate without
// an incident, and short enough that the warning is news, not wallpaper.
const setupTokenWarning = 30 * 24 * time.Hour

// checkSetupTokens reminds about headless tokens nearing their declared
// 1-year expiry. WIRE PRIVACY: /v1/doctor is unguarded, so findings carry a
// COUNT and days-to-soonest-expiry only — never a label; `llmpilot token
// list` is where names live. Metadata only: this check never reads the token
// Keychain service.
func (s *sweep) checkSetupTokens() {
	if s.in.SetupTokens == nil {
		s.notChecked(CheckSetupTokens, "llmpilot's setup-token records are not wired in this build, so they could not be checked")
		return
	}
	tokens, err := s.in.SetupTokens()
	if err != nil {
		// Corrupt or unreadable is NOT "no tokens" — an expiring CI token
		// must never vanish into an all-clear behind a parse error. The
		// reader's error carries the records' absolute path (a username on
		// the unguarded wire), so the reason names the file, not the error.
		s.notChecked(CheckSetupTokens, "llmpilot could not read its setup-token records — setup-tokens.json is unreadable or does not parse")
		return
	}
	var expired, expiring int
	soonest := -1 // -1 = none seen: a token expiring TODAY is a legitimate 0
	for _, m := range tokens {
		switch {
		case m.Expired(s.now): // instants, not rounded days — (-24h,0] is expired
			expired++
		// Duration compare, never days×24h: multiplying a hand-edited
		// far-future date's day count overflows int64 and wraps negative,
		// which would report a year-3000 token as expiring this month.
		case m.ExpiresAt.Sub(s.now) <= setupTokenWarning:
			expiring++
			if days := m.DaysLeft(s.now); soonest < 0 || days < soonest {
				soonest = days
			}
		}
	}
	rotate := Remedy{
		Verb:    VerbNone,
		Label:   "Mint a new token with `claude setup-token`, then store it over the old one",
		Command: "llmpilot token list",
	}
	if expired > 0 {
		s.add(Finding{
			ID: "setup_token_expired", Check: CheckSetupTokens, Severity: Warning,
			Title: fmt.Sprintf("%s passed the declared expiry", countOf(expired, "setup token has", "setup tokens have")),
			Detail: fmt.Sprintf("A setup token lives about a year (declared by Claude Code when it was minted, not verified server-side). Anything still using %s — a CI secret, an env var — stopped working when it lapsed.",
				pluralIt(expired)),
			Remedy: rotate,
		})
	}
	if expiring > 0 {
		s.add(Finding{
			ID: "setup_token_expiring", Check: CheckSetupTokens, Severity: Warning,
			Title: fmt.Sprintf("%s within 30 days", countOf(expiring, "setup token expires", "setup tokens expire")),
			Detail: fmt.Sprintf("The soonest lapses in about %s — a declared 1-year lifetime, not server truth. Rotate it before whatever uses it fails quietly.",
				countOf(soonest, "day", "days")),
			Remedy: rotate,
		})
	}
}

func countOf(n int, singular, plural string) string {
	if n == 1 {
		return "1 " + singular
	}
	return fmt.Sprintf("%d %s", n, plural)
}

func pluralIt(n int) string {
	if n == 1 {
		return "it"
	}
	return "them"
}

func (s *sweep) isPinned(a store.Account) bool {
	return s.in.Pinned != nil && s.in.Pinned(a)
}

func labelsOf(group []store.Account) []string {
	out := make([]string, 0, len(group))
	for _, a := range group {
		out = append(out, a.Label)
	}
	sort.Strings(out)
	return out
}

func distinctEmails(group []store.Account) int {
	seen := map[string]bool{}
	for _, a := range group {
		seen[strings.ToLower(strings.TrimSpace(a.Email))] = true
	}
	return len(seen)
}

// sortedGroups returns the map's groups in a deterministic order so two
// sweeps over the same fleet print the same report.
func sortedGroups(m map[string][]store.Account) [][]store.Account {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([][]store.Account, 0, len(keys))
	for _, k := range keys {
		out = append(out, m[k])
	}
	return out
}

func joinLabels(labels []string) string {
	switch len(labels) {
	case 0:
		return ""
	case 1:
		return labels[0]
	case 2:
		return labels[0] + " and " + labels[1]
	default:
		return strings.Join(labels[:len(labels)-1], ", ") + " and " + labels[len(labels)-1]
	}
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

// localStamp renders an instant the way every other surface does: local wall
// clock, with the weekday only when it is not the sweep's own day. It takes
// the sweep's clock rather than reading time.Now, so a pinned-clock test
// renders deterministically.
func localStamp(t, now time.Time) string {
	local, ref := t.Local(), now.Local()
	if local.YearDay() == ref.YearDay() && local.Year() == ref.Year() {
		return local.Format("15:04")
	}
	return local.Format("Mon 15:04")
}

func normDir(p string) string { return strings.ToLower(filepath.Clean(p)) }

// toolName reduces a foreign statusline command to the program it runs. It
// takes the FIRST whitespace-delimited token, strips quotes and any directory,
// and bounds what is left — so an argument can never reach the payload, and a
// command that is one long unbroken token (JSON we could not parse, say)
// yields nothing rather than a blob that might carry a credential.
func toolName(cmd string) string {
	fields := strings.Fields(excerpt(cmd, 200))
	if len(fields) == 0 {
		return ""
	}
	head := strings.Trim(fields[0], `"'`+"`")
	// One unbroken token this long is not a program name; publishing it would
	// be republishing whatever it actually is.
	if len([]rune(head)) > 60 {
		return ""
	}
	name := filepath.Base(head)
	if name == "." || name == string(filepath.Separator) {
		return ""
	}
	return name
}

// excerpt bounds foreign text before it enters a finding: one line, capped
// length, control characters dropped. A diagnostic quotes what it found; it
// does not republish it.
func excerpt(s string, max int) string {
	s = strings.TrimSpace(strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, s))
	if r := []rune(s); len(r) > max {
		return strings.TrimSpace(string(r[:max])) + "…"
	}
	return s
}
