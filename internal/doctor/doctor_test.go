package doctor_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// treeSnapshot fingerprints every path under root: name, mode, size and
// content hash. A lock dir, a rewritten budget file or a touched cache all
// show up as a difference.
func treeSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			out[rel] = fmt.Sprintf("dir mode=%v", info.Mode())
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		out[rel] = fmt.Sprintf("file mode=%v size=%d sha=%s mtime=%s",
			info.Mode(), info.Size(), hex.EncodeToString(sum[:8]), info.ModTime().UTC())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func diffTrees(t *testing.T, label string, before, after map[string]string) {
	t.Helper()
	for path, was := range before {
		now, ok := after[path]
		if !ok {
			t.Errorf("%s: the sweep DELETED %s", label, path)
			continue
		}
		if now != was {
			t.Errorf("%s: the sweep MODIFIED %s\n  before: %s\n   after: %s", label, path, was, now)
		}
	}
	for path := range after {
		if _, ok := before[path]; !ok {
			t.Errorf("%s: the sweep CREATED %s (a lock dir, a temp file or a write)", label, path)
		}
	}
}

// failingTransport fails the test on ANY outbound request. The doctor has no
// HTTP client of its own — this catches a reader that grew one.
type failingTransport struct{ t *testing.T }

func (f failingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	f.t.Errorf("the sweep issued an HTTP request to %s — the doctor never touches the network", r.URL)
	return nil, errors.New("no network in the doctor")
}

