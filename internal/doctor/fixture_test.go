package doctor_test

// One fixture, every finding class armed. Every test in this package sweeps
// the SAME fleet, so a check that quietly stops firing breaks more than its
// own test — and the read-only proof runs over a fleet that exercises every
// code path rather than an empty one.

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// fixedNow pins the sweep's clock so every rendered time is deterministic.
var fixedNow = time.Date(2026, 7, 26, 14, 32, 0, 0, time.UTC)

type fleet struct {
	home       string // $LLMPILOT_HOME
	fleetDir   string // the shared (global) config dir
	altDir     string // a watched account's own dir → pinned
	foreignDir string // a sign-in outside the fleet
	retiredDir string // a folder a move retired
	store      *store.Store
	sw         *switcher.Switcher
	keychain   *fakeKeychain
	install    doctor.InstallFacts
	t          *testing.T
}

// fakeKeychain is the sweep's ONLY Keychain access. It fails the test on any
// service outside llmpilot's own backups: a diagnostic that reads a foreign
// dir's Keychain item can fire an authorization dialog, and one at 02:00 is a
// product failure.
type fakeKeychain struct {
	t     *testing.T
	items map[string][]byte
	saw   []string
}

func (f *fakeKeychain) GetAccount(_ context.Context, service, account string) ([]byte, error) {
	f.saw = append(f.saw, service+"/"+account)
	if service != switcher.BackupService {
		f.t.Fatalf("the sweep read Keychain service %q — it may only ever read %q",
			service, switcher.BackupService)
	}
	raw, ok := f.items[account]
	if !ok {
		return nil, errors.New("not found")
	}
	return raw, nil
}

// backup writes one account's stored payload the way SaveBackup does:
// credential bytes plus the identity block. The sweep must read ONLY the
// identity half — the credential here is a marker string, and any test that
// finds it in a report has caught a leak.
const credentialMarker = "CREDENTIAL-BYTES-MUST-NEVER-LEAVE-THE-KEYCHAIN"

// argvSecret stands in for what people really do put in a statusline command's
// arguments. The doctor names the PROGRAM; it never republishes what follows.
const argvSecret = "sk-ant-SECRET-IN-ARGV"

func (f *fleet) backup(accountID string, oa *claudecfg.OAuthAccount) {
	f.t.Helper()
	identity, err := json.Marshal(oa)
	if err != nil {
		f.t.Fatal(err)
	}
	payload, err := json.Marshal(map[string]any{
		"credential":   json.RawMessage(`{"accessToken":"` + credentialMarker + `"}`),
		"oauthAccount": json.RawMessage(identity),
		"saved_at":     fixedNow,
	})
	if err != nil {
		f.t.Fatal(err)
	}
	f.keychain.items[accountID] = payload
}

func writeJSON(t *testing.T, path string, v any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := store.WriteJSONAtomic(path, v); err != nil {
		t.Fatal(err)
	}
}

// signedInDir writes a config dir that LOOKS logged in: an oauthAccount block
// in .claude.json, exactly what the clone guard reads (never a credential).
func signedInDir(t *testing.T, path, email string) string {
	t.Helper()
	writeJSON(t, filepath.Join(path, ".claude.json"), map[string]any{
		"oauthAccount": map[string]string{"emailAddress": email, "accountUuid": "uuid-" + email},
	})
	return path
}

