package main

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/daemon"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// switchHarness wires switchCloser with fakes and records what it did.
type switchHarness struct {
	st         *store.Store
	gotOpts    switcher.KeepWarmOpts
	kwCalls    int
	kwResult   switcher.KeepWarmResult
	kwErr      error
	swapped    []string
	quarantine []string
}

func newSwitchHarness(t *testing.T, accs []store.Account) *switchHarness {
	t.Helper()
	st := store.At(filepath.Join(t.TempDir(), "llmpilot"))
	if err := st.SaveAccounts(accs); err != nil {
		t.Fatal(err)
	}
	return &switchHarness{st: st}
}

func (h *switchHarness) build(reserve int) daemon.Switcher {
	base := switcher.KeepWarmOpts{RefreshLead: daemon.SwitchRefreshLead}
	return switchCloser(h.st,
		func(_ context.Context, _ store.Account, opts switcher.KeepWarmOpts) (switcher.KeepWarmResult, error) {
			h.kwCalls++
			h.gotOpts = opts
			return h.kwResult, h.kwErr
		},
		func(_ context.Context, a store.Account) error {
			h.swapped = append(h.swapped, a.ID)
			return nil
		},
		func(_ context.Context, id, _ string) { h.quarantine = append(h.quarantine, id) },
		base, reserve)
}

// TestAutoSwitchReserve (cmd half): the reserve rides the CALLER's intent.
// The unattended closure carries BudgetReserve=1 into the engine — which is
// what stops an autopilot rotation from spending the user's last 2/24h slot
// (the engine-side guarantee is TestKeepWarmBudgetReserve) — and the user's
// own switch carries 0 so it can still use both.
func TestAutoSwitchReserve(t *testing.T) {
	h := newSwitchHarness(t, []store.Account{{ID: "b", Label: "b", Email: "b@example.dev"}})
	h.kwResult = switcher.KeepWarmResult{Rotated: true}

	if err := h.build(0)(context.Background(), "b"); err != nil {
		t.Fatal(err)
	}
	if h.gotOpts.BudgetReserve != 0 {
		t.Fatalf("the user's switch reserved a slot: %d", h.gotOpts.BudgetReserve)
	}
	if err := h.build(1)(context.Background(), "b"); err != nil {
		t.Fatal(err)
	}
	if h.gotOpts.BudgetReserve != 1 {
		t.Fatalf("the unattended switch did not reserve the user's slot: %d", h.gotOpts.BudgetReserve)
	}
	// Both closures still perform the swap — the reserve changes the freshen's
	// budget arithmetic, never whether the switch happens.
	if len(h.swapped) != 2 {
		t.Fatalf("swapped = %v", h.swapped)
	}
	// And the production lead survives the parameterization (a zero lead would
	// silently disable every switch-time freshen).
	if h.gotOpts.RefreshLead != daemon.SwitchRefreshLead {
		t.Fatalf("lead = %v", h.gotOpts.RefreshLead)
	}
}

// TestSwitchRefusesPinnedBeforeFreshen (cmd half): a pinned target is refused
// BEFORE the freshen — the keep-warm engine is never entered, so no refresh
// POST goes out, no budget is charged, and no config-dir lock is taken. The
// fake refresher fails the test if it is called at all.
func TestSwitchRefusesPinnedBeforeFreshen(t *testing.T) {
	pinnedDir := filepath.Join(t.TempDir(), "claude-pinned")
	h := newSwitchHarness(t, []store.Account{
		{ID: "pinned", Label: "alt", Email: "alt@example.dev", ConfigDir: pinnedDir},
		{ID: "fleet", Label: "main", Email: "main@example.dev"},
	})
	h.kwResult = switcher.KeepWarmResult{Rotated: true}

	err := h.build(0)(context.Background(), "pinned")
	if err == nil {
		t.Fatal("switching to a pinned account must be refused")
	}
	if h.kwCalls != 0 {
		t.Fatalf("the freshen ran for a doomed switch (%d calls) — it spends budget and takes the dir's locks", h.kwCalls)
	}
	if len(h.swapped) != 0 {
		t.Fatalf("swapped = %v", h.swapped)
	}
	if !strings.Contains(err.Error(), "own folder") || !strings.Contains(err.Error(), "move it into the fleet") {
		t.Fatalf("copy must say what the account is for and how to make it switchable: %v", err)
	}

	// A fleet account still goes through the freshen and the swap.
	if err := h.build(0)(context.Background(), "fleet"); err != nil {
		t.Fatal(err)
	}
	if h.kwCalls != 1 || len(h.swapped) != 1 {
		t.Fatalf("kwCalls = %d swapped = %v", h.kwCalls, h.swapped)
	}
}

// TestCloneGuardSkipsAreNews: a withheld freshen must reach the user's feed.
// The clone guard accepts a false-positive class by design, so a silent skip
// is how a fleet goes quietly cold — the previous commit claimed this and did
// not deliver it (re-review OLD-7).
func TestCloneGuardSkipsAreNews(t *testing.T) {
	news := map[string]bool{
		switcher.ReasonRefreshPaused:    true,
		switcher.ReasonBudgetExhausted:  true,
		switcher.ReasonLineageElsewhere: true,
		switcher.ReasonCloneSuspect:     true,
		switcher.ReasonRecordUnreadable: true,
		"not near expiry":               false, // the benign no-op
		"backup is the live credential": false,
	}
	for reason, want := range news {
		if got := refreshSkipIsNews(reason); got != want {
			t.Errorf("refreshSkipIsNews(%q) = %v, want %v", reason, got, want)
		}
		// And every newsworthy reason gets caller-neutral user copy, never a
		// raw engine string.
		if want && refreshSkipReason(reason) == reason {
			t.Errorf("reason %q reaches the user unrewritten", reason)
		}
	}
}
