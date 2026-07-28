package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
	"github.com/alicicek/llmpilot/pilotapi"
)

// stashDaemon wires an in-memory stash behind the daemon's injection points.
func stashDaemon(t *testing.T) (*Daemon, *map[string]pilotapi.StashEntry) {
	t.Helper()
	entries := map[string]pilotapi.StashEntry{}
	d := &Daemon{
		Store: testStore(t),
		StashList: func(context.Context) ([]pilotapi.StashEntry, error) {
			out := []pilotapi.StashEntry{}
			for _, e := range entries {
				out = append(out, e)
			}
			return out, nil
		},
		StashAdopt: func(_ context.Context, fp, label string) (store.Account, error) {
			e := entries[fp]
			delete(entries, fp)
			if label == "" {
				label = e.Label
			}
			return store.Account{ID: "acct-adopted", Label: label, Email: e.Label}, nil
		},
		StashDiscard: func(_ context.Context, fp string) error {
			delete(entries, fp)
			return nil
		},
	}
	d.init()
	return d, &entries
}

func authedJSON(t *testing.T, srv *httptest.Server, token, path, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return resp
}

// TestStashStateNeverNull: the empty stash serializes as [], never null —
// the accounts:null wire kill class, pinned for the new field
// in BOTH the unwired and wired-but-empty cases.
func TestStashStateNeverNull(t *testing.T) {
	for _, wired := range []bool{false, true} {
		var d *Daemon
		if wired {
			d, _ = stashDaemon(t)
		} else {
			d = &Daemon{Store: testStore(t)}
			d.init()
		}
		st, err := d.State(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		data, err := json.Marshal(st)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), `"stash":[]`) {
			t.Fatalf("wired=%v: empty stash must serialize as []: %s", wired, data)
		}
	}
	t.Logf("state.stash serializes as [] in both unwired and empty cases")
}

// TestStashAdoptFlow: adopt registers the account, events it, and the entry
// leaves the stash; the fleet row appears in the next state.
func TestStashAdoptFlow(t *testing.T) {
	d, entries := stashDaemon(t)
	(*entries)["sha256:abc"] = pilotapi.StashEntry{Fingerprint: "sha256:abc", Label: "s@example.dev", StashedAt: time.Now()}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp := authedJSON(t, srv, d.authToken, "/v1/stash/adopt", `{"fingerprint":"sha256:abc"}`)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("adopt status = %d", resp.StatusCode)
	}
	var acct store.Account
	if err := json.NewDecoder(resp.Body).Decode(&acct); err != nil {
		t.Fatal(err)
	}
	if acct.ID != "acct-adopted" {
		t.Fatalf("adopted account = %+v", acct)
	}
	st, err := d.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Stash) != 0 {
		t.Fatalf("stash entry survived adopt: %+v", st.Stash)
	}
	evs, _ := d.Store.Events(5)
	found := false
	for _, e := range evs {
		if e.Kind == "stash_adopt" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no stash_adopt event: %+v", evs)
	}
	t.Logf("adopt: 201, account returned, entry retired, event appended")
}

// TestQuarantinePersistAdoptRefusesDeadLineage: adopting a quarantined fingerprint is
// refused with the honest note — never a silent resurrect.
func TestQuarantinePersistAdoptRefusesDeadLineage(t *testing.T) {
	d, entries := stashDaemon(t)
	(*entries)["sha256:dead"] = pilotapi.StashEntry{Fingerprint: "sha256:dead", Label: "gone@example.dev", StashedAt: time.Now()}
	d.QuarantineDeadLineage(context.Background(), "acct-old", "sha256:dead")
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp := authedJSON(t, srv, d.authToken, "/v1/stash/adopt", `{"fingerprint":"sha256:dead"}`)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("dead adopt status = %d, want 409", resp.StatusCode)
	}
	var body map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if !strings.Contains(body["error"], "dead — needs login") {
		t.Fatalf("refusal copy = %q", body["error"])
	}
	if _, still := (*entries)["sha256:dead"]; !still {
		t.Fatal("refused adopt still consumed the stash entry")
	}
	// The dead flag also rides the state so surfaces can warn pre-click.
	st, _ := d.State(context.Background())
	if len(st.Stash) != 1 || !st.Stash[0].Dead {
		t.Fatalf("state does not flag the dead lineage: %+v", st.Stash)
	}
	t.Logf("dead-lineage adopt refused (409, %q), state flags dead:true", body["error"])
}

// TestStashAdoptConflictMapsTo409: a switcher ErrStashConflict (adopting
// over a newer backup — review P0) surfaces as 409, not 500.
func TestStashAdoptConflictMapsTo409(t *testing.T) {
	d, entries := stashDaemon(t)
	(*entries)["sha256:conf"] = pilotapi.StashEntry{Fingerprint: "sha256:conf", Label: "c@example.dev", StashedAt: time.Now()}
	d.StashAdopt = func(context.Context, string, string) (store.Account, error) {
		return store.Account{}, pilotapi.ErrStashConflict
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp := authedJSON(t, srv, d.authToken, "/v1/stash/adopt", `{"fingerprint":"sha256:conf"}`)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("conflict status = %d, want 409", resp.StatusCode)
	}
	t.Logf("adopt-over-newer-backup mapped to 409")
}

// TestStashUnknownFingerprintMapsTo404: an unknown fingerprint is a 404, not
// a 500 (review P2).
func TestStashUnknownFingerprintMapsTo404(t *testing.T) {
	d, _ := stashDaemon(t)
	d.StashDiscard = func(context.Context, string) error { return switcher.ErrNotFound }
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp := authedJSON(t, srv, d.authToken, "/v1/stash/discard", `{"fingerprint":"sha256:nope"}`)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown-fingerprint status = %d, want 404", resp.StatusCode)
	}
	t.Logf("unknown fingerprint mapped to 404")
}

// TestStashDiscardFlow: discard removes the entry and events it.
func TestStashDiscardFlow(t *testing.T) {
	d, entries := stashDaemon(t)
	(*entries)["sha256:bye"] = pilotapi.StashEntry{Fingerprint: "sha256:bye", StashedAt: time.Now()}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	resp := authedJSON(t, srv, d.authToken, "/v1/stash/discard", `{"fingerprint":"sha256:bye"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("discard status = %d", resp.StatusCode)
	}
	if len(*entries) != 0 {
		t.Fatalf("entry survived discard: %+v", *entries)
	}
	evs, _ := d.Store.Events(5)
	found := false
	for _, e := range evs {
		if e.Kind == "stash_discard" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no stash_discard event: %+v", evs)
	}
	t.Logf("discard: entry and payload removed, event appended")
}

// TestStashMutationsRefuseUnauthenticated is the guard fail-case (CLAUDE.md
// rule): both mutation endpoints 401 without the session token. (The
// guardedRoutes table in auth_test.go covers them too — this pins the
// stash-specific pair explicitly beside their feature tests.)
func TestStashMutationsRefuseUnauthenticated(t *testing.T) {
	d, entries := stashDaemon(t)
	(*entries)["sha256:abc"] = pilotapi.StashEntry{Fingerprint: "sha256:abc", StashedAt: time.Now()}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()
	for _, path := range []string{"/v1/stash/adopt", "/v1/stash/discard"} {
		resp := authedJSON(t, srv, "", path, `{"fingerprint":"sha256:abc"}`)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s unauthenticated status = %d, want 401", path, resp.StatusCode)
		}
	}
	if _, still := (*entries)["sha256:abc"]; !still {
		t.Fatal("unauthenticated request mutated the stash")
	}
	t.Logf("unauthenticated adopt/discard refused (401), stash untouched")
}
