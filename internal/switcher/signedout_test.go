package switcher

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
)

// A config dir keeps its oauthAccount block long after its credential is
// gone, so identity alone reports a folder as signed in when adopt and move
// can only refuse there (owner hit both refusals live: "no credential in
// Keychain service …" and "has no stored sign-in to move"). CredentialPresent
// is the direct question the cockpit asks instead.
//
// The probe runs for real here — the fake Keychain answers `dump-keychain` in
// the tool's own block format, so List's parser is exercised rather than
// handed an answer.
func TestCredentialPresentSeesThroughAStaleIdentity(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	ctx := context.Background()

	// A dir that NAMES an account but holds no credential anywhere: nothing
	// in its Keychain service, no .credentials.json.
	stale := filepath.Join(t.TempDir(), "claude-stale")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`{"oauthAccount":%s}`, oauthJSON("gone@example.dev"))
	if err := os.WriteFile(filepath.Join(stale, ".claude.json"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	staleDir := claudecfg.DirAt(stale)
	if sw.CredentialPresent(ctx, staleDir) {
		t.Fatal("a dir with an identity but no credential reported as signed in — the cockpit offers Add/Move there and both refuse")
	}

	// The same dir once a credential exists in its own Keychain service: the
	// verbs are real again.
	cred := credWithExpiry("token-x", time.Now().Add(time.Hour))
	if err := sw.Keychain.Set(ctx, staleDir.KeychainService(), claudecfg.KeychainAccount(), cred); err != nil {
		t.Fatal(err)
	}
	if !sw.CredentialPresent(ctx, staleDir) {
		t.Fatal("a dir holding a credential reported as signed out — a real account would be hidden")
	}
}

// Any doubt must read as PRESENT: hiding a real account is the worse failure,
// and the engine still refuses safely if the guess is wrong.
func TestCredentialPresentTreatsAnUnreadableProbeAsSignedIn(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()

	dir := claudecfg.DirAt(t.TempDir())
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
		return nil, fmt.Errorf("keychain unavailable")
	}}
	if !sw.CredentialPresent(ctx, dir) {
		t.Fatal("an enumeration failure answered signed OUT — an unreadable probe must never hide an account")
	}
}

// SignedInDirs is the path /v1/detect actually takes, and both surfaces poll
// it — so it must answer for the whole fleet with ONE keychain enumeration,
// not one per folder.
func TestSignedInDirsAnswersManyFoldersInOneEnumeration(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()

	live := claudecfg.DirAt(filepath.Join(t.TempDir(), "claude-live"))
	spentA := claudecfg.DirAt(filepath.Join(t.TempDir(), "claude-spent-a"))
	spentB := claudecfg.DirAt(filepath.Join(t.TempDir(), "claude-spent-b"))
	if err := sw.Keychain.Set(ctx, live.KeychainService(), claudecfg.KeychainAccount(),
		credWithExpiry("token-live", time.Now().Add(time.Hour))); err != nil {
		t.Fatal(err)
	}

	dumps := 0
	inner := fk.run
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(ctx context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
		if len(args) > 0 && args[0] == "dump-keychain" {
			dumps++
		}
		return inner(ctx, stdin, name, args...)
	}}

	got := sw.SignedInDirs(ctx, []claudecfg.Dir{live, spentA, spentB})
	if !got[live.Path()] {
		t.Error("a dir holding a credential reported signed out — a real account would be hidden")
	}
	if got[spentA.Path()] || got[spentB.Path()] {
		t.Errorf("a spent dir reported signed in: %+v", got)
	}
	if dumps != 1 {
		t.Errorf("keychain enumerated %d times for 3 dirs, want 1 — this endpoint is polled", dumps)
	}
}

// An enumeration failure must report every dir present, never hide the fleet.
func TestSignedInDirsTreatsAFailedEnumerationAsSignedIn(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	dir := claudecfg.DirAt(t.TempDir())
	sw.Keychain = &Keychain{File: fk.keychain().File, Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
		return nil, fmt.Errorf("keychain unavailable")
	}}
	if !sw.SignedInDirs(context.Background(), []claudecfg.Dir{dir})[dir.Path()] {
		t.Fatal("a failed enumeration hid an account")
	}
}
