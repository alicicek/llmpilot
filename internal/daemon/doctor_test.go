package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/doctor"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// doctorKeychain answers with llmpilot's own backup payloads and fails the
// test on any other service — the same posture the engine's own test proves,
// asserted again at the wiring level.
type doctorKeychain struct {
	t     *testing.T
	items map[string]string
}

func (k doctorKeychain) GetAccount(_ context.Context, service, account string) ([]byte, error) {
	if service != switcher.BackupService {
		k.t.Fatalf("the endpoint read Keychain service %q", service)
	}
	raw, ok := k.items[account]
	if !ok {
		return nil, http.ErrNoLocation
	}
	return []byte(raw), nil
}

func doctorDaemon(t *testing.T) *Daemon {
	t.Helper()
	st := testStore(t)
	d := &Daemon{
		Store: st,
		DoctorReaders: DoctorLocal{
			Backups: doctorKeychain{t: t, items: map[string]string{
				// Both accounts carry the SAME account uuid and the same
				// organization: one duplicate finding, and the credential
				// bytes below must never leave the Keychain.
				"a": `{"credential":{"accessToken":"SECRET-TOKEN-VALUE"},"oauthAccount":{"accountUuid":"same","emailAddress":"a@example.dev","organizationUuid":"org-1"}}`,
				"b": `{"credential":{"accessToken":"SECRET-TOKEN-VALUE"},"oauthAccount":{"accountUuid":"same","emailAddress":"b@example.dev","organizationUuid":"org-1"}}`,
			}},
			Foreign: func(context.Context) ([]switcher.ForeignSignIn, error) {
				return []switcher.ForeignSignIn{{Dir: "/Users/x/.claude-other", Email: "a@example.dev"}}, nil
			},
			Budget: func() (switcher.BudgetSnapshot, error) { return switcher.BudgetSnapshot{}, nil },
			Install: func() (doctor.InstallFacts, error) {
				return doctor.InstallFacts{LaunchAgentInstalled: true, StatusLine: doctor.StatusLineOurs}, nil
			},
		},
		MovedDirs: func(context.Context) (map[string]bool, error) { return map[string]bool{}, nil },
		Pinned:    func(store.Account) bool { return false },
		NowFn:     func() time.Time { return time.Date(2026, 7, 26, 14, 32, 0, 0, time.UTC) },
		StashList: func(context.Context) ([]pilotapi.StashEntry, error) {
			return []pilotapi.StashEntry{{Fingerprint: "FINGERPRINT-VALUE", Label: "kept", StashedAt: time.Now()}}, nil
		},
	}
	d.init()
	// One frozen account, so the payload carries a daemon-only finding too.
	d.mu.Lock()
	d.stale["b"] = time.Now()
	d.mu.Unlock()
	return d
}

// TestDoctorEndpoint proves GET /v1/doctor serves exactly what the shared
// engine produces (one check engine, two callers), that nothing on the wire is
// null, and that no token, fingerprint or credential byte reaches the payload.
func TestDoctorEndpoint(t *testing.T) {
	d := doctorDaemon(t)
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/doctor")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}

	// Same engine, same answer: the endpoint is not a second implementation.
	var served doctor.Report
	if err := json.Unmarshal(body, &served); err != nil {
		t.Fatalf("decode: %v", err)
	}
	direct := d.Doctor(context.Background())
	if !reflect.DeepEqual(served.Findings, direct.Findings) {
		t.Errorf("the endpoint's findings differ from the engine's:\n served: %+v\n engine: %+v", served.Findings, direct.Findings)
	}
	if !reflect.DeepEqual(served.Checks, direct.Checks) {
		t.Errorf("the endpoint's checks differ from the engine's")
	}
	if served.Clean != direct.Clean || served.Problems != direct.Problems {
		t.Errorf("clean/problems differ: %v/%d vs %v/%d", served.Clean, served.Problems, direct.Clean, direct.Problems)
	}
	if len(served.Findings) == 0 {
		t.Fatal("the endpoint served no findings on a fleet with a duplicate identity")
	}

	// Never null — the wire kill that took out a whole surface once (W11).
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"findings", "checks"} {
		if string(raw[key]) == "null" || raw[key] == nil {
			t.Errorf("%s serialized as %s — every list on the wire is never null", key, raw[key])
		}
	}
	for _, f := range served.Findings {
		if f.Accounts == nil {
			t.Errorf("%s: accounts serialized as null", f.ID)
		}
	}

	// No secret material anywhere in the payload.
	for _, secret := range []string{"SECRET-TOKEN-VALUE", "FINGERPRINT-VALUE", "accessToken", "credential"} {
		if strings.Contains(string(body), secret) {
			t.Errorf("the payload carries %q", secret)
		}
	}

	// An EMPTY fleet still decodes: findings/checks are arrays, not null.
	empty := &Daemon{Store: store.At(t.TempDir())}
	esrv := httptest.NewServer(empty.Handler())
	defer esrv.Close()
	eresp, err := http.Get(esrv.URL + "/v1/doctor")
	if err != nil {
		t.Fatal(err)
	}
	defer eresp.Body.Close() //nolint:errcheck // test
	ebody, err := io.ReadAll(eresp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(ebody), `"findings":null`) || strings.Contains(string(ebody), `"checks":null`) {
		t.Errorf("empty fleet served nulls: %s", ebody)
	}
}

