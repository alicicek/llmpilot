package setuptoken

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alicicek/llmpilot/internal/switcher"
)

// liveShaped is a live-SHAPED token (real prefix, fake body): the proofs must
// hold against the real shape, not a toy string a lazy filter would pass.
const liveShaped = "sk-ant-oat01-LIVESHAPED-FAKE-BODY-0123456789abcdefghijklmnop"

// fakeSecurity is an in-memory /usr/bin/security stand-in mirroring the
// switcher test convention: stdin `-i` adds, argv reads/deletes, exit 44 for
// a missing item. The log records every call so tests can assert what the
// runner NEVER saw.
type fakeSecurity struct {
	mu        sync.Mutex
	items     map[string][]byte
	log       []string
	deleteErr error // non-nil: delete-generic-password fails with this
	addErr    error // non-nil: add-generic-password fails with this
}

func newFakeSecurity() *fakeSecurity { return &fakeSecurity{items: map[string][]byte{}} }

func (f *fakeSecurity) keychain() *switcher.Keychain {
	return &switcher.Keychain{File: "/tmp/fake-throwaway.keychain-db", Run: f.run}
}

type exit44 struct{}

func (exit44) Error() string { return "exit status 44" }
func (exit44) ExitCode() int { return 44 }

func (f *fakeSecurity) run(_ context.Context, stdin []byte, name string, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.log = append(f.log, name+" "+strings.Join(args, " ")+" | "+string(stdin))
	joined := strings.Join(args, " ")
	switch {
	case len(args) > 0 && args[0] == "-i": // add-generic-password via stdin
		if f.addErr != nil {
			return nil, f.addErr
		}
		line := string(stdin)
		svc := quoted(line, "-s")
		acct := quoted(line, "-a")
		hexPos := strings.Index(line, "-X ")
		if svc == "" || acct == "" || hexPos < 0 {
			return nil, fmt.Errorf("bad add line: %s", line)
		}
		var val []byte
		if _, err := fmt.Sscanf(strings.Fields(line[hexPos+3:])[0], "%x", &val); err != nil {
			return nil, err
		}
		f.items[svc+"\x00"+acct] = val
		return nil, nil
	case strings.HasPrefix(joined, "find-generic-password"):
		svc, acct := flag(args, "-s"), flag(args, "-a")
		if v, ok := f.items[svc+"\x00"+acct]; ok {
			out := make([]byte, len(v)+1)
			copy(out, v)
			out[len(v)] = '\n'
			return out, nil
		}
		return nil, exit44{}
	case strings.HasPrefix(joined, "delete-generic-password"):
		if f.deleteErr != nil {
			return nil, f.deleteErr
		}
		svc, acct := flag(args, "-s"), flag(args, "-a")
		if _, ok := f.items[svc+"\x00"+acct]; !ok {
			return nil, exit44{}
		}
		delete(f.items, svc+"\x00"+acct)
		return nil, nil
	}
	return nil, fmt.Errorf("unhandled security call: %s", joined)
}

func (f *fakeSecurity) calls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.log...)
}

