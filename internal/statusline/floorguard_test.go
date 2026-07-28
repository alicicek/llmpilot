package statusline

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// setDirIdentity rewrites a fake config dir's oauthAccount — the swap's
// visible effect on the dir.
func setDirIdentity(t *testing.T, dir claudecfg.Dir, email string) {
	t.Helper()
	doc := map[string]any{"oauthAccount": map[string]any{"emailAddress": email}}
	data, _ := json.Marshal(doc)
	if err := os.WriteFile(dir.ConfigJSONPath(), data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// guardCtx builds a Ctx for one render: session sid's stdin carries a
// five_hour floor of 88%, the store knows accounts a and b.
func guardCtx(st *store.Store, dir claudecfg.Dir, sid string) *Ctx {
	stdin := fmt.Sprintf(`{
		"session_id": %q,
		"rate_limits": {"five_hour": {"used_percentage": 88, "resets_at": %d}}
	}`, sid, time.Date(2026, 7, 25, 18, 0, 0, 0, time.UTC).Unix())
	return &Ctx{
		Now: time.Date(2026, 7, 25, 14, 0, 0, 0, time.UTC), Loc: time.UTC,
		In: ParsePayload([]byte(stdin)), Store: st, Dir: dir,
	}
}

// TestFloorIdentityGuard proves the swap window is closed. §2b receipt
// (transcript, 2026-07-25): stdin carries `session_id` (2.1.220 binary
// schema + docs) — so per the wave decision the guard binds sessions to
// identities and the swap-instant-marker leg is dropped. The old session's
// floor is not attributed to the new identity for ANY duration (stronger
// than the 60s-window design the marker would have given); a pinned dir's
// floor is untouched; the floor resumes for new sessions immediately and
// for the old session when its identity is active again.
func TestFloorIdentityGuard(t *testing.T) {
	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-a", Label: "a", Email: "a@example.dev"},
		{ID: "acct-b", Label: "b", Email: "b@example.dev"},
	}); err != nil {
		t.Fatal(err)
	}
	// b's cache snapshot: what the row must fall back to when the floor is
	// suppressed.
	if err := st.SaveSnapshot(&store.UsageSnapshot{
		AccountID: "acct-b", AsOf: time.Date(2026, 7, 25, 13, 59, 0, 0, time.UTC),
		Buckets: []store.Bucket{{Kind: "five_hour", Percent: 41}},
	}); err != nil {
		t.Fatal(err)
	}
	dirPath := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(dirPath)

	// Session S1 first rendered while the dir belongs to a: binds to a, and
	// its floor is attributed (88% renders).
	setDirIdentity(t, dir, "a@example.dev")
	ctx := guardCtx(st, dir, "sess-1")
	buckets, _ := usageBuckets(ctx)
	if len(buckets) == 0 || buckets[0].Percent != 88 {
		t.Fatalf("pre-swap: own session's floor must render: %+v", buckets)
	}
	t.Logf("pre-swap: session bound to a, floor attributed (88%%)")

	// THE SWAP: the dir now belongs to b. S1 keeps rendering with a's
	// windows on stdin — they must NOT be attributed to b, ever (not a 60s
	// window: the binding mismatch suppresses them for the session's life).
	setDirIdentity(t, dir, "b@example.dev")
	ctx = guardCtx(st, dir, "sess-1")
	buckets, _ = usageBuckets(ctx)
	for _, b := range buckets {
		if b.Percent == 88 {
			t.Fatalf("SWAP WINDOW OPEN: old session's floor attributed to the new identity: %+v", buckets)
		}
	}
	if len(buckets) == 0 || buckets[0].Percent != 41 {
		t.Fatalf("suppressed floor must fall back to b's cache: %+v", buckets)
	}
	t.Logf("post-swap: old session's floor suppressed, b renders from cache (41%%)")

	// A NEW session under b binds to b: floor valid immediately — the
	// "floor resumes" leg, with zero grace-window wait.
	ctx = guardCtx(st, dir, "sess-2")
	buckets, _ = usageBuckets(ctx)
	if len(buckets) == 0 || buckets[0].Percent != 88 {
		t.Fatalf("new session's floor must be attributed immediately: %+v", buckets)
	}
	t.Logf("post-swap: new session's floor valid immediately (88%%)")

	// Swapping BACK to a revalidates S1's floor (binding matches again).
	setDirIdentity(t, dir, "a@example.dev")
	ctx = guardCtx(st, dir, "sess-1")
	buckets, _ = usageBuckets(ctx)
	if len(buckets) == 0 || buckets[0].Percent != 88 {
		t.Fatalf("swap-back must revalidate the old session's floor: %+v", buckets)
	}
	t.Logf("swap-back: old session's floor resumes (binding matches again)")
}

