package switcher

import (
	"context"
	"testing"
)

func TestFreshenBackupCapturesRotatedCredential(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()
	me := Identity{ID: "acct-a", Email: "a@example.dev"}

	// first capture: no backup existed.
	changed, err := sw.FreshenBackup(ctx, me)
	if err != nil || !changed {
		t.Fatalf("first freshen: changed=%v err=%v", changed, err)
	}
	cred, _, err := sw.LoadBackup(ctx, "acct-a")
	if err != nil || string(cred) != string(credJSON("token-a-LIVE")) {
		t.Fatalf("backup not captured: %s (err %v)", cred, err)
	}

	// unchanged credential: no write.
	changed, err = sw.FreshenBackup(ctx, me)
	if err != nil || changed {
		t.Fatalf("idempotent freshen: changed=%v err=%v", changed, err)
	}

	// CC refreshes → rotates the credential in the live slot: re-captured.
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", credJSON("token-a-ROTATED")); err != nil {
		t.Fatal(err)
	}
	changed, err = sw.FreshenBackup(ctx, me)
	if err != nil || !changed {
		t.Fatalf("rotated freshen: changed=%v err=%v", changed, err)
	}
	cred, _, _ = sw.LoadBackup(ctx, "acct-a")
	if string(cred) != string(credJSON("token-a-ROTATED")) {
		t.Fatalf("rotation not captured: %s", cred)
	}
}

func TestFreshenBackupRefusesForeignIdentity(t *testing.T) {
	sw, _, dir, _ := sandbox(t)
	ctx := context.Background()

	// the dir is logged into a@ — freshening b's backup must be a no-op:
	// capturing a's credential under b's ID would poison b's backup.
	changed, err := sw.FreshenBackup(ctx, Identity{ID: "acct-b", Email: "b@example.dev"})
	if err != nil || changed {
		t.Fatalf("foreign identity captured: changed=%v err=%v", changed, err)
	}
	cred, _, err := sw.LoadBackup(ctx, "acct-b")
	if err != nil || string(cred) != string(credJSON("token-b-STORED")) {
		t.Fatalf("b's backup mutated: %s (err %v)", cred, err)
	}

	// a bare /login switched the slot to b: NOW freshening b captures, and
	// freshening a is refused.
	writeConfig(t, dir, "b@example.dev", `{}`)
	if err := sw.Keychain.Set(ctx, dir.KeychainService(), "tester", credJSON("token-b-FRESH")); err != nil {
		t.Fatal(err)
	}
	changed, err = sw.FreshenBackup(ctx, Identity{ID: "acct-b", Email: "b@example.dev"})
	if err != nil || !changed {
		t.Fatalf("post-login freshen: changed=%v err=%v", changed, err)
	}
	changed, err = sw.FreshenBackup(ctx, Identity{ID: "acct-a", Email: "a@example.dev"})
	if err != nil || changed {
		t.Fatalf("a captured while b logged in: changed=%v err=%v", changed, err)
	}
}
