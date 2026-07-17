package store

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestOpenRespectsEnv(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("LLMPILOT_HOME", dir)
	s, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	if s.Home() != dir {
		t.Fatalf("Home() = %q, want %q", s.Home(), dir)
	}
}

func TestAccountsMissingFileIsEmpty(t *testing.T) {
	s := At(t.TempDir())
	accs, err := s.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	if len(accs) != 0 {
		t.Fatalf("want empty registry, got %v", accs)
	}
}

func TestAccountsRoundTrip(t *testing.T) {
	s := At(t.TempDir())
	want := []Account{
		{ID: "acct-a", Label: "a", Email: "a@example.dev", ConfigDir: "/tmp/fake-a", KeychainService: "Claude Code-credentials", Pinned: false},
		{ID: "acct-b", Label: "b", Email: "b@example.dev", ConfigDir: "/tmp/fake-b", KeychainService: "Claude Code-credentials-deadbeef", Pinned: true},
	}
	if err := s.SaveAccounts(want); err != nil {
		t.Fatal(err)
	}
	got, err := s.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("round trip mismatch:\ngot  %+v\nwant %+v", got, want)
	}
	info, err := os.Stat(filepath.Join(s.Home(), "accounts.json"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("accounts.json perm = %o, want 600", perm)
	}
}

// TestSnapshotUnknownKindRoundTrip is the 2026-07-12 case: bucket kinds the
// code has never heard of must survive save/load byte-identically.
func TestSnapshotUnknownKindRoundTrip(t *testing.T) {
	s := At(t.TempDir())
	reset := time.Date(2026, 7, 14, 12, 0, 0, 499357000, time.UTC)
	want := &UsageSnapshot{
		AccountID: "acct-a",
		AsOf:      time.Date(2026, 7, 8, 23, 0, 0, 0, time.UTC),
		Buckets: []Bucket{
			{Kind: "session", Percent: 2, Severity: "normal", ResetsAt: &reset},
			{Kind: "weekly_all", Percent: 49, Severity: "normal", ResetsAt: &reset},
			{Kind: "weekly_scoped", Scope: "Fable", Percent: 79, Severity: "warning", ResetsAt: &reset, Active: true},
			{Kind: "tangelo_hourly", Percent: 12.5}, // unknown kind, no reset, no severity
		},
	}
	if err := s.SaveSnapshot(want); err != nil {
		t.Fatal(err)
	}
	got, err := s.Snapshot("acct-a")
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("round trip mismatch:\ngot  %+v\nwant %+v", got, want)
	}
}

func TestSnapshotMissingIsNil(t *testing.T) {
	s := At(t.TempDir())
	snap, err := s.Snapshot("nope")
	if err != nil {
		t.Fatal(err)
	}
	if snap != nil {
		t.Fatalf("want nil snapshot, got %+v", snap)
	}
}

func TestSnapshotRejectsPathyIDs(t *testing.T) {
	s := At(t.TempDir())
	for _, id := range []string{"", "..", "a/b", `a\b`} {
		if err := s.SaveSnapshot(&UsageSnapshot{AccountID: id}); err == nil {
			t.Fatalf("SaveSnapshot accepted invalid id %q", id)
		}
		if _, err := s.Snapshot(id); err == nil {
			t.Fatalf("Snapshot accepted invalid id %q", id)
		}
	}
}

func TestAtomicWriteLeavesNoTempFiles(t *testing.T) {
	s := At(t.TempDir())
	if err := s.SaveAccounts([]Account{{ID: "x"}}); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(s.Home())
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if e.Name() != "accounts.json" {
			t.Fatalf("unexpected leftover entry %q", e.Name())
		}
	}
}

func TestUniqueScheduleID(t *testing.T) {
	// free: the human id
	if got := UniqueScheduleID(nil, "acct-one", "kai", 9, 0); got != "kai-0900" {
		t.Errorf("free id = %q", got)
	}
	existing := []Schedule{{ID: "kai-0900", AccountID: "acct-one", Hour: 9}}
	// same account, same slot: same id (callers' conflict check fires)
	if got := UniqueScheduleID(existing, "acct-one", "kai", 9, 0); got != "kai-0900" {
		t.Errorf("same-account id = %q", got)
	}
	// another account with a colliding label: disambiguated, stable, valid
	got := UniqueScheduleID(existing, "acct-two", "kai", 9, 0)
	if got == "kai-0900" {
		t.Fatal("cross-account collision not disambiguated")
	}
	if again := UniqueScheduleID(existing, "acct-two", "kai", 9, 0); again != got {
		t.Errorf("disambiguation not stable: %q vs %q", got, again)
	}
	if err := (Schedule{ID: got, AccountID: "acct-two", Hour: 9}).Validate(); err != nil {
		t.Errorf("disambiguated id fails validation: %v", err)
	}
}