func flag(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func quoted(line, name string) string {
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

// scanHome fails the test if any file under home carries the token bytes —
// names AND contents (a rename-blind count proved decorative once), and in
// BOTH encodings: the token crosses the Keychain adapter
// hex-encoded, so a raw-only scan would be blind to the wire form.
func scanHome(t *testing.T, home string) {
	t.Helper()
	hexForm := hex.EncodeToString([]byte(liveShaped))
	err := filepath.Walk(home, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if strings.Contains(path, liveShaped) {
			t.Errorf("token bytes in a file NAME under the home: %s", path)
		}
		if info.IsDir() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if bytes.Contains(data, []byte(liveShaped)) || bytes.Contains(data, []byte(hexForm)) {
			t.Errorf("token bytes (raw or hex) landed in %s", path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("scan home: %v", err)
	}
}

func testStore(t *testing.T, fake *fakeSecurity, clip func(context.Context, []byte) error) *Store {
	t.Helper()
	t.Setenv("LLMPILOT_TEST", "1")
	return &Store{
		Home:      t.TempDir(),
		Keychain:  fake.keychain(),
		Clipboard: clip,
		Now:       func() time.Time { return time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC) },
	}
}

func TestSetupTokenStore(t *testing.T) {
	fake := newFakeSecurity()
	var clipped [][]byte
	s := testStore(t, fake, func(_ context.Context, data []byte) error {
		clipped = append(clipped, append([]byte(nil), data...))
		return nil
	})

	// Add: keychain holds the token, metadata holds dates only.
	meta, err := s.Add(context.Background(), "ci", []byte(liveShaped+"\n"), false)
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if want := meta.CreatedAt.Add(365 * 24 * time.Hour); !meta.ExpiresAt.Equal(want) {
		t.Errorf("expires_at = %v, want created+365d = %v", meta.ExpiresAt, want)
	}
	if got := fake.items[Service+"\x00ci"]; string(got) != liveShaped {
		t.Errorf("keychain item = %q, want the trimmed token", got)
	}
	scanHome(t, s.Home)

	// List: metadata only — and the listing itself makes no keychain call.
	before := len(fake.calls())
	list, err := s.List()
	if err != nil || len(list) != 1 || list[0].Label != "ci" {
		t.Fatalf("list = %v, %v; want the one ci row", list, err)
	}
	if got := len(fake.calls()); got != before {
		t.Errorf("list made %d keychain calls; list is metadata-only", got-before)
	}
	if days := list[0].DaysLeft(s.now()); days != 365 {
		t.Errorf("days left = %d, want 365", days)
	}

	// A stored label refuses a plain add — rotation is explicit.
	if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); !errors.Is(err, ErrExists) {
		t.Errorf("re-add without --replace: err = %v, want ErrExists", err)
	}
	// --replace rotates in place: still one row, fresh dates.
	if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), true); err != nil {
		t.Fatalf("add --replace: %v", err)
	}
	if list, _ := s.List(); len(list) != 1 {
		t.Errorf("after --replace: %d rows, want 1", len(list))
	}

	// Copy egresses through the clipboard seam and nowhere else.
	if _, err := s.Copy(context.Background(), "ci"); err != nil {
		t.Fatalf("copy: %v", err)
	}
	if len(clipped) != 1 || string(clipped[0]) != liveShaped {
		t.Fatalf("clipboard saw %d writes; want exactly the token once", len(clipped))
	}

	// Remove converges both halves to gone.
	if err := s.Remove(context.Background(), "ci"); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, ok := fake.items[Service+"\x00ci"]; ok {
		t.Errorf("keychain item survived remove")
	}
	if list, _ := s.List(); len(list) != 0 {
		t.Errorf("metadata row survived remove: %v", list)
	}
	// Remove again: idempotent, no error, no claim about what existed.
	if err := s.Remove(context.Background(), "ci"); err != nil {
		t.Errorf("second remove: %v, want nil (idempotent)", err)
	}

	// NEVER A FLEET LANE, stated as runner + file evidence: the runner never
	// saw the backups service, and nothing wrote an account registry.
	for _, call := range fake.calls() {
		if strings.Contains(call, switcher.BackupService) {
			t.Errorf("the runner saw service %q: %s", switcher.BackupService, call)
		}
	}
	if _, err := os.Stat(filepath.Join(s.Home, "accounts.json")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("accounts.json exists under the home — a fleet lane leaked (stat err=%v)", err)
	}
	scanHome(t, s.Home)
}

