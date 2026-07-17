package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestStateCarriesSchedulesNeverNull proves State().Schedules is an empty
// array (not null) with no schedules registered, and reflects schedules.json
// once one is added — no daemon-side watcher needed, State reads fresh.
func TestStateCarriesSchedulesNeverNull(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/state")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	body, _ := io.ReadAll(resp.Body)
	if strings.Contains(string(body), `"schedules":null`) {
		t.Fatalf("schedules must never be null: %s", body)
	}
	var got State
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Schedules) != 0 {
		t.Fatalf("want no schedules, got %+v", got.Schedules)
	}

	if err := st.SaveSchedules([]store.Schedule{{ID: "a-0900", AccountID: "a", Hour: 9, Minute: 0}}); err != nil {
		t.Fatal(err)
	}
	stt, err := d.State(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(stt.Schedules) != 1 || stt.Schedules[0].ID != "a-0900" {
		t.Fatalf("CLI-side schedule edit not surfaced: %+v", stt.Schedules)
	}
}

func TestScheduleCRUD(t *testing.T) {
	st := testStore(t)
	var wakeCalls int
	d := &Daemon{
		Store: st,
		WakeSync: func(context.Context, time.Time) error {
			wakeCalls++
			return nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	// GET on an empty registry: empty array, not null.
	resp, err := http.Get(srv.URL + "/v1/schedules")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if strings.TrimSpace(string(body)) != "[]" {
		t.Fatalf("empty schedules body = %s, want []", body)
	}

	// POST without Content-Type: application/json → 415.
	bad, err := http.Post(srv.URL+"/v1/schedules", "text/plain", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = bad.Body.Close()
	if bad.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("no content-type status = %d, want 415", bad.StatusCode)
	}

	// POST for an unknown account → 404.
	notFound, err := http.Post(srv.URL+"/v1/schedules", "application/json",
		strings.NewReader(`{"account_id":"nope","hour":9,"minute":0}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = notFound.Body.Close()
	if notFound.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown account status = %d, want 404", notFound.StatusCode)
	}

	// POST with an out-of-range time → 400.
	invalid, err := http.Post(srv.URL+"/v1/schedules", "application/json",
		strings.NewReader(`{"account_id":"a","hour":99,"minute":0}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = invalid.Body.Close()
	if invalid.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid time status = %d, want 400", invalid.StatusCode)
	}

	// POST a valid schedule → 201, created doc, WakeSync + notify fired.
	created, err := http.Post(srv.URL+"/v1/schedules", "application/json",
		strings.NewReader(`{"account_id":"a","hour":9,"minute":0}`))
	if err != nil {
		t.Fatal(err)
	}
	cbody, _ := io.ReadAll(created.Body)
	_ = created.Body.Close()
	if created.StatusCode != http.StatusCreated {
		t.Fatalf("create status = %d, body = %s", created.StatusCode, cbody)
	}
	var sched store.Schedule
	if err := json.Unmarshal(cbody, &sched); err != nil {
		t.Fatal(err)
	}
	if sched.ID == "" || sched.AccountID != "a" || sched.Hour != 9 {
		t.Fatalf("created schedule = %+v", sched)
	}
	if wakeCalls != 1 {
		t.Fatalf("wakeCalls = %d, want 1 after create", wakeCalls)
	}

	// Duplicate create (same account+time → same ID) → 409.
	dup, err := http.Post(srv.URL+"/v1/schedules", "application/json",
		strings.NewReader(`{"account_id":"a","hour":9,"minute":0}`))
	if err != nil {
		t.Fatal(err)
	}
	_ = dup.Body.Close()
	if dup.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate create status = %d, want 409", dup.StatusCode)
	}

	// PUT moves it.
	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/v1/schedules/"+sched.ID,
		strings.NewReader(`{"hour":10,"minute":30}`))
	req.Header.Set("Content-Type", "application/json")
	putResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	pbody, _ := io.ReadAll(putResp.Body)
	_ = putResp.Body.Close()
	if putResp.StatusCode != http.StatusOK {
		t.Fatalf("put status = %d, body = %s", putResp.StatusCode, pbody)
	}
	var moved store.Schedule
	if err := json.Unmarshal(pbody, &moved); err != nil {
		t.Fatal(err)
	}
	if moved.Hour != 10 || moved.Minute != 30 {
		t.Fatalf("moved schedule = %+v", moved)
	}
	if wakeCalls != 2 {
		t.Fatalf("wakeCalls = %d, want 2 after move", wakeCalls)
	}

	// PUT on an unknown id → 404.
	req2, _ := http.NewRequest(http.MethodPut, srv.URL+"/v1/schedules/nope",
		strings.NewReader(`{"hour":1,"minute":0}`))
	req2.Header.Set("Content-Type", "application/json")
	putBad, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	_ = putBad.Body.Close()
	if putBad.StatusCode != http.StatusNotFound {
		t.Fatalf("put unknown id status = %d, want 404", putBad.StatusCode)
	}

	// DELETE without Content-Type → 415.
	delReq, _ := http.NewRequest(http.MethodDelete, srv.URL+"/v1/schedules/"+sched.ID, nil)
	delNoCT, err := http.DefaultClient.Do(delReq)
	if err != nil {
		t.Fatal(err)
	}
	_ = delNoCT.Body.Close()
	if delNoCT.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("delete no content-type status = %d, want 415", delNoCT.StatusCode)
	}

	// DELETE an unknown id → 404.
	delBadReq, _ := http.NewRequest(http.MethodDelete, srv.URL+"/v1/schedules/nope", nil)
	delBadReq.Header.Set("Content-Type", "application/json")
	delBad, err := http.DefaultClient.Do(delBadReq)
	if err != nil {
		t.Fatal(err)
	}
	_ = delBad.Body.Close()
	if delBad.StatusCode != http.StatusNotFound {
		t.Fatalf("delete unknown id status = %d, want 404", delBad.StatusCode)
	}

	// DELETE the real one → 200, gone from the registry.
	delReq2, _ := http.NewRequest(http.MethodDelete, srv.URL+"/v1/schedules/"+sched.ID, nil)
	delReq2.Header.Set("Content-Type", "application/json")
	delOK, err := http.DefaultClient.Do(delReq2)
	if err != nil {
		t.Fatal(err)
	}
	_ = delOK.Body.Close()
	if delOK.StatusCode != http.StatusOK {
		t.Fatalf("delete status = %d", delOK.StatusCode)
	}
	if wakeCalls != 3 {
		t.Fatalf("wakeCalls = %d, want 3 after delete", wakeCalls)
	}
	scheds, err := st.Schedules()
	if err != nil {
		t.Fatal(err)
	}
	if len(scheds) != 0 {
		t.Fatalf("schedule not removed: %+v", scheds)
	}
}

