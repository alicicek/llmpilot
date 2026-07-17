package daemon

import (
	"context"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

func TestEntitlementCheckPiggybackIsNonBlockingAndCoalesced(t *testing.T) {
	d := &Daemon{
		Store:         testStore(t),
		AllowFastPoll: true,
		PollInterval:  time.Hour,
		Fetch: func(context.Context, store.Account) ([]store.Bucket, error) {
			return []store.Bucket{{Kind: "five_hour", Percent: 10}}, nil
		},
		EntitlementDue: func(time.Time) bool { return true },
		Revalidate: func(context.Context) (EntitlementValidation, error) {
			t.Fatal("revalidation ran synchronously on poll path")
			return EntitlementValidation{}, nil
		},
	}
	d.init()
	d.revalidateCh <- struct{}{} // already queued: another fleet poll coalesces
	start := time.Now()
	d.pollOne(context.Background(), store.Account{ID: "a"})
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("successful usage poll blocked on entitlement check for %s", elapsed)
	}
	if len(d.revalidateCh) != 1 {
		t.Fatalf("revalidation queue len = %d, want one coalesced item", len(d.revalidateCh))
	}
}

func TestEntitlementRevocationPausesAndNotifiesOnce(t *testing.T) {
	st := testStore(t)
	d := &Daemon{
		Store: st,
		Revalidate: func(context.Context) (EntitlementValidation, error) {
			return EntitlementValidation{Status: "revoked"}, nil
		},
	}
	d.init()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.entitlementLoop(ctx)
	d.revalidateCh <- struct{}{}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		st, err := d.State(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if st.License == "revoked" {
			events, err := d.Store.Events(10)
			if err != nil {
				t.Fatal(err)
			}
			if len(events) == 0 {
				time.Sleep(5 * time.Millisecond)
				continue
			}
			if len(events) != 1 || events[0].Kind != "license_revoked" {
				t.Fatalf("events = %+v, want one license_revoked", events)
			}
			// Same authoritative state does not append or notify again.
			d.revalidateCh <- struct{}{}
			time.Sleep(20 * time.Millisecond)
			events, err = d.Store.Events(10)
			if err != nil {
				t.Fatal(err)
			}
			if len(events) != 1 {
				t.Fatalf("repeat revoke appended events: %+v", events)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("revocation did not reach daemon state")
}
