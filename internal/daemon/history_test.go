package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHistoryRequiresParams(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	cases := []string{
		"/v1/history",
		"/v1/history?account_id=a",
		"/v1/history?kind=session",
	}
	for _, path := range cases {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s status = %d, want 400", path, resp.StatusCode)
		}
	}
}

func TestHistoryEmptyIsEmptyArray(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/history?account_id=a&kind=session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var out struct {
		Samples []HistorySample `json:"samples"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Samples == nil || len(out.Samples) != 0 {
		t.Fatalf("samples = %+v, want empty non-nil slice", out.Samples)
	}
}

func TestHistoryAppendAndCap(t *testing.T) {
	d := &Daemon{}
	d.init()
	key := historyKey("a", "session", "")
	for i := 0; i < historyCap+50; i++ {
		d.appendHistory(key, HistorySample{At: time.Now(), Percent: float64(i)})
	}
	got := d.History("a", "session", "")
	if len(got) != historyCap {
		t.Fatalf("len = %d, want cap %d", len(got), historyCap)
	}
	// oldest dropped: the ring keeps the LAST historyCap samples.
	if got[0].Percent != 50 {
		t.Fatalf("oldest surviving sample = %v, want Percent 50", got[0])
	}
	if got[len(got)-1].Percent != float64(historyCap+49) {
		t.Fatalf("newest sample = %v", got[len(got)-1])
	}
}

func TestHistoryEndpointServesAppendedSamples(t *testing.T) {
	d := &Daemon{Store: testStore(t)}
	d.init()
	d.appendHistory(historyKey("a", "session", ""), HistorySample{At: time.Now(), Percent: 42})
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/history?account_id=a&kind=session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var out struct {
		Samples []HistorySample `json:"samples"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if len(out.Samples) != 1 || out.Samples[0].Percent != 42 {
		t.Fatalf("samples = %+v", out.Samples)
	}

	// A different scope must not see it.
	resp2, err := http.Get(srv.URL + "/v1/history?account_id=a&kind=session&scope=Opus")
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close() //nolint:errcheck // test
	var out2 struct {
		Samples []HistorySample `json:"samples"`
	}
	if err := json.NewDecoder(resp2.Body).Decode(&out2); err != nil {
		t.Fatal(err)
	}
	if len(out2.Samples) != 0 {
		t.Fatalf("scoped samples = %+v, want none", out2.Samples)
	}
}