func TestSetupTokenTornStates(t *testing.T) {
	t.Run("replace lands keychain then fails metadata", func(t *testing.T) {
		fake := newFakeSecurity()
		s := testStore(t, fake, nil)
		if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err != nil {
			t.Fatalf("seed add: %v", err)
		}
		// Make the metadata write fail AFTER the keychain write lands: the
		// home refuses new files, load() still reads the existing document.
		if err := os.Chmod(s.Home, 0o500); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(s.Home, 0o700) })
		_, err := s.Add(context.Background(), "ci", []byte(liveShaped+"ROTATED"), true)
		if !errors.Is(err, ErrTorn) {
			t.Fatalf("torn rotation: err = %v, want ErrTorn", err)
		}
		if !strings.Contains(err.Error(), "record stale") || !strings.Contains(err.Error(), "add --replace") {
			t.Errorf("torn error must say the record is stale and how to repair: %v", err)
		}
		// The keychain half IS the new token, and the stale dates stay
		// visible — nothing pretends the rotation half-happened cleanly.
		if got := fake.items[Service+"\x00ci"]; !strings.HasSuffix(string(got), "ROTATED") {
			t.Errorf("keychain half should hold the NEW token after a torn rotation")
		}
		_ = os.Chmod(s.Home, 0o700)
		list, err := s.List()
		if err != nil || len(list) != 1 {
			t.Fatalf("list after torn rotation: %v, %v", list, err)
		}
	})

	t.Run("remove keeps the record when the keychain delete errors", func(t *testing.T) {
		fake := newFakeSecurity()
		s := testStore(t, fake, nil)
		if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err != nil {
			t.Fatalf("seed add: %v", err)
		}
		fake.deleteErr = errors.New("keychain is locked")
		err := s.Remove(context.Background(), "ci")
		if err == nil || !strings.Contains(err.Error(), "record is kept") {
			t.Fatalf("remove with an erroring delete: err = %v, want a kept-record report", err)
		}
		if list, _ := s.List(); len(list) != 1 {
			t.Errorf("metadata row was dropped while the keychain item survives — an invisible orphan")
		}
	})

	t.Run("copy of a record whose keychain half is gone", func(t *testing.T) {
		fake := newFakeSecurity()
		clipboardRan := false
		s := testStore(t, fake, func(context.Context, []byte) error {
			clipboardRan = true
			return nil
		})
		if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err != nil {
			t.Fatalf("seed add: %v", err)
		}
		delete(fake.items, Service+"\x00ci")
		_, err := s.Copy(context.Background(), "ci")
		if err == nil || !strings.Contains(err.Error(), "no token stored") {
			t.Fatalf("copy with the keychain half gone: err = %v, want a missing-half report", err)
		}
		if clipboardRan {
			t.Errorf("clipboard ran with nothing to copy")
		}
	})

	t.Run("copy failure path never carries the token", func(t *testing.T) {
		fake := newFakeSecurity()
		s := testStore(t, fake, func(context.Context, []byte) error {
			return errors.New("pbcopy exploded")
		})
		if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err != nil {
			t.Fatalf("seed add: %v", err)
		}
		_, err := s.Copy(context.Background(), "ci")
		if err == nil {
			t.Fatal("copy should surface the clipboard failure")
		}
		if strings.Contains(err.Error(), liveShaped) {
			t.Errorf("the copy FAILURE error carries the token")
		}
	})
}

func TestSetupTokenInterlock(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	s := &Store{
		Home: t.TempDir(),
		// No throwaway keychain file: the interlock must refuse every
		// operation BEFORE any subprocess runs.
		Keychain: &switcher.Keychain{Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
			t.Fatal("a /usr/bin/security subprocess ran under LLMPILOT_TEST with no throwaway keychain")
			return nil, nil
		}},
	}
	if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Errorf("add under the interlock: err = %v, want a loud interlock refusal", err)
	}
	if _, err := s.Copy(context.Background(), "ci"); err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Errorf("copy under the interlock: err = %v, want a loud interlock refusal", err)
	}
	if err := s.Remove(context.Background(), "ci"); err == nil || !strings.Contains(err.Error(), "interlock") {
		t.Errorf("remove under the interlock: err = %v, want a loud interlock refusal", err)
	}
}

func TestValidateToken(t *testing.T) {
	if err := ValidateToken([]byte("  ")); err == nil {
		t.Error("empty paste must refuse — an empty write can only destroy")
	}
	if err := ValidateToken([]byte("hunter2")); err == nil {
		t.Error("a non-token paste must refuse at the boundary")
	}
	if err := ValidateToken([]byte(liveShaped + "\n")); err != nil {
		t.Errorf("a live-shaped paste must pass: %v", err)
	}
}

// TestSetupTokenLabelBoundary is the P0 regression (adversarial review,
// proven live against real /usr/bin/security): %q's escaping and `security
// -i`'s un-escaping DISAGREE on control characters, so labels "ci\tprod" and
// "citprod" collide on ONE Keychain account — a plain add could destroy a
// stored credential, and remove could delete the wrong item or orphan one
// invisibly. The boundary refuses such labels BEFORE any subprocess.
func TestSetupTokenLabelBoundary(t *testing.T) {
	t.Setenv("LLMPILOT_TEST", "1")
	subprocessRan := false
	s := &Store{
		Home: t.TempDir(),
		Keychain: &switcher.Keychain{File: "/tmp/fake-throwaway.keychain-db",
			Run: func(context.Context, []byte, string, ...string) ([]byte, error) {
				subprocessRan = true
				return nil, nil
			}},
	}
	bad := []string{"ci\tprod", "ci\nprod", "ci prod", `ci"prod`, "", "  ", strings.Repeat("a", 65)}
	for _, label := range bad {
		if _, err := s.Add(context.Background(), label, []byte(liveShaped), false); err == nil {
			t.Errorf("Add accepted label %q", label)
		}
		if _, err := s.Copy(context.Background(), label); err == nil {
			t.Errorf("Copy accepted label %q", label)
		}
		if err := s.Remove(context.Background(), label); err == nil {
			t.Errorf("Remove accepted label %q", label)
		}
	}
	if subprocessRan {
		t.Fatal("a refused label still reached the Keychain runner")
	}
	// Trimming is part of the boundary: " ci " means ci, so a padded remove
	// can never report success over an untouched item.
	fake := newFakeSecurity()
	s2 := testStore(t, fake, nil)
	if _, err := s2.Add(context.Background(), " ci ", []byte(liveShaped), false); err != nil {
		t.Fatalf("padded label should trim, not refuse: %v", err)
	}
	if err := s2.Remove(context.Background(), "ci"); err != nil {
		t.Fatalf("remove of the trimmed label: %v", err)
	}
	if len(fake.items) != 0 {
		t.Error("the padded add and trimmed remove did not converge on one item")
	}
}