// armedFleet builds the fixture: ten accounts covering every finding class,
// a foreign sign-in, a retired folder, a spent refresh budget and an open
// breaker.
func armedFleet(t *testing.T) *fleet {
	t.Helper()
	home := t.TempDir()
	cfg := t.TempDir()
	f := &fleet{
		home:       home,
		fleetDir:   filepath.Join(cfg, ".claude"),
		altDir:     filepath.Join(cfg, ".claude-alt"),
		foreignDir: filepath.Join(cfg, ".claude-away"),
		retiredDir: filepath.Join(cfg, ".claude-moved"),
		store:      store.At(home),
		keychain:   &fakeKeychain{t: t, items: map[string][]byte{}},
		t:          t,
	}
	signedInDir(t, f.fleetDir, "main@example.dev")
	signedInDir(t, f.altDir, "alt@example.dev")
	signedInDir(t, f.foreignDir, "away@example.dev")
	// A retired folder keeps its identity block forever — llmpilot never blanks
	// a foreign folder's — which is why it must not be reported as a live copy.
	signedInDir(t, f.retiredDir, "moved@example.dev")

	accounts := []store.Account{
		{ID: "main", Label: "main", Email: "main@example.dev", ConfigDir: f.fleetDir},
		{ID: "work", Label: "work", Email: "MAIN@example.dev", ConfigDir: f.fleetDir},
		{ID: "orga", Label: "orga", Email: "a@corp.dev", ConfigDir: f.fleetDir},
		{ID: "orgb", Label: "orgb", Email: "b@corp.dev", ConfigDir: f.fleetDir},
		{ID: "noorg", Label: "noorg", Email: "noorg@example.dev", ConfigDir: f.fleetDir},
		{ID: "away", Label: "away", Email: "away@example.dev", ConfigDir: f.fleetDir},
		{ID: "moved", Label: "moved", Email: "moved@example.dev", ConfigDir: f.fleetDir},
		{ID: "frozen", Label: "frozen", Email: "frozen@example.dev", ConfigDir: f.fleetDir},
		{ID: "dead", Label: "dead", Email: "dead@example.dev", ConfigDir: f.fleetDir},
		{ID: "spent", Label: "spent", Email: "spent@example.dev", ConfigDir: f.fleetDir},
		{ID: "suspect", Label: "suspect", Email: "suspect@example.dev", ConfigDir: f.fleetDir},
		{ID: "alt", Label: "alt", Email: "alt@example.dev", ConfigDir: f.altDir},
	}
	if err := f.store.SaveAccounts(accounts); err != nil {
		t.Fatal(err)
	}

	org := "org-shared-uuid"
	for _, a := range accounts {
		oa := &claudecfg.OAuthAccount{
			AccountUUID:      "acct-" + a.ID,
			EmailAddress:     a.Email,
			OrganizationUUID: "org-" + a.ID,
		}
		switch a.ID {
		case "orga", "orgb":
			oa.OrganizationUUID = org // one subscription, two sign-ins
		case "work":
			oa.AccountUUID = "acct-main" // the same Claude account as main
		case "noorg":
			oa.OrganizationUUID = "" // UNCHECKABLE for a shared subscription
		}
		f.backup(a.ID, oa)
	}

	// orga/orgb move in lockstep — the only corroboration allowed.
	resets := fixedNow.Add(3 * time.Hour)
	for _, id := range []string{"orga", "orgb"} {
		if err := f.store.SaveSnapshot(&store.UsageSnapshot{
			AccountID: id, AsOf: fixedNow,
			Buckets: []store.Bucket{{Kind: "session", Percent: 41.5, ResetsAt: &resets}},
		}); err != nil {
			t.Fatal(err)
		}
	}

	// One proven migration (the folder is empty and stays quiet) and one
	// unproven one (clone-suspect: refreshes stay refused until a fresh login).
	if err := f.store.SaveRetirements(store.Retirements{
		Version: 1,
		Dirs: []store.RetiredDir{
			{ConfigDir: f.retiredDir, Email: "moved@example.dev", AccountID: "moved", RetiredAt: fixedNow.Add(-48 * time.Hour), Complete: true},
			{ConfigDir: filepath.Join(t.TempDir(), ".claude-half"), Email: "suspect@example.dev", AccountID: "suspect", RetiredAt: fixedNow.Add(-time.Hour), Complete: false},
		},
		CloneSuspect: []string{"suspect"},
	}); err != nil {
		t.Fatal(err)
	}

	// The budget document: "spent" has used both slots, and a 429 tripped the
	// global breaker an hour ago.
	tripped := fixedNow.Add(-time.Hour)
	writeJSON(t, filepath.Join(home, "refresh-budget.json"), map[string]any{
		"version": 1,
		"attempts": map[string][]time.Time{
			"spent": {fixedNow.Add(-3 * time.Hour), fixedNow.Add(-90 * time.Minute)},
			"main":  {fixedNow.Add(-30 * time.Hour)}, // outside the window: not spent
		},
		"breaker_tripped_at": tripped,
	})

	// One setup token nearing its declared expiry — the armed class for the
	// setup_tokens check. The file is real and the reader below is the real
	// one, so the read-only sweep proves this read mutates nothing.
	writeJSON(t, filepath.Join(home, "setup-tokens.json"), map[string]any{
		"tokens": []map[string]any{{
			"label":      "ci",
			"created_at": fixedNow.Add(-353 * 24 * time.Hour),
			"expires_at": fixedNow.Add(12 * 24 * time.Hour),
		}},
	})

	// The install is healthy except for a statusline another tool owns — an
	// informational finding, never a problem (it is the user's choice).
	f.install = doctor.InstallFacts{
		LaunchAgentInstalled: true,
		LaunchAgentPath:      filepath.Join(home, "dev.llmpilot.daemon.plist"),
		StatusLine:           doctor.StatusLineForeign,
		// A real statusline command, with the thing that must never be
		// republished sitting in its arguments.
		StatusLineOwner: "/usr/local/bin/starship prompt --api-key=" + argvSecret,
	}

	f.sw = &switcher.Switcher{
		Dir:      claudecfg.DirAt(f.fleetDir),
		Registry: f.store,
		// Any Keychain subprocess at all fails the test: the sweep's only
		// Keychain access is the injected backups reader.
		Keychain: &switcher.Keychain{Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
			t.Fatalf("the sweep shelled out to the Keychain — it must only read llmpilot's own backups through the injected reader")
			return nil, nil
		}},
		ScanDirs: func() ([]string, error) {
			return []string{f.fleetDir, f.altDir, f.foreignDir, f.retiredDir}, nil
		},
	}
	return f
}

