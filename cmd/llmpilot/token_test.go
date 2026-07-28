package main

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"

	"github.com/spf13/cobra"

	"github.com/alicicek/llmpilot/internal/setuptoken"
	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/internal/switcher"
)

// cmdLiveShaped is a live-SHAPED token: the no-egress proof must hold against
// the real prefix, not a toy string a lazy filter would pass.
const cmdLiveShaped = "sk-ant-oat01-LIVESHAPED-FAKE-BODY-abcdefghijklmnopqrstuvwxyz"

// tokenHarness swaps every seam the token family has: the keychain runner,
// the clipboard, and the paste reader. No real /usr/bin/security or pbcopy
// runs, and the interlock's throwaway-file rule is satisfied.
type tokenHarness struct {
	mu       sync.Mutex
	items    map[string][]byte
	clip     [][]byte
	clipErr  error
	pasted   []byte
	pasteErr error
}

type cmdExit44 struct{}

func (cmdExit44) Error() string { return "exit status 44" }
func (cmdExit44) ExitCode() int { return 44 }

func (h *tokenHarness) run(_ context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	joined := strings.Join(args, " ")
	switch {
	case len(args) > 0 && args[0] == "-i":
		line := string(stdin)
		svc := harnessQuoted(line, "-s")
		acct := harnessQuoted(line, "-a")
		hexPos := strings.Index(line, "-X ")
		if svc == "" || acct == "" || hexPos < 0 {
			return nil, fmt.Errorf("bad add line: %s", line)
		}
		var val []byte
		if _, err := fmt.Sscanf(strings.Fields(line[hexPos+3:])[0], "%x", &val); err != nil {
			return nil, err
		}
		h.items[svc+"\x00"+acct] = val
		return nil, nil
	case strings.HasPrefix(joined, "find-generic-password"):
		svc, acct := harnessFlag(args, "-s"), harnessFlag(args, "-a")
		if v, ok := h.items[svc+"\x00"+acct]; ok {
			return append(append([]byte{}, v...), '\n'), nil
		}
		return nil, cmdExit44{}
	case strings.HasPrefix(joined, "delete-generic-password"):
		svc, acct := harnessFlag(args, "-s"), harnessFlag(args, "-a")
		delete(h.items, svc+"\x00"+acct)
		return nil, nil
	}
	return nil, fmt.Errorf("unhandled security call: %s", joined)
}

func harnessFlag(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func harnessQuoted(line, name string) string {
	i := strings.Index(line, name+` "`)
	if i < 0 {
		return ""
	}
	rest := line[i+len(name)+2:]
	j := strings.Index(rest, `"`)
	if j < 0 {
		return ""
	}
	return rest[:j]
}

func installTokenHarness(t *testing.T) *tokenHarness {
	t.Helper()
	t.Setenv("LLMPILOT_TEST", "1")
	t.Setenv("LLMPILOT_HOME", t.TempDir())
	h := &tokenHarness{items: map[string][]byte{}, pasted: []byte(cmdLiveShaped)}

	realStore, realInput := tokenStoreFor, tokenInput
	t.Cleanup(func() { tokenStoreFor, tokenInput = realStore, realInput })
	tokenStoreFor = func(st *store.Store) *setuptoken.Store {
		return &setuptoken.Store{
			Home:     st.Home(),
			Keychain: &switcher.Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: h.run},
			Clipboard: func(_ context.Context, data []byte) error {
				if h.clipErr != nil {
					return h.clipErr
				}
				h.clip = append(h.clip, append([]byte(nil), data...))
				return nil
			},
		}
	}
	tokenInput = func(*cobra.Command) ([]byte, error) { return h.pasted, h.pasteErr }
	return h
}

// runToken executes one verb and returns combined stdout+stderr and the
// error. Errors are rendered into the transcript too — the no-egress proof
// covers the failure paths, where a leak is most natural.
func runToken(args ...string) (string, error) {
	cmd := tokenCmd()
	var buf bytes.Buffer
	cmd.SetOut(&buf)
	cmd.SetErr(&buf)
	cmd.SetArgs(args)
	err := cmd.Execute()
	if err != nil {
		fmt.Fprintf(&buf, "error: %v\n", err)
	}
	return buf.String(), err
}

