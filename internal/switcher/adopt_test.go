package switcher

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestAdoptStashRefusesClobberingNewerBackup is the adversarial-review P0:
// an account signed in AFTER a stash was taken has a FRESH backup; adopting
// the leftover (older, server-dead) stash entry must NOT overwrite it.
func TestAdoptStashRefusesClobberingNewerBackup(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()

	// 1. Stash a foreign credential for stranger@ (older lineage).
	old := json.RawMessage(`{"claudeAiOauth":{"accessToken":"token-OLD-DEAD","refreshToken":"r-OLD-DEAD","expiresAt":4102444800000}}`)
	if err := sw.stashForeign(ctx, old, oauthJSON("stranger@example.dev")); err != nil {
		t.Fatal(err)
	}
	fp := ""
	if entries, _ := sw.StashEntries(); len(entries) == 1 {
		fp = entries[0].Fingerprint
	} else {
		t.Fatalf("want 1 stash entry, got %v", entries)
	}

	// 2. That account is now registered with a FRESH backup (a real re-login).
	id := "acct-stranger_example.dev"
	accs, _ := sw.Registry.Accounts()
	accs = append(accs, store.Account{ID: id, Label: "stranger", Email: "stranger@example.dev", ConfigDir: dir.Path()})
	if err := sw.Registry.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	fresh := json.RawMessage(`{"claudeAiOauth":{"accessToken":"token-FRESH-LIVE","refreshToken":"r-FRESH-LIVE","expiresAt":4102444800000}}`)
	if err := sw.SaveBackup(ctx, id, fresh, oauthJSON("stranger@example.dev")); err != nil {
		t.Fatal(err)
	}

	// 3. Adopt the leftover stash entry — must be REFUSED, backup untouched.
	_, err := sw.AdoptStash(ctx, fp, "")
	if !errors.Is(err, ErrStashConflict) {
		t.Fatalf("adopt over a newer backup = %v, want ErrStashConflict", err)
	}
	got, _, lerr := sw.LoadBackup(ctx, id)
	if lerr != nil || !strings.Contains(string(got), "token-FRESH-LIVE") {
		t.Fatalf("P0 REGRESSION: fresh backup clobbered by the stale stash: %s (%v)", got, lerr)
	}
	t.Logf("adopt refused (ErrStashConflict) — the account's fresh backup survived")
}

// TestAdoptStashSucceedsForUnregistered: the normal path still works — a
// stash entry for an account with no existing backup adopts cleanly.
func TestAdoptStashSucceedsForUnregistered(t *testing.T) {
	sw, fk, _, _ := sandbox(t)
	ctx := context.Background()
	cred := json.RawMessage(`{"claudeAiOauth":{"accessToken":"token-NEW","refreshToken":"r-NEW","expiresAt":4102444800000}}`)
	if err := sw.stashForeign(ctx, cred, oauthJSON("new@example.dev")); err != nil {
		t.Fatal(err)
	}
	entries, _ := sw.StashEntries()
	acct, err := sw.AdoptStash(ctx, entries[0].Fingerprint, "")
	if err != nil {
		t.Fatalf("adopt: %v", err)
	}
	if acct.Email != "new@example.dev" {
		t.Fatalf("adopted account = %+v", acct)
	}
	if !strings.Contains(string(fk.items[BackupService+"\x00"+acct.ID]), "token-NEW") {
		t.Fatal("adopted backup missing the credential")
	}
	if left, _ := sw.StashEntries(); len(left) != 0 {
		t.Fatalf("stash entry not retired after adopt: %v", left)
	}
	// Re-adopting the SAME lineage (idempotent) is not a conflict.
	if err := sw.stashForeign(ctx, cred, oauthJSON("new@example.dev")); err != nil {
		t.Fatal(err)
	}
	e2, _ := sw.StashEntries()
	if _, err := sw.AdoptStash(ctx, e2[0].Fingerprint, ""); err != nil {
		t.Fatalf("re-adopt of the same lineage should succeed: %v", err)
	}
	t.Logf("adopt of an unregistered entry registered it and retired the stash; same-lineage re-adopt is not a conflict")
}