// TestDoctorIsReadOnly is the load-bearing proof: a full sweep over a
// fleet with EVERY finding class armed leaves the sandbox byte-identical
// (no write, no lock dir, no refresh-budget charge), shells out to no
// Keychain, and issues no HTTP request. A refresher that fires would have to
// pass through one of those three traps.
func TestDoctorIsReadOnly(t *testing.T) {
	f := armedFleet(t)

	realTransport := http.DefaultTransport
	realClient := http.DefaultClient.Transport
	http.DefaultTransport = failingTransport{t}
	http.DefaultClient.Transport = failingTransport{t}
	t.Cleanup(func() {
		http.DefaultTransport = realTransport
		http.DefaultClient.Transport = realClient
	})

	// The refresh trap is the fixture's Keychain runner: every path that could
	// refresh a token goes through `/usr/bin/security`, and armedFleet's runner
	// fails the test on any invocation. Together with the tree fingerprint (a
	// charged budget rewrites refresh-budget.json) and the transport above,
	// a refresh cannot happen without failing this test.
	homeBefore := treeSnapshot(t, f.home)
	cfgBefore := treeSnapshot(t, filepath.Dir(f.fleetDir))
	budgetBefore, err := f.sw.BudgetSnapshot()
	if err != nil {
		t.Fatal(err)
	}

	rep := doctor.Run(context.Background(), f.inputs())

	diffTrees(t, "llmpilot home", homeBefore, treeSnapshot(t, f.home))
	diffTrees(t, "claude config dirs", cfgBefore, treeSnapshot(t, filepath.Dir(f.fleetDir)))

	budgetAfter, err := f.sw.BudgetSnapshot()
	if err != nil {
		t.Fatal(err)
	}
	for id, before := range budgetBefore.Attempts {
		if len(budgetAfter.Attempts[id]) != len(before) {
			t.Errorf("the sweep charged the refresh budget for %s: %d attempts → %d",
				id, len(before), len(budgetAfter.Attempts[id]))
		}
	}
	// The lock the budget's read-modify-write cycle takes must never appear.
	if _, err := os.Stat(filepath.Join(f.home, ".budget.lock")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("the sweep took the budget lock (%v) — a read needs none", err)
	}

	// THE input that makes llmpilot want to write during a read: a corrupt
	// retirement record. store.Retirements() quarantines one by RENAMING it;
	// the doctor must use the reader that does not, so a second sweep over a
	// corrupt home still leaves every byte alone.
	corrupt := armedFleet(t)
	if err := os.WriteFile(filepath.Join(corrupt.home, "retirements.json"), []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	corruptIn := corrupt.inputs()
	corruptBefore := treeSnapshot(t, corrupt.home)
	corruptRep := doctor.Run(context.Background(), corruptIn)
	diffTrees(t, "corrupt-record home", corruptBefore, treeSnapshot(t, corrupt.home))
	if _, ok := findingsByID(corruptRep)["retirement_record_unreadable"]; !ok {
		t.Error("a corrupt retirement record was not reported — it silently became an empty record")
	}
	if checksByID(corruptRep)[doctor.CheckMigrations].State != doctor.StateNotChecked {
		t.Error("a corrupt retirement record must leave the migration check not_checked")
	}
	if corruptRep.Clean {
		t.Error("a sweep that could not read the retirement record reported a clean bill")
	}

	// ...and it still did the work: every finding class is present.
	got := findingsByID(rep)
	for _, id := range []string{
		"duplicate_identity", "shared_subscription", "signin_live_elsewhere",
		"account_frozen", "signin_rejected", "stash_waiting", "stash_dead",
		"clone_suspect", "refresh_breaker_open", "refresh_budget_spent",
		"watched_lane", "statusline_foreign",
	} {
		if _, ok := got[id]; !ok {
			t.Errorf("read-only sweep produced no %q finding — the fixture arms it", id)
		}
	}
}

// TestDoctorCollisions covers the four collision cases the wave names, ending
// with the honesty trap: an account with no stored organization id is NOT
// CHECKED, never "no collision".
func TestDoctorCollisions(t *testing.T) {
	f := armedFleet(t)
	rep := doctor.Run(context.Background(), f.inputs())
	got := findingsByID(rep)
	checks := checksByID(rep)

	// (i) two rows, one sign-in → ONE critical finding, stated as proven.
	dup, ok := got["duplicate_identity"]
	if !ok {
		t.Fatal("two accounts share an email and no duplicate finding was reported")
	}
	if dup.Severity != doctor.Critical {
		t.Errorf("duplicate identity severity = %q, want critical", dup.Severity)
	}
	if n := countByID(rep, "duplicate_identity"); n != 1 {
		t.Errorf("duplicate identity reported %d times, want exactly 1 (email and account id are the same pair)", n)
	}
	if !strings.Contains(dup.Detail, "one sign-in") {
		t.Errorf("duplicate detail must state proven identity, got %q", dup.Detail)
	}
	if want := []string{"main", "work"}; !equalStrings(dup.Accounts, want) {
		t.Errorf("duplicate accounts = %v, want %v", dup.Accounts, want)
	}

	// (ii) different emails, same organization → a WARNING stated as probable,
	// upgraded to corroborated because both snapshots move in lockstep.
	shared, ok := got["shared_subscription"]
	if !ok {
		t.Fatal("two accounts share an organization and no shared-subscription finding was reported")
	}
	if shared.Severity != doctor.Warning {
		t.Errorf("shared subscription severity = %q, want warning", shared.Severity)
	}
	if !strings.Contains(shared.Title, "probably share") {
		t.Errorf("shared subscription must be DECLARED, not asserted: %q", shared.Title)
	}
	if !strings.Contains(shared.Detail, "match exactly") {
		t.Errorf("lockstep snapshots must upgrade the copy with the evidence, got %q", shared.Detail)
	}
	// ...but corroborated is still not proven: the copy must never say it is.
	if !strings.Contains(shared.Detail, "not proof") {
		t.Errorf("even a corroborated shared pool must say it is not proof, got %q", shared.Detail)
	}

	// ...and without the lockstep evidence it stays merely probable.
	in := f.inputs()
	in.Snapshot = func(string) (*store.UsageSnapshot, error) { return nil, nil }
	bare := findingsByID(doctor.Run(context.Background(), in))["shared_subscription"]
	if strings.Contains(bare.Detail, "match exactly") {
		t.Errorf("with no snapshots the finding must claim no corroboration, got %q", bare.Detail)
	}
	if !strings.Contains(bare.Detail, "not proof") {
		t.Errorf("an uncorroborated shared pool must say it is not proof, got %q", bare.Detail)
	}

	// ...and one matching bucket is NOT "their limits match exactly": two
	// accounts whose weekly buckets differ are evidence against one pool.
	partial := f.inputs()
	partial.Snapshot = func(id string) (*store.UsageSnapshot, error) {
		if id != "orga" && id != "orgb" {
			return f.store.Snapshot(id)
		}
		resets := fixedNow.Add(3 * time.Hour)
		weekly := fixedNow.Add(72 * time.Hour)
		pct := 41.5
		if id == "orgb" {
			pct = 88.0 // same session bucket, DIFFERENT weekly
		}
		return &store.UsageSnapshot{AccountID: id, AsOf: fixedNow, Buckets: []store.Bucket{
			{Kind: "session", Percent: 41.5, ResetsAt: &resets},
			{Kind: "weekly_all", Percent: pct, ResetsAt: &weekly},
		}}, nil
	}
	half := findingsByID(doctor.Run(context.Background(), partial))["shared_subscription"]
	if strings.Contains(half.Detail, "match exactly") {
		t.Errorf("one matching bucket was reported as every limit matching: %q", half.Detail)
	}
	// ...nor when one account simply reports FEWER buckets: an agreeing subset
	// is not "every limit matches", it is a smaller sample.
	subset := f.inputs()
	subset.Snapshot = func(id string) (*store.UsageSnapshot, error) {
		if id != "orga" && id != "orgb" {
			return f.store.Snapshot(id)
		}
		resets := fixedNow.Add(3 * time.Hour)
		weekly := fixedNow.Add(72 * time.Hour)
		buckets := []store.Bucket{{Kind: "session", Percent: 41.5, ResetsAt: &resets}}
		if id == "orga" {
			buckets = append(buckets, store.Bucket{Kind: "weekly_all", Percent: 12, ResetsAt: &weekly})
		}
		return &store.UsageSnapshot{AccountID: id, AsOf: fixedNow, Buckets: buckets}, nil
	}
	fewer := findingsByID(doctor.Run(context.Background(), subset))["shared_subscription"]
	if strings.Contains(fewer.Detail, "match exactly") {
		t.Errorf("an agreeing SUBSET was reported as every limit matching: %q", fewer.Detail)
	}
	if !strings.Contains(half.Detail, "not proof") {
		t.Errorf("the uncorroborated finding must still say it is not proof: %q", half.Detail)
	}

	// (iii) an account whose email is signed into a folder outside the fleet
	// names that folder and offers the migration.
	elsewhere, ok := got["signin_live_elsewhere"]
	if !ok {
		t.Fatal("a fleet email is signed in outside the fleet and nothing was reported")
	}
	if !strings.Contains(elsewhere.Detail, f.foreignDir) {
		t.Errorf("the finding must name the folder, got %q", elsewhere.Detail)
	}
	if elsewhere.Remedy.Verb != doctor.VerbMoveIntoFleet || elsewhere.Remedy.Target != f.foreignDir {
		t.Errorf("remedy = %+v, want move_into_fleet targeting %s", elsewhere.Remedy, f.foreignDir)
	}
	// A folder a move already emptied is NOT reported — it keeps its identity
	// block forever, so reporting it would be a permanent false alarm.
	for _, fd := range rep.Findings {
		if strings.Contains(fd.Detail, f.retiredDir) {
			t.Errorf("a migrated, proven-empty folder was reported as a live copy: %q", fd.Detail)
		}
	}

	// (iv) THE TRAP: a row with no stored organization id is not checkable for
	// a shared subscription, and silence there must never read as "no
	// collision".
	c := checks[doctor.CheckSharedPool]
	if c.State != doctor.StateNotChecked {
		t.Fatalf("shared-subscription check state = %q, want not_checked (one account has no organization id)", c.State)
	}
	if !strings.Contains(c.Why, "noorg") {
		t.Errorf("the not-checked reason must name the account it could not check, got %q", c.Why)
	}
	if rep.Clean {
		t.Error("a report with a not-checked collision case must never be clean")
	}
}

// TestDoctorFindings walks every class the wave lists: each carries a shipped
// severity, says what happened, and offers one remedy the engine accepts.
func TestDoctorFindings(t *testing.T) {
	f := armedFleet(t)
	rep := doctor.Run(context.Background(), f.inputs())
	got := findingsByID(rep)

	cases := []struct {
		id       string
		severity doctor.Severity
		verb     string
		contains string
	}{
		{"clone_suspect", doctor.Warning, doctor.VerbSignInAgain, "refuses to refresh"},
		{"account_frozen", doctor.Warning, doctor.VerbSwitch, "expired while it sat idle"},
		{"signin_rejected", doctor.Critical, doctor.VerbSignInAgain, "cannot be revived"},
		{"stash_waiting", doctor.Info, doctor.VerbReviewStash, "belongs to no registered account"},
		{"stash_dead", doctor.Warning, doctor.VerbSignInAgain, "already dead"},
		{"refresh_breaker_open", doctor.Warning, doctor.VerbNone, "rate-limited a token refresh"},
		{"refresh_budget_spent", doctor.Info, doctor.VerbNone, "refreshes per account per day"},
		{"watched_lane", doctor.Info, doctor.VerbMoveIntoFleet, "watches its limits"},
		{"statusline_foreign", doctor.Info, doctor.VerbInstallStatusline, "settings.json runs starship."},
	}
	for _, tc := range cases {
		fd, ok := got[tc.id]
		if !ok {
			t.Errorf("%s: not reported", tc.id)
			continue
		}
		if fd.Severity != tc.severity {
			t.Errorf("%s: severity = %q, want %q", tc.id, fd.Severity, tc.severity)
		}
		if fd.Remedy.Verb != tc.verb {
			t.Errorf("%s: remedy verb = %q, want %q", tc.id, fd.Remedy.Verb, tc.verb)
		}
		if fd.Remedy.Label == "" {
			t.Errorf("%s: remedy has no label — every finding names its one verb", tc.id)
		}
		if !strings.Contains(fd.Detail, tc.contains) {
			t.Errorf("%s: detail %q does not say what happened (%q)", tc.id, fd.Detail, tc.contains)
		}
		if fd.Title == "" {
			t.Errorf("%s: no title", tc.id)
		}
	}

	// ...and the arguments that named it never reach the payload. A statusline
	// command is arbitrary user content on an unguarded endpoint, and people do
	// put keys in argv.
	blob := fmt.Sprintf("%+v", rep)
	if strings.Contains(blob, argvSecret) {
		t.Error("a secret from a foreign statusline command's arguments reached the report")
	}
	if strings.Contains(blob, "--api-key") {
		t.Error("a foreign command's arguments were republished")
	}
	if strings.Contains(blob, "/usr/local/bin") {
		t.Error("a foreign command's path was republished — the name is all the copy needs")
	}
	// An unparseable statusline value yields a NAME or nothing, never a blob.
	unparsedIn := f.inputs()
	unparsedIn.Install = func() (doctor.InstallFacts, error) {
		return doctor.InstallFacts{
			LaunchAgentInstalled: true,
			StatusLine:           doctor.StatusLineForeign,
			StatusLineOwner:      `{"type":"command","command":"x","token":"` + argvSecret + `"}`,
		}, nil
	}
	unparsed := fmt.Sprintf("%+v", doctor.Run(context.Background(), unparsedIn))
	if strings.Contains(unparsed, argvSecret) {
		t.Error("an unparseable statusline value was republished whole")
	}

	// A watched lane is a FEATURE: its copy never blames the user.
	watched := got["watched_lane"]
	for _, blame := range []string{"wrong", "mistake", "should have", "you failed", "error"} {
		if strings.Contains(strings.ToLower(watched.Title+watched.Detail), blame) {
			t.Errorf("the watched-lane copy implies the user erred: %q / %q", watched.Title, watched.Detail)
		}
	}
	// ...and a WATCHED account that is also frozen must not be offered a
	// switch the engine refuses.
	in := f.inputs()
	in.Daemon.Stale = map[string]bool{"alt": true}
	pinnedFrozen := findingsByID(doctor.Run(context.Background(), in))["account_frozen"]
	if pinnedFrozen.Remedy.Verb != doctor.VerbNone {
		t.Errorf("a pinned frozen account was offered %q — the engine refuses a pinned switch target", pinnedFrozen.Remedy.Verb)
	}

	// Severities come from the shipped vocabulary; nothing else is allowed.
	for _, fd := range rep.Findings {
		switch fd.Severity {
		case doctor.Critical, doctor.Warning, doctor.Info:
		default:
			t.Errorf("%s: severity %q is outside the shipped vocabulary", fd.ID, fd.Severity)
		}
		if fd.Accounts == nil {
			t.Errorf("%s: Accounts is nil — every list on the wire is never null", fd.ID)
		}
	}

	// Ranking: critical first, then warning, then notes.
	last := -1
	for _, fd := range rep.Findings {
		rank := map[doctor.Severity]int{doctor.Critical: 0, doctor.Warning: 1, doctor.Info: 2}[fd.Severity]
		if rank < last {
			t.Errorf("findings are not ranked by severity: %s (%s) came after rank %d", fd.ID, fd.Severity, last)
		}
		last = rank
	}

	// Install gaps: a missing launch agent is a warning, an unreadable one is
	// NOT CHECKED — never silently fine.
	in = f.inputs()
	in.Install = func() (doctor.InstallFacts, error) {
		return doctor.InstallFacts{StatusLine: doctor.StatusLineOurs}, nil
	}
	missing := doctor.Run(context.Background(), in)
	if _, ok := findingsByID(missing)["login_item_missing"]; !ok {
		t.Error("no launch agent and no finding — llmpilot would silently stop at logout")
	}
	in.Install = func() (doctor.InstallFacts, error) {
		return doctor.InstallFacts{
			LaunchAgentErr: "permission denied", StatusLineErr: "settings.json unreadable",
		}, nil
	}
	unreadable := checksByID(doctor.Run(context.Background(), in))
	if unreadable[doctor.CheckLoginItem].State != doctor.StateNotChecked {
		t.Error("an unreadable login item must report not_checked, not pass")
	}
	if unreadable[doctor.CheckStatusLine].State != doctor.StateNotChecked {
		t.Error("an unreadable statusline must report not_checked, not pass")
	}

	// A clean fleet earns the all-clear — and it names what was checked.
	clean := doctor.Run(context.Background(), cleanInputs(t))
	if !clean.Clean {
		t.Errorf("a clean fleet did not earn the all-clear: %+v", clean.Findings)
	}
	if clean.Problems != 0 {
		t.Errorf("clean report counts %d problems", clean.Problems)
	}
	for _, c := range clean.Checks {
		if c.State == doctor.StateNotChecked {
			t.Errorf("clean report has an unchecked item: %s (%s)", c.ID, c.Why)
		}
	}
	if len(clean.Checks) == 0 {
		t.Error("the all-clear must name what was checked")
	}

	// THE RULE: a partial sweep may never render as a clean bill. Take the
	// clean fleet, blind ONE check, and the all-clear is gone even though
	// there is not a single problem to report.
	partial := cleanInputs(t)
	partial.Budget = func() (switcher.BudgetSnapshot, error) {
		return switcher.BudgetSnapshot{}, errors.New("budget file unreadable")
	}
	rep2 := doctor.Run(context.Background(), partial)
	if rep2.Problems != 0 {
		t.Fatalf("the partial fleet has problems (%d) — this case must isolate not-checked", rep2.Problems)
	}
	if rep2.Clean {
		t.Error("a sweep with an unchecked item reported a clean bill — that is the false all-clear this guard exists to prevent")
	}
	if checksByID(rep2)[doctor.CheckRefreshBudget].Why == "" {
		t.Error("not_checked without a reason")
	}
}

// TestDoctorRefusesVerbsTheEngineRefuses covers the review's sharpest class:
// a remedy button that would 409. A rejected sign-in cannot be switched to, an
// unreadable stash cannot be called empty, and an unknown pinned rule cannot be
// treated as "switchable".
func TestDoctorRefusesVerbsTheEngineRefuses(t *testing.T) {
	f := armedFleet(t)

	// A frozen account whose lineage the token endpoint REJECTED: the only
	// honest remedy is a fresh sign-in, and the switch that would 409 (after
	// spending a refresh attempt) must not be offered.
	in := f.inputs()
	in.Daemon.Stale = map[string]bool{"dead": true}
	rep := doctor.Run(context.Background(), in)
	for _, fd := range rep.Findings {
		if fd.ID == "account_frozen" && len(fd.Accounts) > 0 && fd.Accounts[0] == "dead" {
			t.Errorf("a rejected sign-in was also reported as merely frozen, remedy %+v", fd.Remedy)
		}
	}
	rejected := findingsByID(rep)["signin_rejected"]
	if rejected.Remedy.Verb != doctor.VerbSignInAgain {
		t.Errorf("rejected sign-in remedy = %q, want sign_in_again", rejected.Remedy.Verb)
	}

	// With no pinned rule wired the sweep cannot tell a watched lane from a
	// switchable one: it says so, and offers no switch it cannot vouch for.
	in = f.inputs()
	in.Pinned = nil
	in.Daemon.Stale = map[string]bool{"alt": true}
	rep = doctor.Run(context.Background(), in)
	if checksByID(rep)[doctor.CheckWatchedLanes].State != doctor.StateNotChecked {
		t.Error("with no pinned rule, watched lanes must report not_checked, not pass")
	}
	if v := findingsByID(rep)["account_frozen"].Remedy.Verb; v != doctor.VerbNone {
		t.Errorf("with no pinned rule the frozen remedy = %q, want none (the target may be unswitchable)", v)
	}
	if rep.Clean {
		t.Error("a sweep that could not tell watched lanes apart reported a clean bill")
	}

	// An unreadable stash is NOT an empty stash: a dead kept sign-in would
	// otherwise vanish into an all-clear.
	clean := cleanInputs(t)
	clean.Daemon = &doctor.DaemonFacts{StashErr: "llmpilot could not read the sign-ins it kept from switching"}
	rep = doctor.Run(context.Background(), clean)
	if checksByID(rep)[doctor.CheckKeptSignIns].State != doctor.StateNotChecked {
		t.Error("an unreadable stash rendered as checked-and-fine")
	}
	if rep.Clean {
		t.Error("an unreadable stash still earned the all-clear")
	}

	// A live daemon that cannot serve a report is not a daemon that is down —
	// telling that user to start one is the same lie pointed the other way.
	skew := cleanInputs(t)
	skew.Daemon = nil
	skew.DaemonUnreachable = "A daemon is running, but it could not serve a health report."
	rep = doctor.Run(context.Background(), skew)
	got := findingsByID(rep)
	if _, ok := got["daemon_down"]; ok {
		t.Error("a running daemon was reported as not running")
	}
	if _, ok := got["daemon_unreachable"]; !ok {
		t.Fatal("a daemon that answered but served nothing was not reported at all")
	}
}

// TestDoctorCoverageIsHonest pins the coverage half of the honesty rule for
// the checks whose readers can half-run.
func TestDoctorCoverageIsHonest(t *testing.T) {
	// Two accounts with DIFFERENT emails can still be one Claude account —
	// only the stored identity says so. With it unreadable, the duplicate
	// check ran only half and must say which accounts it could not compare.
	in := cleanInputs(t)
	in.Backups = nil
	rep := doctor.Run(context.Background(), in)
	c := checksByID(rep)[doctor.CheckDuplicates]
	if c.State != doctor.StateNotChecked {
		t.Errorf("duplicate check = %q with unreadable identities, want not_checked", c.State)
	}
	if !strings.Contains(c.Why, "solo") {
		t.Errorf("the reason must name the accounts it could not compare, got %q", c.Why)
	}
	if rep.Clean {
		t.Error("a half-run duplicate check still earned the all-clear")
	}
}

// TestDoctorReadsOnlyOwnKeychain proves the ACL-prompt rule: the sweep asks
// for llmpilot's own backup service and nothing else, and still produces its
// findings.
func TestDoctorReadsOnlyOwnKeychain(t *testing.T) {
	f := armedFleet(t)
	rep := doctor.Run(context.Background(), f.inputs())

	if len(f.keychain.saw) == 0 {
		t.Fatal("the sweep read no Keychain item at all — the identity checks would be vacuous")
	}
	for _, call := range f.keychain.saw {
		service, _, _ := strings.Cut(call, "/")
		if service != switcher.BackupService {
			t.Errorf("the sweep read Keychain service %q", service)
		}
	}
	if len(rep.Findings) == 0 {
		t.Fatal("the sweep produced no findings")
	}
	// The identity-derived findings are exactly the ones that need the
	// Keychain — they must be present, from our own service only.
	got := findingsByID(rep)
	if _, ok := got["duplicate_identity"]; !ok {
		t.Error("no duplicate finding — the identity read did not happen")
	}
	if _, ok := got["shared_subscription"]; !ok {
		t.Error("no shared-subscription finding — the identity read did not happen")
	}

	// No credential byte from the payload reaches the report, in any field.
	blob := fmt.Sprintf("%+v", rep)
	if strings.Contains(blob, credentialMarker) {
		t.Error("a credential byte from the backup payload reached the report")
	}
	for _, fd := range rep.Findings {
		for _, secret := range []string{"fp-live", "fp-dead"} {
			if strings.Contains(fd.Title+fd.Detail+fd.Remedy.Target, secret) {
				t.Errorf("%s: a stash fingerprint reached the payload", fd.ID)
			}
		}
	}

	// An unreadable backup is NOT CHECKED, never "no collision".
	in := f.inputs()
	in.Backups = nil
	blind := doctor.Run(context.Background(), in)
	if checksByID(blind)[doctor.CheckSharedPool].State != doctor.StateNotChecked {
		t.Error("with no readable identities the collision check must report not_checked")
	}
	if blind.Clean {
		t.Error("a sweep that could not read identities must never be clean")
	}
}

// TestDoctorDegraded is the daemon-down half of the honesty rule, asserted
// here at the engine (the CLI and endpoint halves live in their own packages).
func TestDoctorDegraded(t *testing.T) {
	f := armedFleet(t)
	in := f.inputs()
	in.Daemon = nil
	rep := doctor.Run(context.Background(), in)

	got := findingsByID(rep)
	if len(rep.Findings) == 0 || rep.Findings[0].ID != "daemon_down" {
		t.Fatalf("the daemon being down must be the FIRST finding, got %+v", rep.Findings)
	}
	if got["daemon_down"].Severity != doctor.Critical {
		t.Errorf("daemon down severity = %q, want critical", got["daemon_down"].Severity)
	}
	for _, id := range []string{doctor.CheckFrozen, doctor.CheckDeadSignIns, doctor.CheckKeptSignIns} {
		c := checksByID(rep)[id]
		if c.State != doctor.StateNotChecked {
			t.Errorf("%s: state = %q with the daemon down, want not_checked", id, c.State)
		}
		if c.Why == "" {
			t.Errorf("%s: not_checked with no reason", id)
		}
	}
	// The daemon-only classes must NOT be reported as absent.
	for _, id := range []string{"account_frozen", "signin_rejected", "stash_waiting", "stash_dead"} {
		if _, ok := got[id]; ok {
			t.Errorf("%s was reported with the daemon down — the sweep cannot know it", id)
		}
	}
	if rep.Clean {
		t.Error("a degraded sweep must never be clean")
	}
}

// cleanInputs is a fleet with nothing wrong: one account, a whole identity, a
// live daemon, an installed statusline. It is what the all-clear must be
// earnable on — and it is deliberately built from the SAME engine, so a check
// that fires spuriously fails here first.
func cleanInputs(t *testing.T) doctor.Inputs {
	t.Helper()
	home := t.TempDir()
	st := store.At(home)
	acct := store.Account{ID: "solo", Label: "solo", Email: "solo@example.dev", ConfigDir: filepath.Join(home, ".claude")}
	if err := st.SaveAccounts([]store.Account{acct}); err != nil {
		t.Fatal(err)
	}
	kc := &fakeKeychain{t: t, items: map[string][]byte{}}
	f := &fleet{t: t, keychain: kc}
	f.backup("solo", identityFor("solo"))
	return doctor.Inputs{
		Now:         func() time.Time { return fixedNow },
		Accounts:    st.Accounts,
		Snapshot:    st.Snapshot,
		Retirements: st.RetirementsSnapshot, // the non-writing reader, as production wires it
		Backups:     kc,
		Foreign:     func(context.Context) ([]switcher.ForeignSignIn, error) { return nil, nil },
		MovedDirs:   func(context.Context) (map[string]bool, error) { return map[string]bool{}, nil },
		Budget:      func() (switcher.BudgetSnapshot, error) { return switcher.BudgetSnapshot{}, nil },
		Pinned:      func(store.Account) bool { return false },
		Install: func() (doctor.InstallFacts, error) {
			return doctor.InstallFacts{LaunchAgentInstalled: true, StatusLine: doctor.StatusLineOurs}, nil
		},
		SetupTokens: func() ([]setuptoken.Meta, error) { return nil, nil },
		Daemon:      &doctor.DaemonFacts{},
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	x, y := append([]string{}, a...), append([]string{}, b...)
	sort.Strings(x)
	sort.Strings(y)
	for i := range x {
		if x[i] != y[i] {
			return false
		}
	}
	return true
}

// TestDoctorSetupTokens covers the headless-token reminder: expiring and
// expired tokens warn with the ONE-command remedy, a healthy one is quiet,
// and every failure to read — corrupt, erroring, UNWIRED — is NOT CHECKED,
// never "no tokens". WIRE PRIVACY: findings carry counts, never a label.
func TestDoctorSetupTokens(t *testing.T) {
	tok := func(label string, days int) setuptoken.Meta {
		return setuptoken.Meta{
			Label:     label,
			CreatedAt: fixedNow.Add(time.Duration(days-365) * 24 * time.Hour),
			ExpiresAt: fixedNow.Add(time.Duration(days) * 24 * time.Hour),
		}
	}
	base := func(tokens []setuptoken.Meta, err error) doctor.Inputs {
		in := cleanInputs(t)
		in.SetupTokens = func() ([]setuptoken.Meta, error) { return tokens, err }
		return in
	}

	t.Run("expiring token warns with days and the one-command remedy", func(t *testing.T) {
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{tok("github-actions-prod", 12)}, nil))
		f, ok := findingsByID(rep)["setup_token_expiring"]
		if !ok {
			t.Fatalf("no expiring finding: %+v", rep.Findings)
		}
		if f.Severity != doctor.Warning {
			t.Errorf("severity = %s, want warning", f.Severity)
		}
		if !strings.Contains(f.Detail, "12 day") {
			t.Errorf("detail must say how soon: %s", f.Detail)
		}
		if f.Remedy.Command != "llmpilot token list" {
			t.Errorf("remedy command = %q, want exactly `llmpilot token list`", f.Remedy.Command)
		}
		if f.Remedy.Verb != doctor.VerbNone {
			t.Errorf("remedy verb = %q — a new verb would render an inert button (closed union)", f.Remedy.Verb)
		}
		if rep.Clean {
			t.Error("an expiring CI token is a problem; the report may not be clean")
		}
	})

	t.Run("expired token warns", func(t *testing.T) {
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{tok("old", -3)}, nil))
		f, ok := findingsByID(rep)["setup_token_expired"]
		if !ok {
			t.Fatalf("no expired finding: %+v", rep.Findings)
		}
		if f.Severity != doctor.Warning {
			t.Errorf("severity = %s, want warning", f.Severity)
		}
	})

	t.Run("healthy token is quiet and the check RAN", func(t *testing.T) {
		// StateOK is open()'s DEFAULT, so asserting it alone would pass even
		// if checkSetupTokens were deleted from Run (adversarial review P2:
		// vacuous default-state assertions). The canary proves the check
		// consumed the reader.
		read := 0
		in := cleanInputs(t)
		in.SetupTokens = func() ([]setuptoken.Meta, error) { read++; return []setuptoken.Meta{tok("fresh", 300)}, nil }
		rep := doctor.Run(context.Background(), in)
		if read == 0 {
			t.Fatal("the setup-token reader was never called — the check did not run")
		}
		if _, ok := findingsByID(rep)["setup_token_expiring"]; ok {
			t.Error("a token 300 days out fired the 30-day reminder")
		}
		if c := checksByID(rep)[doctor.CheckSetupTokens]; c.State != doctor.StateOK {
			t.Errorf("check state = %s, want ok", c.State)
		}
	})

	t.Run("no tokens at all is ok — the check ran and found nothing", func(t *testing.T) {
		read := 0
		in := cleanInputs(t)
		in.SetupTokens = func() ([]setuptoken.Meta, error) { read++; return nil, nil }
		rep := doctor.Run(context.Background(), in)
		if read == 0 {
			t.Fatal("the setup-token reader was never called — the check did not run")
		}
		if c := checksByID(rep)[doctor.CheckSetupTokens]; c.State != doctor.StateOK {
			t.Errorf("check state = %s, want ok", c.State)
		}
	})

	t.Run("a token in the (-24h,0] window is EXPIRED, not expiring", func(t *testing.T) {
		// Truncated day-math held this window at "0 days left" — for a full
		// day after a CI token died, the reminder said it had not.
		past := setuptoken.Meta{Label: "lapsed", ExpiresAt: fixedNow.Add(-12 * time.Hour)}
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{past}, nil))
		if _, ok := findingsByID(rep)["setup_token_expired"]; !ok {
			t.Fatal("a token 12h past its declared expiry did not report as expired")
		}
		if _, ok := findingsByID(rep)["setup_token_expiring"]; ok {
			t.Error("a lapsed token also fired the expiring reminder")
		}
	})

	t.Run("soonest is order-independent and a today-expiry is not the sentinel", func(t *testing.T) {
		today := setuptoken.Meta{Label: "today", ExpiresAt: fixedNow.Add(12 * time.Hour)}
		five := tok("five", 5)
		for _, order := range [][]setuptoken.Meta{{today, five}, {five, today}} {
			rep := doctor.Run(context.Background(), base(order, nil))
			f, ok := findingsByID(rep)["setup_token_expiring"]
			if !ok {
				t.Fatal("no expiring finding")
			}
			if !strings.Contains(f.Detail, "0 days") {
				t.Errorf("soonest must be the today-token regardless of order: %s", f.Detail)
			}
		}
	})

	t.Run("the 30-day boundary fires at 30 and not at 31", func(t *testing.T) {
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{tok("edge", 30)}, nil))
		if _, ok := findingsByID(rep)["setup_token_expiring"]; !ok {
			t.Error("a token exactly 30 days out must fire the reminder")
		}
		rep = doctor.Run(context.Background(), base([]setuptoken.Meta{tok("outside", 31)}, nil))
		if _, ok := findingsByID(rep)["setup_token_expiring"]; ok {
			t.Error("a token 31 days out must not fire the reminder")
		}
	})

	t.Run("a hand-edited far-future expiry does not wrap into a warning", func(t *testing.T) {
		// days×24h overflowed int64 past ~292 years and wrapped negative,
		// reporting a year-3000 token as expiring this month (re-review N3).
		absurd := setuptoken.Meta{Label: "forged", ExpiresAt: fixedNow.AddDate(974, 0, 0)}
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{absurd}, nil))
		if _, ok := findingsByID(rep)["setup_token_expiring"]; ok {
			t.Error("a far-future expiry fired the 30-day reminder — duration math wrapped")
		}
		if _, ok := findingsByID(rep)["setup_token_expired"]; ok {
			t.Error("a far-future expiry reported as expired")
		}
	})

	t.Run("corrupt records are NOT CHECKED and deny the all-clear", func(t *testing.T) {
		rep := doctor.Run(context.Background(), base(nil, errors.New("parse /Users/someone/.llmpilot/setup-tokens.json: unexpected end of JSON input")))
		c := checksByID(rep)[doctor.CheckSetupTokens]
		if c.State != doctor.StateNotChecked {
			t.Fatalf("check state = %s, want not_checked — an unreadable record must never read as \"no tokens\"", c.State)
		}
		// WIRE PRIVACY extends to the coverage list: the reader's error
		// carries the records' absolute path (a username), and Check.Why
		// rides the same unguarded endpoint as Findings. Exact-match: a
		// contains-no-slash check would let a reintroduced %v slip whenever
		// the error happened to carry no path.
		if want := "llmpilot could not read its setup-token records — setup-tokens.json is unreadable or does not parse"; c.Why != want {
			t.Errorf("Check.Why must be the fixed path-free sentence, got: %s", c.Why)
		}
		if rep.Clean {
			t.Error("a sweep with an unreadable token record printed a clean bill")
		}
	})

	t.Run("an unwired reader is NOT CHECKED, never no-tokens", func(t *testing.T) {
		in := cleanInputs(t)
		in.SetupTokens = nil
		rep := doctor.Run(context.Background(), in)
		c := checksByID(rep)[doctor.CheckSetupTokens]
		if c.State != doctor.StateNotChecked {
			t.Fatalf("check state = %s, want not_checked", c.State)
		}
		if rep.Clean {
			t.Error("an unwired reader earned a clean bill")
		}
	})

	t.Run("wire privacy: findings carry counts, never a label or token bytes", func(t *testing.T) {
		rep := doctor.Run(context.Background(), base([]setuptoken.Meta{
			tok("github-actions-prod", 12), tok("sk-ant-oat01-NEVER-A-LABEL", -1),
		}, nil))
		for _, f := range rep.Findings {
			if f.Check != doctor.CheckSetupTokens {
				continue
			}
			blob, err := json.Marshal(f)
			if err != nil {
				t.Fatal(err)
			}
			for _, leak := range []string{"github-actions-prod", "sk-ant-oat01"} {
				if strings.Contains(string(blob), leak) {
					t.Errorf("a setup-token finding carries %q on the unguarded wire: %s", leak, blob)
				}
			}
			if len(f.Accounts) != 0 {
				t.Errorf("a setup-token finding names accounts: %v", f.Accounts)
			}
		}
	})
}
