package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// TestPollOneAppendsHistoryAndFiresThresholds proves the real poll path (not
// just checkThresholds/appendHistory called directly) wires both features:
// a poll appends a burn-rate sample, and a rising crossing across two real
// polls fires a notification.
func TestPollOneAppendsHistoryAndFiresThresholds(t *testing.T) {
	st := testStore(t)
	if err := st.SaveConfig(store.Config{Notifications: store.NotificationsConfig{Thresholds: []float64{75}}}); err != nil {
		t.Fatal(err)
	}
	rz := time.Now().Add(4 * time.Hour)
	percent := 50.0
	var notes []notification
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour,
		Fetch: func(context.Context, store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "session", Percent: percent, ResetsAt: &rz}}, nil
		},
		NotifyUser: func(_ context.Context, title, body string) {
			notes = append(notes, notification{title, body})
		},
	}
	d.init()
	accs, err := st.Accounts()
	if err != nil {
		t.Fatal(err)
	}

	d.pollOne(context.Background(), accs[0])
	if got := d.History(accs[0].ID, "session", ""); len(got) != 1 || got[0].Percent != 50 {
		t.Fatalf("history after first poll = %+v", got)
	}
	if len(notes) != 0 {
		t.Fatalf("first poll (no prior baseline) fired: %+v", notes)
	}

	percent = 80
	d.pollOne(context.Background(), accs[0])
	if got := d.History(accs[0].ID, "session", ""); len(got) != 2 || got[1].Percent != 80 {
		t.Fatalf("history after second poll = %+v", got)
	}
	if len(notes) != 1 {
		t.Fatalf("crossing poll notes = %+v, want 1", notes)
	}
}
