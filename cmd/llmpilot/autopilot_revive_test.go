package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// reviveHarness wires reviveSwitch with fakes and records what it did.
type reviveHarness struct {
	gotOpts    switcher.KeepWarmOpts
	kwResult   switcher.KeepWarmResult
	kwErr      error
	swapped    []string
	quarantine []string
}

func (h *reviveHarness) build() daemon.Switcher {
	base := switcher.KeepWarmOpts{RefreshLead: daemon.SwitchRefreshLead} // production default: 10min
	return reviveSwitch(
		func(id string) (store.Account, error) { return store.Account{ID: id, Label: id}, nil },
		func(_ context.Context, _ store.Account, opts switcher.KeepWarmOpts) (switcher.KeepWarmResult, error) {
			h.gotOpts = opts
			return h.kwResult, h.kwErr
		},
		func(_ context.Context, a store.Account) error {
			h.swapped = append(h.swapped, a.ID)
			return nil
		},
		func(_ context.Context, id, _ string) { h.quarantine = append(h.quarantine, id) },
		base,
	)
}

// TestReviveSwitchForcedLead: the 401-class stale account can carry a
// valid-LOOKING future expiry (daemon.go markStale on a 401) — the normal
// 10min lead would skip its refresh and install it on looks. The revive
// lead is forced beyond any real expiry horizon so the POST always goes
// out and the account is proven live or dead.
func TestReviveSwitchForcedLead(t *testing.T) {
	h := &reviveHarness{kwResult: switcher.KeepWarmResult{Rotated: true}}
	if err := h.build()(context.Background(), "b"); err != nil {
		t.Fatal(err)
	}
	// A token expiring 8h out (a fresh CC mint) must still be inside the lead.
	if h.gotOpts.RefreshLead < 24*time.Hour {
		t.Fatalf("revive lead not forced: %v", h.gotOpts.RefreshLead)
	}
	if len(h.swapped) != 1 || h.swapped[0] != "b" {
		t.Fatalf("proven rotation must swap, got %v", h.swapped)
	}
}

// TestReviveSwitchClassification: every non-proven outcome must map to the
// class maybeRotate expects — skips and transients hold, dead quarantines,
// rotation-not-persisted aborts. A wrong class either strands the user on a
// dead session or turns a designed hold into a false alarm.
func TestReviveSwitchClassification(t *testing.T) {
	cases := []struct {
		name       string
		res        switcher.KeepWarmResult
		err        error
		wantHold   bool
		wantSwap   bool
		wantQuar   bool
		wantErrSub string
	}{
		{name: "budget skip holds", res: switcher.KeepWarmResult{Skipped: switcher.ReasonBudgetExhausted + " for this account (1 of 2 slots usable by this caller)"}, wantHold: true, wantErrSub: "autopilot refresh slot is spent"},
		{name: "breaker skip holds", res: switcher.KeepWarmResult{Skipped: switcher.ReasonRefreshPaused + ": the token endpoint rate-limited a refresh at 2026-07-25T02:00:00Z — all refreshes wait out a 24h0m0s local cooldown"}, wantHold: true, wantErrSub: "paused after a rate limit"},
		{name: "no refresh token holds", res: switcher.KeepWarmResult{Skipped: "no refresh token"}, wantHold: true},
		{name: "transient failure holds", err: errors.New("post token: connection refused"), wantHold: true, wantErrSub: "connection refused"},
		{name: "dead lineage quarantines", err: fmt.Errorf("%w: HTTP 400 invalid_grant", switcher.ErrLineageDead), wantQuar: true, wantErrSub: "sign-in expired"},
		{name: "rotation not persisted aborts", err: fmt.Errorf("%w: persist: disk full", switcher.ErrRotationNotPersisted), wantErrSub: "switch aborted"},
		{name: "proven rotation swaps", res: switcher.KeepWarmResult{Rotated: true}, wantSwap: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &reviveHarness{kwResult: tc.res, kwErr: tc.err}
			err := h.build()(context.Background(), "b")
			if got := errors.Is(err, daemon.ErrReviveNotProven); got != tc.wantHold {
				t.Fatalf("ErrReviveNotProven=%v want %v (err %v)", got, tc.wantHold, err)
			}
			if got := len(h.swapped) == 1; got != tc.wantSwap {
				t.Fatalf("swapped=%v want swap %v", h.swapped, tc.wantSwap)
			}
			if got := len(h.quarantine) == 1; got != tc.wantQuar {
				t.Fatalf("quarantine=%v want %v", h.quarantine, tc.wantQuar)
			}
			if !tc.wantSwap && err == nil {
				t.Fatal("non-proven outcome returned nil error")
			}
			if tc.wantErrSub != "" && !strings.Contains(err.Error(), tc.wantErrSub) {
				t.Fatalf("error %q missing %q", err, tc.wantErrSub)
			}
		})
	}
}

// TestFreshenSkippedMessage: the budget/breaker-skip event lands BEFORE the
// swap runs — its copy must never claim a switch that may still fail
// (P3 audit nit; the old copy said "Switched" past-tense).
func TestFreshenSkippedMessage(t *testing.T) {
	msg := freshenSkippedMessage("refresh paused after a rate limit")
	if !strings.HasPrefix(msg, "Switching on the stored sign-in — ") {
		t.Fatalf("unexpected copy: %q", msg)
	}
	if strings.Contains(msg, "Switched") {
		t.Fatalf("copy claims a completed switch before Swap ran: %q", msg)
	}
}

// TestRefreshSkipReason asserts the caller-side rewrite. Drift safety comes
// from the shared switcher.Reason* constants, which both the engine's
// Sprintf and this matcher build on — the suffixes here are illustrative
// only (the real-engine exhaustion path is driven by
// TestKeepWarmBudgetReserve in internal/switcher). The rewrite must carry
// no caller-specific consequence clause and no raw Go duration (VOICE.md,
// review P1-1).
func TestRefreshSkipReason(t *testing.T) {
	for _, raw := range []string{
		switcher.ReasonBudgetExhausted + " for this account (1 of 2 slots usable by this caller)",
		switcher.ReasonRefreshPaused + ": the token endpoint rate-limited a refresh at 2026-07-25T02:00:00Z — all refreshes wait out a 24h0m0s local cooldown",
	} {
		got := refreshSkipReason(raw)
		if strings.Contains(got, "swap proceeds") || strings.Contains(got, "24h0m0s") || strings.Contains(got, "slots usable") {
			t.Fatalf("engine internals leak into user copy: %q", got)
		}
	}
	if got := refreshSkipReason(switcher.ReasonBudgetExhausted + " for this account"); got != "its refresh budget is spent for now" {
		t.Fatalf("budget copy: %q", got)
	}
	if got := refreshSkipReason(switcher.ReasonRefreshPaused + ": details"); got != "refreshes are paused after a rate limit" {
		t.Fatalf("breaker copy: %q", got)
	}
	if got := refreshSkipReason("no refresh token"); got != "no refresh token" {
		t.Fatalf("pass-through broken: %q", got)
	}
}
