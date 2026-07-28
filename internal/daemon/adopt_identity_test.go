package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/detect"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// detectRow mirrors GET /v1/detect's wire shape.
type detectRow struct {
	ConfigDir  string `json:"config_dir"`
	Email      string `json:"email"`
	Registered bool   `json:"registered"`
	Moved      bool   `json:"moved"`
}

func getDetect(t *testing.T, srv *httptest.Server) []detectRow {
	t.Helper()
	resp, err := http.Get(srv.URL + "/v1/detect")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var out []detectRow
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestAdoptIdentity is the identity-not-dir proof. In the swappable model
// EVERY registered account's ConfigDir is the GLOBAL dir, so the old
// dir-match reported that dir registered forever: a NEW account signed into
// ~/.claude could never be adopted from a GUI (409), while `llmpilot init`
// adopted it fine. Identity is the email.
func TestAdoptIdentity(t *testing.T) {
	const globalDir = "/fake/global"
	st := testStore(t) // seeds a@example.dev and b@example.dev
	accs, err := st.Accounts()
	if err != nil {
		t.Fatal(err)
	}
	for i := range accs {
		accs[i].ConfigDir = globalDir // the swappable model: everyone shares it
	}
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	// The global dir is now signed in as a THIRD account nobody registered.
	detected := []detect.Detected{
		fakeDetected(globalDir, "new@example.dev"),
		fakeDetected("/fake/dir-pinned", "a@example.dev"), // known identity, other dir
	}
	adopted := ""
	d := &Daemon{
		Store:  st,
		Detect: func(context.Context) ([]detect.Detected, error) { return detected, nil },
		Adopt: func(_ context.Context, det detect.Detected, label string) (store.Account, error) {
			adopted = det.Account.EmailAddress
			acct := store.Account{ID: "acct-new", Label: label, Email: det.Account.EmailAddress, ConfigDir: det.Dir.Path()}
			cur, err := st.Accounts()
			if err != nil {
				return store.Account{}, err
			}
			return acct, st.SaveAccounts(append(cur, acct))
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	rows := getDetect(t, srv)
	byDir := map[string]detectRow{}
	for _, r := range rows {
		byDir[r.ConfigDir] = r
	}
	if byDir[globalDir].Registered {
		t.Fatalf("a NEW account in the global dir reported registered: %+v", byDir[globalDir])
	}
	// A dir whose EMAIL is registered still reports registered.
	if !byDir["/fake/dir-pinned"].Registered {
		t.Fatalf("a known identity reported unregistered: %+v", byDir["/fake/dir-pinned"])
	}

	// The GUI no longer hides what the CLI can reach: `llmpilot init` calls
	// AddAccount on EVERY detected dir (wave3.go), so a dir it would register
	// as a NEW account is exactly a dir whose email is unknown here. That set
	// is what the GUI must offer; it used to be empty for the global dir.
	adoptable := map[string]bool{}
	for _, r := range rows {
		if !r.Registered {
			adoptable[r.Email] = true
		}
	}
	known := map[string]bool{}
	for _, a := range accs {
		known[a.Email] = true
	}
	for _, det := range detected {
		wantAdoptable := !known[det.Account.EmailAddress]
		if adoptable[det.Account.EmailAddress] != wantAdoptable {
			t.Fatalf("GUI adoptable set diverges from init's for %s", det.Account.EmailAddress)
		}
	}

	// And POST /v1/adopt actually registers it (today: 409).
	resp, err := http.Post(srv.URL+"/v1/adopt", "application/json",
		strings.NewReader(`{"config_dir":"`+globalDir+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("adopt status = %d, body = %s", resp.StatusCode, body)
	}
	if adopted != "new@example.dev" {
		t.Fatalf("adopted = %q", adopted)
	}

	// Re-adopting the same identity is still a 409 (additive, never a fork).
	again, err := http.Post(srv.URL+"/v1/adopt", "application/json",
		strings.NewReader(`{"config_dir":"`+globalDir+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = again.Body.Close()
	if again.StatusCode != http.StatusConflict {
		t.Fatalf("re-adopt status = %d, want 409", again.StatusCode)
	}
}

// TestAdoptIdentityRendersMovedDirs: a dir whose sign-in was moved into the
// fleet keeps its oauthAccount block (llmpilot never blanks a foreign dir's
// identity), so /v1/detect must say so from the retirement record instead of
// pretending the dir is a fresh candidate.
func TestAdoptIdentityRendersMovedDirs(t *testing.T) {
	st := testStore(t)
	if err := st.RecordRetirement(store.RetiredDir{
		ConfigDir: "/fake/dir-moved", Email: "a@example.dev", AccountID: "a", Complete: true,
	}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{fakeDetected("/fake/dir-moved", "a@example.dev")}, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	rows := getDetect(t, srv)
	if len(rows) != 1 || !rows[0].Moved || !rows[0].Registered {
		t.Fatalf("moved dir = %+v", rows)
	}
}

// TestSwitchRefusesPinnedBeforeFreshen (daemon half): the API refuses a
// pinned target BEFORE d.Switch runs — no freshen, no budget, no dir lock.
// The copy states what the account IS for; a pinned account is a feature.
func TestSwitchRefusesPinnedBeforeFreshen(t *testing.T) {
	st := testStore(t)
	accs, _ := st.Accounts()
	accs[0].ConfigDir = "/fake/pinned-dir"
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	switched := 0
	d := &Daemon{
		Store:  st,
		Pinned: func(a store.Account) bool { return a.ConfigDir == "/fake/pinned-dir" },
		Switch: func(context.Context, string) error { switched++; return nil },
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/v1/switch", "application/json",
		strings.NewReader(`{"account_id":"`+accs[0].ID+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("status = %d, want 409; body = %s", resp.StatusCode, body)
	}
	if switched != 0 {
		t.Fatalf("the switch path ran for a pinned target (%d calls) — it would freshen and lock", switched)
	}
	var errBody struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &errBody); err != nil {
		t.Fatal(err)
	}
	msg := errBody.Error
	if !strings.Contains(msg, "own folder") || !strings.Contains(msg, "move it into the fleet") {
		t.Fatalf("copy must say what the account is for and how to make it switchable: %s", msg)
	}
	for _, blame := range []string{"invalid", "cannot be", "not allowed", "failed"} {
		if strings.Contains(strings.ToLower(msg), blame) {
			t.Fatalf("copy blames the user (%q): %s", blame, msg)
		}
	}

	// A non-pinned account still switches.
	accs[1].ConfigDir = ""
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	ok, err := http.Post(srv.URL+"/v1/switch", "application/json",
		strings.NewReader(`{"account_id":"`+accs[1].ID+`"}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = ok.Body.Close()
	if ok.StatusCode != http.StatusOK || switched != 1 {
		t.Fatalf("status = %d switched = %d", ok.StatusCode, switched)
	}
}

// TestAutoSwitchReserve (daemon half): every autopilot-initiated rotation
// rides the UNATTENDED closure, and a nil AutoSwitch falls back to Switch so
// a partially wired build still rotates.
func TestAutoSwitchReserve(t *testing.T) {
	for _, tc := range []struct {
		name        string
		wireAuto    bool
		wantAuto    int
		wantRegular int
	}{
		{name: "autopilot uses the unattended closure", wireAuto: true, wantAuto: 1},
		{name: "nil AutoSwitch falls back to Switch", wireAuto: false, wantRegular: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := testStore(t)
			saveSnap(t, st, "a", 95)
			saveSnap(t, st, "b", 10)
			auto, regular := 0, 0
			d := &Daemon{
				Store:  st,
				Switch: func(context.Context, string) error { regular++; return nil },
				Active: func(context.Context) string { return "a" },
				Pilot:  fakePolicy{params: pilotapi.ParamsFrom(pilotapi.AutopilotConfig{})},
			}
			if tc.wireAuto {
				d.AutoSwitch = func(context.Context, string) error { auto++; return nil }
			}
			d.init()
			d.maybeRotate(context.Background())
			if auto != tc.wantAuto || regular != tc.wantRegular {
				t.Fatalf("auto=%d regular=%d, want auto=%d regular=%d", auto, regular, tc.wantAuto, tc.wantRegular)
			}
		})
	}
}

// TestMovePartialRetirementEvent: the API surfaces a clone-suspect migration
// as ONE honest event carrying the note — never as a clean success.
func TestMovePartialRetirementEvent(t *testing.T) {
	st := testStore(t)
	note := "The sign-in is in the fleet, but a copy is still readable in /fake/src — llmpilot will not refresh this account until you sign in to it again."
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{fakeDetected("/fake/src", "moved@example.dev")}, nil
		},
		MoveIntoFleet: func(context.Context, detect.Detected, string) (MoveResult, error) {
			return MoveResult{
				Account:      store.Account{ID: "acct-moved", Label: "moved", Email: "moved@example.dev"},
				CloneSuspect: true,
				Note:         note,
			}, nil
		},
	}
	d.init()
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	req, err := http.NewRequest(http.MethodPost, srv.URL+"/v1/adopt/move",
		strings.NewReader(`{"config_dir":"/fake/src"}`))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+d.authToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("status = %d body = %s", resp.StatusCode, body)
	}
	var out struct {
		Outcome string `json:"outcome"`
		Note    string `json:"note"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Outcome != "clone_suspect" || out.Note != note {
		t.Fatalf("response = %s", body)
	}
	evs, err := st.Events(0)
	if err != nil {
		t.Fatal(err)
	}
	moves := 0
	for _, e := range evs {
		if e.Kind == "adopt_move" {
			moves++
			if e.Message != note {
				t.Fatalf("event must carry the honest note, got %q", e.Message)
			}
		}
	}
	if moves != 1 {
		t.Fatalf("want exactly one adopt_move event, got %d (%+v)", moves, evs)
	}
}

// TestMoveRequiresAuth: the destructive migration is token-guarded, while
// additive adopt stays open (the shipped first-run funnel).
func TestMoveRequiresAuth(t *testing.T) {
	d := &Daemon{
		Store: testStore(t),
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{fakeDetected("/fake/src", "x@example.dev")}, nil
		},
		MoveIntoFleet: func(context.Context, detect.Detected, string) (MoveResult, error) {
			t.Fatal("an unauthenticated move reached the switcher")
			return MoveResult{}, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp, err := http.Post(srv.URL+"/v1/adopt/move", "application/json",
		strings.NewReader(`{"config_dir":"/fake/src"}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

// TestStatePinnedIsDerived: every surface gates its Switch verb on the wire
// field `pinned`, and NOTHING writes that field into accounts.json for a real
// account — so State must derive it from the engine's own rule. Without this
// the cockpit and menu bar would keep offering a verb the engine refuses.
func TestStatePinnedIsDerived(t *testing.T) {
	st := testStore(t)
	accs, _ := st.Accounts()
	accs[0].ConfigDir = "/fake/pinned-dir"
	accs[1].ConfigDir = "" // the global swappable slot
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	// The stored rows carry pinned=false — the registry never sets it.
	for _, a := range accs {
		if a.Pinned {
			t.Fatalf("fixture is not representative: %+v", a)
		}
	}
	d := &Daemon{
		Store:  st,
		Pinned: func(a store.Account) bool { return a.ConfigDir == "/fake/pinned-dir" },
	}
	state, err := d.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, a := range state.Accounts {
		got[a.ID] = a.Pinned
	}
	if !got[accs[0].ID] || got[accs[1].ID] {
		t.Fatalf("pinned flags = %+v", got)
	}
	// Deriving must not write back to the registry.
	after, _ := st.Accounts()
	for _, a := range after {
		if a.Pinned {
			t.Fatalf("State wrote the derived flag back to accounts.json: %+v", a)
		}
	}
}

// TestAdoptIdentityFallsBackToDirForIdentitylessRows: a registry row with no
// email carries no identity to match on, so the dir is the only link back to
// the account. Adopting over it would fork a second row for one account.
func TestAdoptIdentityFallsBackToDirForIdentitylessRows(t *testing.T) {
	st := testStore(t)
	if err := st.SaveAccounts([]store.Account{{ID: "legacy", Label: "legacy", ConfigDir: "/fake/legacy-dir"}}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{
		Store: st,
		Detect: func(context.Context) ([]detect.Detected, error) {
			return []detect.Detected{
				fakeDetected("/fake/legacy-dir", "legacy@example.dev"),
				fakeDetected("/fake/other-dir", "other@example.dev"),
			}, nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	for _, r := range getDetect(t, srv) {
		want := r.ConfigDir == "/fake/legacy-dir"
		if r.Registered != want {
			t.Fatalf("row %+v: registered = %v, want %v", r, r.Registered, want)
		}
	}
}

// TestMoveRefusalIsAConflictNotAFault: every refusal the engine makes is a
// decision the user can act on, so it must reach the cockpit as 409 with its
// message intact. A 500 reads as a retryable fault and hides the remedy.
func TestMoveRefusalIsAConflictNotAFault(t *testing.T) {
	// Both directions: a DECISION is 409 with its remedy intact, a genuine
	// FAULT stays 500. Pinning only the first half would let a later change
	// classify every fault as a conflict and nothing would notice.
	for _, tc := range []struct {
		name    string
		err     error
		want    int
		wantMsg string
	}{
		{
			name:    "refusal is a conflict",
			err:     fmt.Errorf("%w: llmpilot could not make sense of what is stored in /fake/global", switcher.ErrMoveRefused),
			want:    http.StatusConflict,
			wantMsg: "could not make sense",
		},
		{
			name:    "fault is a server error",
			err:     errors.New("keychain read for service \"x\" failed"),
			want:    http.StatusInternalServerError,
			wantMsg: "keychain read",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := &Daemon{
				Store: testStore(t),
				Detect: func(context.Context) ([]detect.Detected, error) {
					return []detect.Detected{fakeDetected("/fake/src", "x@example.dev")}, nil
				},
				MoveIntoFleet: func(context.Context, detect.Detected, string) (MoveResult, error) {
					return MoveResult{}, tc.err
				},
			}
			d.init()
			srv := httptest.NewServer(d.Handler())
			defer srv.Close()
			req, err := http.NewRequest(http.MethodPost, srv.URL+"/v1/adopt/move", strings.NewReader(`{"config_dir":"/fake/src"}`))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Authorization", "Bearer "+d.authToken)
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			body, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status = %d, want %d; body = %s", resp.StatusCode, tc.want, body)
			}
			if !strings.Contains(string(body), tc.wantMsg) {
				t.Fatalf("the message did not survive: %s", body)
			}
		})
	}
}
