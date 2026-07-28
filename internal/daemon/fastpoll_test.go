package daemon

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

func TestFastPollOnSwitch(t *testing.T) {
	st := testStore(t)
	polled := map[string]int{}
	active := "a"
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour,
		Fetch: func(_ context.Context, a store.Account) ([]store.Bucket, error) {
			polled[a.ID]++
			return []store.Bucket{{Kind: "five_hour", Percent: 1}}, nil
		},
		Active: func(context.Context) string { return active },
	}
	d.init()
	ctx := context.Background()

	d.pollDue(ctx) // first pass: everyone polled, active observed
	if polled["a"] != 1 || polled["b"] != 1 {
		t.Fatalf("first pass: %v", polled)
	}
	d.pollDue(ctx) // steady state: nothing due
	if polled["b"] != 1 {
		t.Fatalf("steady state repolled: %v", polled)
	}

	// the user /logins over to b, last polled an hour+ ago: next pass
	// pulls b's poll to now. a is untouched.
	active = "b"
	d.mu.Lock()
	d.lastPolled["b"] = time.Now().Add(-2 * time.Hour)
	d.mu.Unlock()
	d.pollDue(ctx)
	if polled["b"] != 2 || polled["a"] != 1 {
		t.Fatalf("switch did not fast-poll b: %v", polled)
	}

	// switching to a FRESHLY polled account keeps etiquette: b was just
	// polled, a's floor is lastPolled+interval — no immediate poll.
	active = "a"
	d.mu.Lock()
	d.lastPolled["a"] = time.Now().Add(-time.Minute)
	d.nextPoll["a"] = time.Now().Add(2 * time.Hour) // pretend far-off slot
	d.mu.Unlock()
	d.pollDue(ctx)
	if polled["a"] != 1 {
		t.Fatalf("fast-poll broke the per-account floor: %v", polled)
	}
	d.mu.Lock()
	next := d.nextPoll["a"]
	d.mu.Unlock()
	if time.Until(next) > time.Hour+time.Minute {
		t.Fatalf("switch did not pull a's slot to its etiquette floor: %v", time.Until(next))
	}
}

func TestCheckUnregisteredSurfacesOncePerEmail(t *testing.T) {
	st := testStore(t)
	email := "new@example.dev"
	var notes []string
	d := &Daemon{
		Store:         st,
		AllowFastPoll: true,
		PollInterval:  time.Hour,
		ActiveEmail:   func(context.Context) string { return email },
		NotifyUser: func(_ context.Context, _, body string) {
			notes = append(notes, body)
		},
	}
	d.init()
	ctx := context.Background()
	accs, _ := st.Accounts()

	d.checkUnregistered(ctx, accs)
	d.checkUnregistered(ctx, accs) // same email: no duplicate
	evs, _ := st.Events(0)
	if len(evs) != 1 || evs[0].Kind != "unregistered" {
		t.Fatalf("want one unregistered event, got %+v", evs)
	}
	// P4: the copy points at the cockpit, not a terminal command — adopt now
	// resolves by identity, so the GUIs can register this sign-in themselves
	// (the old copy existed BECAUSE the cockpit's adopt 409'd on the global dir).
	if len(notes) != 1 || !strings.Contains(notes[0], "Add account") {
		t.Fatalf("notification must point at the cockpit's adopt path, got %v", notes)
	}
	if strings.Contains(notes[0], "llmpilot init") {
		t.Fatalf("notification still sends the user to a terminal: %v", notes)
	}

	// back on a registered account, then a DIFFERENT unknown: fires again.
	email = "a@example.dev"
	d.checkUnregistered(ctx, accs)
	email = "other@example.dev"
	d.checkUnregistered(ctx, accs)
	evs, _ = st.Events(0)
	if len(evs) != 2 {
		t.Fatalf("want two events after second unknown, got %+v", evs)
	}

	// logged out entirely: not "unregistered", nothing fires.
	email = ""
	d.checkUnregistered(ctx, accs)
	if evs, _ = st.Events(0); len(evs) != 2 {
		t.Fatalf("empty email fired an event: %+v", evs)
	}
}