// TestDoctorDegraded is the daemon-side half of the honesty rule: the shared
// assembler with no daemon facts marks every daemon-only check NOT CHECKED,
// and such a report is never clean. This is what `llmpilot doctor` runs when
// nothing answers on the socket.
func TestDoctorDegraded(t *testing.T) {
	st := testStore(t)
	local := DoctorLocal{
		Install: func() (doctor.InstallFacts, error) {
			return doctor.InstallFacts{LaunchAgentInstalled: true, StatusLine: doctor.StatusLineOurs}, nil
		},
		Foreign: func(context.Context) ([]switcher.ForeignSignIn, error) { return nil, nil },
		Budget:  func() (switcher.BudgetSnapshot, error) { return switcher.BudgetSnapshot{}, nil },
		Backups: doctorKeychain{t: t, items: map[string]string{
			"a": `{"oauthAccount":{"accountUuid":"a","emailAddress":"a@example.dev","organizationUuid":"org-a"}}`,
			"b": `{"oauthAccount":{"accountUuid":"b","emailAddress":"b@example.dev","organizationUuid":"org-b"}}`,
		}},
	}
	in := DoctorInputs(st, func(store.Account) bool { return false },
		func(context.Context) (map[string]bool, error) { return map[string]bool{}, nil },
		local, time.Now)
	if in.Daemon != nil {
		t.Fatal("the shared assembler must leave the daemon facts to the daemon itself")
	}
	rep := doctor.Run(context.Background(), in)

	if len(rep.Findings) == 0 || rep.Findings[0].ID != "daemon_down" {
		t.Fatalf("the daemon being down must be the first finding, got %+v", rep.Findings)
	}
	for _, c := range rep.Checks {
		switch c.ID {
		case doctor.CheckFrozen, doctor.CheckDeadSignIns, doctor.CheckKeptSignIns:
			if c.State != doctor.StateNotChecked {
				t.Errorf("%s = %q with no daemon, want not_checked", c.ID, c.State)
			}
		}
	}
	if rep.Clean {
		t.Error("a degraded sweep printed a clean bill")
	}

	// The live daemon, by contrast, DOES answer those checks — proving the
	// not-checked results above come from the missing daemon, not from a
	// check that never runs.
	d := doctorDaemon(t)
	live := d.Doctor(context.Background())
	for _, c := range live.Checks {
		switch c.ID {
		case doctor.CheckFrozen, doctor.CheckDeadSignIns, doctor.CheckKeptSignIns:
			if c.State == doctor.StateNotChecked {
				t.Errorf("%s is not_checked even with a live daemon: %s", c.ID, c.Why)
			}
		}
	}
}

// TestDoctorUnwiredReadersNeverPass proves the "not wired" discipline: a
// daemon with no injected readers reports NOT CHECKED rather than passing
// those checks — an unwired build must not look like a healthy one.
func TestDoctorUnwiredReadersNeverPass(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	rep := d.Doctor(context.Background())
	for _, id := range []string{
		doctor.CheckLoginItem, doctor.CheckStatusLine, doctor.CheckSharedPool,
		doctor.CheckOtherSignIns, doctor.CheckRefreshBudget,
		// The review's half-blind classes: an unwired stash is not an empty
		// one, an unreadable identity leaves the duplicate check half-run, and
		// with no pinned rule a watched lane cannot be told from a switchable
		// one.
		doctor.CheckKeptSignIns, doctor.CheckDuplicates, doctor.CheckWatchedLanes,
	} {
		var found bool
		for _, c := range rep.Checks {
			if c.ID != id {
				continue
			}
			found = true
			if c.State != doctor.StateNotChecked {
				t.Errorf("%s = %q with no reader wired, want not_checked", id, c.State)
			}
		}
		if !found {
			t.Errorf("%s missing from the coverage list", id)
		}
	}
	if rep.Clean {
		t.Error("an unwired daemon reported a clean bill")
	}
}