// TestFloorIdentityGuardPinnedDirUntouched: a pinned dir's identity never
// changes on a global swap, so its sessions' floors are never suppressed.
func TestFloorIdentityGuardPinnedDirUntouched(t *testing.T) {
	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-p", Label: "p", Email: "pinned@example.dev", Pinned: true},
	}); err != nil {
		t.Fatal(err)
	}
	pinned := filepath.Join(t.TempDir(), ".claude-pinned")
	if err := os.MkdirAll(pinned, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(pinned)
	setDirIdentity(t, dir, "pinned@example.dev")
	for i := 1; i <= 3; i++ { // repeated renders across (global) swap instants
		ctx := guardCtx(st, dir, "sess-pinned")
		buckets, _ := usageBuckets(ctx)
		if len(buckets) == 0 || buckets[0].Percent != 88 {
			t.Fatalf("render %d: pinned dir's floor suppressed: %+v", i, buckets)
		}
	}
	t.Logf("pinned dir: floor attributed on every render — never suppressed")
}

// TestFloorIdentityGuardNoSessionID: an older CC without session_id (or the
// daemon preview) degrades to the pre-P2 behavior — floor honored.
func TestFloorIdentityGuardNoSessionID(t *testing.T) {
	st := store.At(t.TempDir())
	dirPath := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(dirPath)
	setDirIdentity(t, dir, "a@example.dev")
	stdin := `{"rate_limits": {"five_hour": {"used_percentage": 88, "resets_at": 1784000000}}}`
	ctx := &Ctx{Now: time.Now(), Loc: time.UTC, In: ParsePayload([]byte(stdin)), Store: st, Dir: dir}
	buckets, _ := usageBuckets(ctx)
	if len(buckets) == 0 || buckets[0].Percent != 88 {
		t.Fatalf("no session_id must not suppress the floor: %+v", buckets)
	}
	t.Logf("no session_id: floor honored (nothing to bind on)")
}

// TestFloorIdentityGuardBindingsPrune: bindings older than the TTL are
// dropped on a first-sight bind; the binding dir never grows unbounded.
func TestFloorIdentityGuardBindingsPrune(t *testing.T) {
	st := store.At(t.TempDir())
	dirPath := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(dirPath)
	setDirIdentity(t, dir, "a@example.dev")
	bindDir := filepath.Join(st.Home(), sessionBindingsDirName)
	if err := os.MkdirAll(bindDir, 0o700); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(bindDir, "sess-ancient")
	if err := os.WriteFile(stale, []byte("old@example.dev\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-30 * 24 * time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	ctx := guardCtx(st, dir, "sess-fresh")
	ctx.Now = time.Now()
	if _, _ = usageBuckets(ctx); false {
		t.Fatal("unreachable")
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale binding not pruned on a first-sight bind")
	}
	t.Logf("bindings pruned past the %s TTL", sessionBindingTTL)
}

// TestFloorIdentityGuardLiveBindingSurvivesTTL: a session that keeps
// rendering must NOT have its binding pruned — the read path touches the
// mtime so the TTL measures time-since-last-render, not time-since-first-
// sight (fix-delta review P2: otherwise a long-lived session's binding is
// pruned and its next render re-binds to the then-current identity, re-
// opening the swap window).
func TestFloorIdentityGuardLiveBindingSurvivesTTL(t *testing.T) {
	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{{ID: "acct-a", Label: "a", Email: "a@example.dev"}}); err != nil {
		t.Fatal(err)
	}
	dirPath := filepath.Join(t.TempDir(), ".claude-test")
	if err := os.MkdirAll(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	dir := claudecfg.DirAt(dirPath)
	setDirIdentity(t, dir, "a@example.dev")

	// First render at T0 binds the session.
	c0 := guardCtx(st, dir, "sess-live")
	c0.Now = time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	_, _ = usageBuckets(c0)

	// The session renders again 20 days later (past the 14-day TTL) — the
	// read must refresh the binding's mtime.
	late := time.Date(2026, 7, 21, 12, 0, 0, 0, time.UTC)
	c1 := guardCtx(st, dir, "sess-live")
	c1.Now = late
	buckets, _ := usageBuckets(c1)
	if len(buckets) == 0 || buckets[0].Percent != 88 {
		t.Fatalf("live session's floor should still attribute after a re-render: %+v", buckets)
	}

	// A DIFFERENT session first-sight-binds even later, running the pruner —
	// the live session's binding must NOT be swept (its mtime is `late`).
	c2 := guardCtx(st, dir, "sess-other")
	c2.Now = late.Add(2 * time.Hour)
	_, _ = usageBuckets(c2)
	bindDir := filepath.Join(st.Home(), sessionBindingsDirName)
	if _, err := os.Stat(filepath.Join(bindDir, "sess-live")); err != nil {
		t.Fatalf("live session's binding was pruned despite recent renders: %v", err)
	}
	t.Logf("live session's binding survived the TTL — mtime tracks last render, not first sight")
}
