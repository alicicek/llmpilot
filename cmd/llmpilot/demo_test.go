package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// demoStoreHome must only hand back LLMPILOT_HOME under the exact
// LLMPILOT_TEST=1 gate, and must REFUSE (error, never a silent mktemp
// fallback) any target that is — or sits under — the user home: SeedDemo
// atomically overwrites accounts.json, so a home target would destroy the
// live fleet registry. The refusal must hold by inode identity (firmlinks,
// symlinked parents, case variants), not just string spelling. Tests build
// their paths from t.TempDir() so they hold regardless of what exists on
// the machine (a hardcoded "/tmp/x" flips behavior the day someone creates
// it).
func TestDemoStoreHome(t *testing.T) {
	realHome := t.TempDir() // exists — the inode walk is live

	t.Run("test mode with sandbox home uses it", func(t *testing.T) {
		sandbox := filepath.Join(t.TempDir(), "llmpilot-home") // sibling tree
		dir, sandboxed, err := demoStoreHome(true, sandbox, realHome)
		if err != nil || !sandboxed {
			t.Fatalf("= (%q, %v, %v), want sandboxed with no error", dir, sandboxed, err)
		}
		if filepath.Base(dir) != "llmpilot-home" {
			t.Fatalf("dir = %q, want the requested sandbox path", dir)
		}
	})

	t.Run("test mode with no home falls back to mktemp", func(t *testing.T) {
		dir, sandboxed, err := demoStoreHome(true, "", realHome)
		if err != nil || sandboxed || dir != "" {
			t.Fatalf("= (%q, %v, %v), want the mktemp fallback", dir, sandboxed, err)
		}
	})

	t.Run("home set but not in test mode falls back to mktemp", func(t *testing.T) {
		dir, sandboxed, err := demoStoreHome(false, filepath.Join(t.TempDir(), "x"), realHome)
		if err != nil || sandboxed || dir != "" {
			t.Fatalf("= (%q, %v, %v), want the mktemp fallback", dir, sandboxed, err)
		}
	})

	refused := func(t *testing.T, target string) {
		t.Helper()
		_, _, err := demoStoreHome(true, target, realHome)
		if err == nil || !strings.Contains(err.Error(), "refusing to seed demo data") {
			t.Fatalf("demoStoreHome(true, %q, %q) err = %v, want the interlock refusal",
				target, realHome, err)
		}
	}

	t.Run("the home itself is refused", func(t *testing.T) {
		refused(t, realHome)
	})

	t.Run("a not-yet-created dir under the home is refused", func(t *testing.T) {
		// The leaf does not exist (MkdirAll would create it) — the parent
		// walk must still judge it. This is the shape a misconfigured
		// LLMPILOT_HOME=$HOME/.llmpilot takes.
		refused(t, filepath.Join(realHome, ".llmpilot"))
	})

	t.Run("a symlinked parent of the home is refused", func(t *testing.T) {
		link := filepath.Join(t.TempDir(), "link-to-home")
		if err := os.Symlink(realHome, link); err != nil {
			t.Skipf("cannot create symlink: %v", err)
		}
		refused(t, filepath.Join(link, ".llmpilot"))
	})

	t.Run("a case-variant spelling of the home is refused", func(t *testing.T) {
		// On the case-insensitive APFS default the inode walk catches it;
		// on a case-sensitive volume the case-folded prefix fallback does.
		refused(t, filepath.Join(swapCase(realHome), ".llmpilot"))
	})

	t.Run("a sibling sharing the home's name prefix is NOT refused", func(t *testing.T) {
		sibling := realHome + "x-sibling"
		dir, sandboxed, err := demoStoreHome(true, sibling, realHome)
		if err != nil || !sandboxed {
			t.Fatalf("= (%q, %v, %v), want allowed — %q is not under %q",
				dir, sandboxed, err, sibling, realHome)
		}
	})
}

func swapCase(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z':
			return r - 'a' + 'A'
		case r >= 'A' && r <= 'Z':
			return r - 'A' + 'a'
		default:
			return r
		}
	}, s)
}
