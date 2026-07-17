package anthropic

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const fakeRefreshToken = "sk-ant-ort01-FAKEROTATEFAKEROTATE"

func TestRefreshRequestShapeAndRotation(t *testing.T) {
	var gotMethod, gotPath, gotCT, gotUA string
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotCT = r.Header.Get("Content-Type")
		gotUA = r.Header.Get("User-Agent")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		_, _ = w.Write([]byte(`{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"scope":"user:inference user:profile"}`))
	}))
	defer srv.Close()

	now := time.Date(2026, 7, 16, 12, 0, 0, 0, time.UTC)
	c := &RefreshClient{
		BaseURL:   srv.URL,
		UserAgent: "claude-code/2.1.205",
		Now:       func() time.Time { return now },
	}
	res, err := c.Refresh(context.Background(), fakeRefreshToken)
	if err != nil {
		t.Fatal(err)
	}

	if gotMethod != http.MethodPost || gotPath != "/v1/oauth/token" {
		t.Errorf("request = %s %s", gotMethod, gotPath)
	}
	if gotCT != "application/json" {
		t.Errorf("Content-Type = %q", gotCT)
	}
	if gotUA != "claude-code/2.1.205" {
		t.Errorf("User-Agent = %q", gotUA)
	}
	want := map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": fakeRefreshToken,
		"client_id":     refreshClientID,
	}
	for k, v := range want {
		if gotBody[k] != v {
			t.Errorf("body[%s] = %q, want %q", k, gotBody[k], v)
		}
	}
	if res.AccessToken != "new-access" || res.RefreshToken != "new-refresh" {
		t.Errorf("result tokens = %q/%q", res.AccessToken, res.RefreshToken)
	}
	if !res.ExpiresAt.Equal(now.Add(time.Hour)) {
		t.Errorf("ExpiresAt = %v, want %v", res.ExpiresAt, now.Add(time.Hour))
	}
	if len(res.Scopes) != 2 || res.Scopes[0] != "user:inference" {
		t.Errorf("Scopes = %v", res.Scopes)
	}
}

func TestRefreshWithoutRotationKeepsEmptyRefreshToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"new-access","expires_in":3600}`))
	}))
	defer srv.Close()

	c := &RefreshClient{BaseURL: srv.URL}
	res, err := c.Refresh(context.Background(), fakeRefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if res.RefreshToken != "" {
		t.Errorf("RefreshToken = %q, want empty (server did not rotate)", res.RefreshToken)
	}
}

func TestRefreshErrorClassification(t *testing.T) {
	cases := []struct {
		name      string
		status    int
		body      string
		permanent bool
		code      string
	}{
		{"invalid_grant 400", 400, `{"error":"invalid_grant","error_description":"Refresh token not found"}`, true, "invalid_grant"},
		{"invalid_client 401", 401, `{"error":"invalid_client"}`, true, "invalid_client"},
		{"invalid_grant substring", 403, `oops invalid_grant oops`, true, "invalid_grant"},
		{"other 400", 400, `{"error":"server_error"}`, false, "server_error"},
		{"429 stays transient", 429, ``, false, ""},
		{"500 with marker stays transient", 500, `{"error":"invalid_grant"}`, false, "invalid_grant"},
		{"hostile code dropped", 400, `{"error":"<script>alert(1)</script>"}`, false, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			c := &RefreshClient{BaseURL: srv.URL}
			_, err := c.Refresh(context.Background(), fakeRefreshToken)
			var re *RefreshError
			if !errors.As(err, &re) {
				t.Fatalf("err = %v, want *RefreshError", err)
			}
			if re.StatusCode != tc.status || re.Code != tc.code {
				t.Errorf("RefreshError = %d/%q, want %d/%q", re.StatusCode, re.Code, tc.status, tc.code)
			}
			if re.Permanent() != tc.permanent {
				t.Errorf("Permanent() = %v, want %v", re.Permanent(), tc.permanent)
			}
		})
	}
}

func TestRefreshTokenNeverInErrors(t *testing.T) {
	// The failure body echoes the token; the error string must not.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(400)
		_, _ = w.Write([]byte(`{"error":"invalid_grant","echo":"` + fakeRefreshToken + `"}`))
	}))
	defer srv.Close()

	c := &RefreshClient{BaseURL: srv.URL}
	_, err := c.Refresh(context.Background(), fakeRefreshToken)
	if err == nil {
		t.Fatal("want error")
	}
	if strings.Contains(err.Error(), fakeRefreshToken) {
		t.Errorf("error leaks the refresh token: %v", err)
	}

	// Malformed success responses must not leak either.
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"refresh_token":"` + fakeRefreshToken + `","expires_in":3600}`))
	}))
	defer srv2.Close()
	c2 := &RefreshClient{BaseURL: srv2.URL}
	_, err = c2.Refresh(context.Background(), fakeRefreshToken)
	if err == nil || strings.Contains(err.Error(), fakeRefreshToken) {
		t.Errorf("malformed-response error = %v (must exist, must not leak)", err)
	}
}

func TestRefreshRejectsEmptyRefreshToken(t *testing.T) {
	c := &RefreshClient{BaseURL: "http://127.0.0.1:0"}
	if _, err := c.Refresh(context.Background(), ""); err == nil {
		t.Fatal("want error for empty refresh token")
	}
}

func TestRefreshInterlockRefusesProductionUnderTest(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	c := &RefreshClient{} // default BaseURL = production
	_, err := c.Refresh(context.Background(), fakeRefreshToken)
	if err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Fatalf("err = %v, want interlock refusal", err)
	}
}

func TestRefreshInterlockAllowsTestServerUnderTest(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"a","expires_in":60}`))
	}))
	defer srv.Close()
	c := &RefreshClient{BaseURL: srv.URL}
	if _, err := c.Refresh(context.Background(), fakeRefreshToken); err != nil {
		t.Fatal(err)
	}
}
