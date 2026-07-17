package daemon

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/store"
)

func TestConfigGetAppliesDefaultsVisibly(t *testing.T) {
	st := testStore(t) // no config.json written — all defaults
	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/config")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	var cfg store.Config
	if err := json.NewDecoder(resp.Body).Decode(&cfg); err != nil {
		t.Fatal(err)
	}
	if len(cfg.Notifications.Thresholds) != 2 || cfg.Notifications.Thresholds[0] != 75 || cfg.Notifications.Thresholds[1] != 90 {
		t.Fatalf("thresholds = %v, want defaults [75 90] filled in", cfg.Notifications.Thresholds)
	}
}

func TestConfigPutValidatesSavesAndNotifies(t *testing.T) {
	st := testStore(t)
	d := &Daemon{Store: st}
	srv := httptest.NewServer(d.Handler())
	defer srv.Close()

	put := func(body string, contentType string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/v1/config", strings.NewReader(body))
		if contentType != "" {
			req.Header.Set("Content-Type", contentType)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	// no Content-Type → 415
	noCT := put(`{}`, "")
	_ = noCT.Body.Close()
	if noCT.StatusCode != http.StatusUnsupportedMediaType {
		t.Fatalf("no content-type status = %d, want 415", noCT.StatusCode)
	}

	// out-of-range threshold → 400
	invalid := put(`{"notifications":{"thresholds":[150]}}`, "application/json")
	_ = invalid.Body.Close()
	if invalid.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid threshold status = %d, want 400", invalid.StatusCode)
	}

	// valid save → 200, persisted sorted, SSE notified
	ch := d.events.subscribe()
	defer d.events.unsubscribe(ch)

	ok := put(`{"notifications":{"thresholds":[90,50]},"plan_cost_monthly":{"a":20.5}}`, "application/json")
	body, _ := io.ReadAll(ok.Body)
	_ = ok.Body.Close()
	if ok.StatusCode != http.StatusOK {
		t.Fatalf("put status = %d, body = %s", ok.StatusCode, body)
	}

	saved, err := st.Config()
	if err != nil {
		t.Fatal(err)
	}
	if len(saved.Notifications.Thresholds) != 2 || saved.Notifications.Thresholds[0] != 50 || saved.Notifications.Thresholds[1] != 90 {
		t.Fatalf("saved thresholds = %v, want sorted [50 90]", saved.Notifications.Thresholds)
	}
	if saved.PlanCostMonthly["a"] != 20.5 {
		t.Fatalf("saved plan cost = %v", saved.PlanCostMonthly)
	}

	select {
	case <-ch:
	default:
		t.Fatal("PUT /v1/config did not push an SSE notify")
	}
}