// TestSetupTokenExpiryInstants: day-rounding must never keep a lapsed token
// looking alive — the whole (-24h, 0] window once rendered as "0d left".
func TestSetupTokenExpiryInstants(t *testing.T) {
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	twelveHoursPast := Meta{ExpiresAt: now.Add(-12 * time.Hour)}
	if !twelveHoursPast.Expired(now) {
		t.Error("a token 12h past its declared expiry must be expired")
	}
	if d := twelveHoursPast.DaysLeft(now); d >= 0 {
		t.Errorf("DaysLeft 12h past expiry = %d, want negative (floored)", d)
	}
	twelveHoursLeft := Meta{ExpiresAt: now.Add(12 * time.Hour)}
	if twelveHoursLeft.Expired(now) {
		t.Error("a token with 12h left is not expired")
	}
	if d := twelveHoursLeft.DaysLeft(now); d != 0 {
		t.Errorf("DaysLeft with 12h left = %d, want 0", d)
	}
	if err := ValidateToken([]byte(TokenPrefix + strings.Repeat("x", 1100))); err == nil {
		t.Error("an oversized token must refuse — it would route to the argv fallback and land in the process listing")
	}
	// A token pasted where a label goes must refuse WITHOUT echoing it —
	// the length-rule message quotes the input (re-review N2).
	if _, err := ValidateLabel(liveShaped); err == nil || strings.Contains(err.Error(), liveShaped) {
		t.Errorf("a token-shaped label must refuse without echoing the bytes: %v", err)
	}
}

// TestSetupTokenWriteMayHaveLanded: the adapter distinguishes "provably
// untouched" (interlock/CAS) from "the subprocess errored — the write MAY
// have landed". Collapsing them told a user whose Keychain half changed that
// nothing happened (adversarial review P1).
func TestSetupTokenWriteMayHaveLanded(t *testing.T) {
	fake := newFakeSecurity()
	s := testStore(t, fake, nil)
	fake.addErr = errors.New("signal: killed")
	_, err := s.Add(context.Background(), "ci", []byte(liveShaped), false)
	if err == nil || !strings.Contains(err.Error(), "may or may not have changed") {
		t.Errorf("a subprocess error must say the Keychain half is uncertain: %v", err)
	}
	// The provably-untouched class carries no such rider.
	s2 := &Store{Home: t.TempDir(), Keychain: &switcher.Keychain{}} // no throwaway file → interlock refusal
	_, err = s2.Add(context.Background(), "ci", []byte(liveShaped), false)
	if err == nil || strings.Contains(err.Error(), "may or may not") {
		t.Errorf("an interlock refusal is provably untouched — no uncertainty rider: %v", err)
	}
}

// TestSetupTokenClipboardInterlock: a test that forgot to inject a fake
// clipboard must never put a token on the real pasteboard.
func TestSetupTokenClipboardInterlock(t *testing.T) {
	fake := newFakeSecurity()
	s := testStore(t, fake, nil) // nil Clipboard = the real pbcopy path
	if _, err := s.Add(context.Background(), "ci", []byte(liveShaped), false); err != nil {
		t.Fatalf("seed add: %v", err)
	}
	_, err := s.Copy(context.Background(), "ci")
	if err == nil || !strings.Contains(err.Error(), "clipboard write not attempted") {
		t.Fatalf("Copy with no injected clipboard under LLMPILOT_TEST: err = %v, want the interlock refusal", err)
	}
}