// inputs is the production-shaped reader set: the real store, the real
// foreign-dir scan and the real budget reader, plus the daemon's live facts.
// movedDirs is the caller's attribute-only "did a move empty it?" answer — the
// clone guard's own question, never a read this package performs.
func (f *fleet) inputs() doctor.Inputs {
	return doctor.Inputs{
		Now:      func() time.Time { return fixedNow },
		Accounts: f.store.Accounts,
		Snapshot: f.store.Snapshot,
		// The NON-rebuilding reader, exactly as daemon.DoctorInputs wires it:
		// store.Retirements() quarantines an unreadable record by renaming it,
		// and this package never writes.
		Retirements: f.store.RetirementsSnapshot,
		Backups:     f.keychain,
		Foreign:     f.sw.ForeignSignIns,
		Budget:      f.sw.BudgetSnapshot,
		MovedDirs: func(context.Context) (map[string]bool, error) {
			return map[string]bool{f.retiredDir: true}, nil
		},
		Pinned:  func(a store.Account) bool { return a.ConfigDir == f.altDir },
		Install: func() (doctor.InstallFacts, error) { return f.install, nil },
		// The REAL metadata reader on the real home — metadata only, no
		// Keychain: the read-only and own-keychain proofs cover it.
		SetupTokens: (&setuptoken.Store{Home: f.home}).List,
		Daemon:      f.daemonFacts(),
	}
}

func (f *fleet) daemonFacts() *doctor.DaemonFacts {
	return &doctor.DaemonFacts{
		Stale:       map[string]bool{"frozen": true},
		TokenNote:   map[string]string{"frozen": "usage may be out of date", "main": "a note worth repeating"},
		Quarantined: map[string]bool{"dead": true},
		Stash: []pilotapi.StashEntry{
			{Fingerprint: "fp-live", Label: "kept-one", StashedAt: fixedNow.Add(-time.Hour)},
			{Fingerprint: "fp-dead", Label: "kept-two", StashedAt: fixedNow.Add(-2 * time.Hour), Dead: true},
		},
	}
}

// findingsByID indexes a report for assertions.
func findingsByID(rep doctor.Report) map[string]doctor.Finding {
	out := map[string]doctor.Finding{}
	for _, f := range rep.Findings {
		if _, seen := out[f.ID]; !seen {
			out[f.ID] = f
		}
	}
	return out
}

func checksByID(rep doctor.Report) map[string]doctor.Check {
	out := map[string]doctor.Check{}
	for _, c := range rep.Checks {
		out[c.ID] = c
	}
	return out
}

func countByID(rep doctor.Report, id string) int {
	n := 0
	for _, f := range rep.Findings {
		if f.ID == id {
			n++
		}
	}
	return n
}

// identityFor is the stored identity block for a whole, checkable account.
func identityFor(id string) *claudecfg.OAuthAccount {
	return &claudecfg.OAuthAccount{
		AccountUUID:      "acct-" + id,
		EmailAddress:     id + "@example.dev",
		OrganizationUUID: "org-" + id,
	}
}