// TestSetupTokenNeverPrinted is the load-bearing egress proof: every
// verb runs with a live-shaped token, and no output — success or failure —
// ever contains the token bytes. The clipboard seam is the ONE egress.
func TestSetupTokenNeverPrinted(t *testing.T) {
	h := installTokenHarness(t)
	var transcript strings.Builder

	// add — the guide + paste path.
	out, err := runToken("add", "--label", "ci")
	if err != nil {
		t.Fatalf("token add: %v (%s)", err, out)
	}
	if !strings.Contains(out, "claude setup-token") {
		t.Errorf("add must guide the mint: %s", out)
	}
	transcript.WriteString(out)

	// add again without --replace — the refusal path.
	out, err = runToken("add", "--label", "ci")
	if err == nil {
		t.Error("re-add without --replace must refuse")
	}
	transcript.WriteString(out)

	// list — metadata rendering.
	out, err = runToken("list")
	if err != nil {
		t.Fatalf("token list: %v", err)
	}
	if !strings.Contains(out, "ci") || !strings.Contains(out, "declared, not verified") {
		t.Errorf("list must show the label and the declared register: %s", out)
	}
	if !strings.Contains(out, "cannot report usage") {
		t.Errorf("list must say setup tokens cannot report usage (probed, HTTP 403): %s", out)
	}
	transcript.WriteString(out)

	// copy — the one egress, plus its hazard sentence.
	out, err = runToken("copy", "ci")
	if err != nil {
		t.Fatalf("token copy: %v (%s)", err, out)
	}
	if len(h.clip) != 1 || string(h.clip[0]) != cmdLiveShaped {
		t.Fatalf("clipboard saw %d writes, want exactly the token once", len(h.clip))
	}
	if !strings.Contains(out, "clipboard managers") {
		t.Errorf("copy must state the clipboard hazard: %s", out)
	}
	transcript.WriteString(out)

	// copy FAILURE — the leak-shaped path: a clipboard error must not carry
	// the payload into the error chain.
	h.clipErr = errors.New("pbcopy exploded")
	out, err = runToken("copy", "ci")
	if err == nil {
		t.Error("a clipboard failure must surface")
	}
	transcript.WriteString(out)
	h.clipErr = nil

	// copy of a missing label — the missing-half report.
	out, _ = runToken("copy", "ghost")
	if !strings.Contains(out, "no token stored") {
		t.Errorf("copy of a missing label must say so: %s", out)
	}
	transcript.WriteString(out)

	// a token pasted where a LABEL goes — the refusal must not echo it
	// (the final transcript scan is the proof; re-review N2).
	out, err = runToken("copy", cmdLiveShaped)
	if err == nil {
		t.Error("a token-shaped label must refuse")
	}
	transcript.WriteString(out)
	out, _ = runToken("add", "--label", cmdLiveShaped)
	transcript.WriteString(out)

	// paste failure — an unreadable paste must not echo anything back.
	h.pasteErr = errors.New("tty gone")
	out, _ = runToken("add", "--label", "x")
	transcript.WriteString(out)
	h.pasteErr = nil

	// a garbage paste refuses at the boundary.
	h.pasted = []byte("hunter2")
	out, err = runToken("add", "--label", "x")
	if err == nil {
		t.Error("a non-token paste must refuse")
	}
	transcript.WriteString(out)
	h.pasted = []byte(cmdLiveShaped)

	// remove — and the idempotent second remove.
	out, err = runToken("remove", "ci")
	if err != nil {
		t.Fatalf("token remove: %v", err)
	}
	transcript.WriteString(out)
	out, err = runToken("remove", "ci")
	if err != nil {
		t.Errorf("second remove: %v, want nil (idempotent)", err)
	}
	transcript.WriteString(out)

	// THE PROOF: the combined transcript of every verb, success and failure,
	// never contains the token bytes — raw OR hex, the encoding the token
	// actually crosses the Keychain adapter in.
	if strings.Contains(transcript.String(), cmdLiveShaped) {
		t.Fatalf("token bytes reached a verb's output:\n%s", transcript.String())
	}
	if strings.Contains(transcript.String(), hex.EncodeToString([]byte(cmdLiveShaped))) {
		t.Fatalf("hex-encoded token bytes reached a verb's output:\n%s", transcript.String())
	}
}