// TestScheduleMutationsSyncLaunchdBeforeSave pins the Greptile P1
// (2026-07-11): every cockpit schedule write mirrors into launchd BEFORE it
// persists — create, move, and delete each call TriggerSync with the next
// set, and a sync failure aborts the mutation with disk untouched.
func TestScheduleMutationsSyncLaunchdBeforeSave(t *testing.T) {
	st := testStore(t)
	var synced [][]store.Schedule
	failNext := false
	d := &Daemon{
		Store: st,
		TriggerSync: func(_ context.Context, scheds []store.Schedule) error {
			if failNext {
				return context.DeadlineExceeded
			}
			cp := make([]store.Schedule, len(scheds))
			copy(cp, scheds)
			synced = append(synced, cp)
			return nil
		},
	}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	post := func(body string) *http.Response {
		resp, err := http.Post(srv.URL+"/v1/schedules", "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp
	}

	// create syncs the set including the new schedule
	if resp := post(`{"account_id":"a","hour":9,"minute":0}`); resp.StatusCode != http.StatusCreated {
		t.Fatalf("create: %d", resp.StatusCode)
	}
	if len(synced) != 1 || len(synced[0]) != 1 || synced[0][0].Hour != 9 {
		t.Fatalf("create did not sync launchd with the new set: %+v", synced)
	}

	// move syncs the updated set
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPut,
		srv.URL+"/v1/schedules/"+synced[0][0].ID, strings.NewReader(`{"hour":10,"minute":30}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(synced) != 2 || synced[1][0].Hour != 10 {
		t.Fatalf("move did not sync launchd: status %d, synced %+v", resp.StatusCode, synced)
	}

	// a failing sync aborts the mutation and leaves disk untouched
	failNext = true
	if resp := post(`{"account_id":"a","hour":11,"minute":0}`); resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("failed sync must 502, got %d", resp.StatusCode)
	}
	scheds, _ := st.Schedules()
	if len(scheds) != 1 {
		t.Fatalf("failed sync persisted anyway: %+v", scheds)
	}
	failNext = false

	// delete syncs the set without the schedule
	del, _ := http.NewRequestWithContext(context.Background(), http.MethodDelete,
		srv.URL+"/v1/schedules/"+scheds[0].ID, nil)
	del.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(del)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK || len(synced) != 3 || len(synced[2]) != 0 {
		t.Fatalf("delete did not sync launchd with the emptied set: status %d, synced %+v", resp2.StatusCode, synced)
	}
}

// TestScheduleSameLabelAccountsCoexist pins the Greptile P1 id-collision
// (2026-07-11): two accounts whose labels sanitize identically can both book
// the same wall-clock time — the second gets an account-disambiguated ID.
func TestScheduleSameLabelAccountsCoexist(t *testing.T) {
	st := store.At(t.TempDir())
	if err := st.SaveAccounts([]store.Account{
		{ID: "acct-one", Label: "work", Email: "one@example.dev"},
		{ID: "acct-two", Label: "work!", Email: "two@example.dev"}, // sanitizes to "work-"… same prefix family
		{ID: "acct-three", Label: "work", Email: "three@example.dev"},
	}); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	create := func(acct string) (int, store.Schedule) {
		resp, err := http.Post(srv.URL+"/v1/schedules", "application/json",
			strings.NewReader(`{"account_id":"`+acct+`","hour":9,"minute":0}`))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close() //nolint:errcheck // test
		var sc store.Schedule
		_ = json.NewDecoder(resp.Body).Decode(&sc)
		return resp.StatusCode, sc
	}

	code1, sc1 := create("acct-one")
	code2, sc2 := create("acct-three") // identical label "work", same time
	if code1 != http.StatusCreated || code2 != http.StatusCreated {
		t.Fatalf("same-label accounts must both book 09:00: %d, %d", code1, code2)
	}
	if sc1.ID == sc2.ID {
		t.Fatalf("colliding schedule IDs: %q == %q", sc1.ID, sc2.ID)
	}
	// the same account re-booking the same time still conflicts
	if code, _ := create("acct-one"); code != http.StatusConflict {
		t.Fatalf("same-account duplicate must 409, got %d", code)
	}
}
