package switcher

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

// lyingKeychain wraps the fake, returning a forged value for reads of one
// service after N calls — simulating a read-back that does not match what
// was written (verify must fail, journal must survive).
type lyingKeychain struct {
	*fakeKeychain
	lieService string
	lieAfter   int
	lieValue   []byte
	calls      int
}

func (l *lyingKeychain) run(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	l.calls++
	joined := strings.Join(args, " ")
	if l.calls > l.lieAfter && strings.HasPrefix(joined, "find-generic-password") &&
		flagVal(args, "-s") == l.lieService {
		if len(l.lieValue) == 0 {
			return []byte("\n"), nil // an EMPTY read-back
		}
		return append(l.lieValue, '\n'), nil
	}
	return l.fakeKeychain.run(ctx, stdin, name, args...)
}

// TestCASRefusalEmptySet: Keychain.Set refuses an empty secret outright.
func TestCASRefusalEmptySet(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	for _, payload := range [][]byte{nil, {}, []byte("   \n")} {
		if err := sw.Keychain.Set(context.Background(), dir.KeychainService(), "tester", payload); err == nil {
			t.Fatalf("empty Set (%q) accepted", payload)
		}
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("refused Set still mutated the item")
	}
	t.Logf("CAS: empty overwrite refused at Keychain.Set, item untouched")
}

// TestCASRefusalUnparseableTarget: a backup whose credential does not parse
// as claudeAiOauth is refused BEFORE the install writes anything.
func TestCASRefusalUnparseableTarget(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	if err := sw.SaveBackup(ctx, "acct-b", json.RawMessage(`{"not":"a credential"}`), oauthJSON("b@example.dev")); err != nil {
		t.Fatal(err)
	}
	err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "refusing to install") {
		t.Fatalf("err = %v, want install refusal", err)
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("refused install still mutated the live slot")
	}
	if got := readEmail(t, dir); got != "a@example.dev" {
		t.Fatalf("config mutated: %s", got)
	}
	t.Logf("CAS: parse-failing target credential refused before any write")
}

// TestCASRefusalSpliceToNil: a target backup that omitted oauthAccount must
// not blank a non-empty identity in .claude.json (the splice-to-nil hole:
// verify's empty==empty would then pass over it).
func TestCASRefusalSpliceToNil(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	if err := sw.SaveBackup(ctx, "acct-b", credJSON("token-b-STORED"), nil); err != nil {
		t.Fatal(err)
	}
	err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "refusing to blank") {
		t.Fatalf("err = %v, want splice-to-nil refusal", err)
	}
	// The refusal happens at the splice — the keychain write must be rolled
	// back and the config identity intact.
	if got := readEmail(t, dir); got != "a@example.dev" {
		t.Fatalf("identity blanked or changed: %s", got)
	}
	if !strings.Contains(string(fk.items[dir.KeychainService()+"\x00tester"]), "token-a-LIVE") {
		t.Fatal("keychain not rolled back after splice-to-nil refusal")
	}
	t.Logf("CAS: splice-to-nil refused while the file holds a non-empty oauthAccount; rolled back")
}

// TestCASRefusalSpliceToNilAllowedWhenAlreadyEmpty: nil-over-nothing is not
// a blanking — a dir with no identity accepts an identity-less install.
func TestCASRefusalSpliceToNilAllowedWhenAlreadyEmpty(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	ctx := context.Background()
	if err := os.WriteFile(dir.ConfigJSONPath(), []byte(`{"userSettings":{"theme":"dark"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := sw.SaveBackup(ctx, "acct-b", credJSON("token-b-STORED"), nil); err != nil {
		t.Fatal(err)
	}
	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("nil-over-empty splice should succeed: %v\n%s", err, out.String())
	}
	t.Logf("CAS: identity-less install accepted when the dir held no identity")
}

// TestCASRefusalEmptyReadBack: verify FAILS when the keychain read-back is
// empty — and the journal survives for the next swap's recovery.
func TestCASRefusalEmptyReadBack(t *testing.T) {
	sw, fk, dir, _ := sandbox(t)
	ctx := context.Background()
	lk := &lyingKeychain{fakeKeychain: fk, lieService: dir.KeychainService(), lieAfter: 6}
	sw.Keychain = &Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: lk.run}
	err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"})
	if err == nil || !strings.Contains(err.Error(), "verify") {
		t.Fatalf("err = %v, want verify failure", err)
	}
	if _, ok := fk.items[BackupService+"\x00"+journalAccount]; !ok {
		t.Fatal("journal did not survive a verify failure")
	}
	t.Logf("CAS: empty read-back failed verify, journal kept for recovery")
}
