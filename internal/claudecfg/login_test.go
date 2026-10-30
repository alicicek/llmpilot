package claudecfg

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fakeClaude writes a stand-in for `claude` that behaves like
// `claude auth login`: it prints the OSC 8 manual link and the paste prompt,
// then acts per FAKE_MODE. It records its argv and CLAUDE_CONFIG_DIR.
func fakeClaude(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "claude")
	script := `#!/bin/sh
printf '%s\n' "$*" > "$FAKE_LOG"
printf '%s\n' "$CLAUDE_CONFIG_DIR" >> "$FAKE_LOG"
printf '%s\n' "${DISABLE_AUTOUPDATER:-}" >> "$FAKE_LOG"
printf 'Opening browser to sign in…\n'
printf 'If the browser didn'"'"'t open, visit: \033]8;;https://claude.com/cai/oauth/authorize?code=true&state=abc\033\\https://claude.com/cai/oauth/authorize?code=true&state=abc\033]8;;\033\\\n'
printf 'Paste code here if prompted > '
case "$FAKE_MODE" in
  ok) printf 'Login successful.\n'; exit 0 ;;
  paste) read line; [ "$line" = "abcdefgh1234#statestate99" ] && { printf 'Login successful.\n'; exit 0; }; printf 'OAuth error: invalid code\n'; exit 1 ;;
  fail) printf '\nOAuth error: access_denied\n' >&2; exit 1 ;;
  hang) trap '' TERM; sleep 30 ;;
  *) sleep 30 ;;
esac
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func startFake(t *testing.T, mode, email string) (*LoginSession, string, string) {
	t.Helper()
	bin := fakeClaude(t)
	log := filepath.Join(t.TempDir(), "log")
	cfg := t.TempDir()
	cli := CLI{Path: bin, Env: []string{"PATH=/usr/bin:/bin", "FAKE_MODE=" + mode, "FAKE_LOG=" + log, "CLAUDE_CONFIG_DIR=/should/be/replaced"}}
	s, err := StartLogin(LoginOptions{CLI: cli, ConfigDir: cfg, Email: email})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	return s, log, cfg
}

func waitDone(t *testing.T, s *LoginSession) {
	t.Helper()
	select {
	case <-s.Done():
	case <-time.After(10 * time.Second):
		t.Fatal("sign-in process did not exit")
	}
}

func waitURL(t *testing.T, s *LoginSession) string {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if u := s.ManualURL(); u != "" {
			return u
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("manual URL never appeared")
	return ""
}

func TestStartLoginSuccess(t *testing.T) {
	s, log, cfg := startFake(t, "ok", "")
	waitDone(t, s)
	if err := s.Err(); err != nil {
		t.Fatalf("Err = %v, want nil", err)
	}
	if got := s.ManualURL(); got != "https://claude.com/cai/oauth/authorize?code=true&state=abc" {
		t.Fatalf("ManualURL = %q", got)
	}
	data, _ := os.ReadFile(log)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if lines[0] != "auth login --claudeai" {
		t.Errorf("argv = %q", lines[0])
	}
	// The caller's CLAUDE_CONFIG_DIR is replaced, never appended beside.
	if lines[1] != cfg {
		t.Errorf("CLAUDE_CONFIG_DIR = %q, want %q", lines[1], cfg)
	}
	if lines[2] != "1" {
		t.Errorf("DISABLE_AUTOUPDATER = %q, want 1", lines[2])
	}
}

func TestStartLoginPassesEmail(t *testing.T) {
	s, log, _ := startFake(t, "ok", "b@example.dev")
	waitDone(t, s)
	data, _ := os.ReadFile(log)
	if first := strings.SplitN(string(data), "\n", 2)[0]; first != "auth login --claudeai --email b@example.dev" {
		t.Fatalf("argv = %q", first)
	}
}

func TestSubmitCodeFinishesSignIn(t *testing.T) {
	s, _, _ := startFake(t, "paste", "")
	waitURL(t, s)
	if err := s.SubmitCode("  abcdefgh1234#statestate99\n"); err != nil {
		t.Fatal(err)
	}
	waitDone(t, s)
	if err := s.Err(); err != nil {
		t.Fatalf("Err = %v", err)
	}
}

func TestFailureCarriesClaudeCodesReason(t *testing.T) {
	s, _, _ := startFake(t, "fail", "")
	waitDone(t, s)
	err := s.Err()
	if err == nil || !strings.Contains(err.Error(), "access_denied") {
		t.Fatalf("Err = %v, want Claude Code's reason", err)
	}
	if strings.Contains(err.Error(), "://") {
		t.Fatalf("failure reason carries a link: %v", err)
	}
}

func TestStopKillsAStubbornProcess(t *testing.T) {
	s, _, _ := startFake(t, "hang", "")
	waitURL(t, s)
	start := time.Now()
	s.Stop()
	select {
	case <-s.Done():
	default:
		t.Fatal("Stop returned before the process exited")
	}
	if time.Since(start) > 8*time.Second {
		t.Fatalf("Stop took %v", time.Since(start))
	}
	if !errors.Is(s.Err(), errStopped) {
		t.Fatalf("Err = %v, want errStopped", s.Err())
	}
	s.Stop() // idempotent
}

func TestSubmitCodeAfterExit(t *testing.T) {
	s, _, _ := startFake(t, "ok", "")
	waitDone(t, s)
	if err := s.SubmitCode("abcdefgh1234#statestate99"); err == nil {
		t.Fatal("SubmitCode after exit succeeded")
	}
}

func TestNormalizeCode(t *testing.T) {
	good := map[string]string{
		"abcdefgh1234#statestate99":      "abcdefgh1234#statestate99",
		"  abcd-efgh_1234#st.ate~state ": "abcd-efgh_1234#st.ate~state",
		"https://platform.claude.com/oauth/code/callback?code=abcdefgh1234&state=statestate99": "abcdefgh1234#statestate99",
	}
	for in, want := range good {
		got, err := NormalizeCode(in)
		if err != nil || got != want {
			t.Errorf("NormalizeCode(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{
		"", "abc", "nohashhere12345678",
		"abcdefgh1234#state\nrm -rf /",
		"abcdefgh1234#statestate99\n#more",
		"abcdefgh 1234#statestate99",
		"https://platform.claude.com/oauth/code/callback?code=abcdefgh1234",
		strings.Repeat("a", 2000) + "#" + strings.Repeat("b", 2000),
	}
	for _, in := range bad {
		if _, err := NormalizeCode(in); !errors.Is(err, ErrBadCode) {
			t.Errorf("NormalizeCode(%q) err = %v, want ErrBadCode", in, err)
		}
	}
}

func TestValidManualURL(t *testing.T) {
	for _, u := range []string{
		"https://claude.com/cai/oauth/authorize?x=1",
		"https://claude.ai/oauth/authorize?x=1",
		"https://console.anthropic.com/oauth/authorize?x=1",
	} {
		if !validManualURL(u) {
			t.Errorf("rejected %q", u)
		}
	}
	for _, u := range []string{
		"http://claude.com/oauth/authorize?x=1",
		"https://evil.example/oauth/authorize?x=1",
		"https://claude.com.evil.example/oauth/authorize?x=1",
		"https://notclaude.com/oauth/authorize?x=1",
	} {
		if validManualURL(u) {
			t.Errorf("accepted %q", u)
		}
	}
}

func TestParseShellEnv(t *testing.T) {
	out := []byte("Last login: today\nwelcome!\n" + envBegin + "\n" +
		"PATH=/a:/b\x00HTTPS_PROXY=http://proxy:8080\x00CLAUDE_CONFIG_DIR=/pinned\x00ANTHROPIC_API_KEY=sk-x\x00BROWSER=firefox\x00" +
		"NODE_EXTRA_CA_CERTS=/etc/ca.pem\x00" + envEnd + "bye\n")
	got := parseShellEnv(out)
	want := map[string]string{"PATH": "/a:/b", "HTTPS_PROXY": "http://proxy:8080", "NODE_EXTRA_CA_CERTS": "/etc/ca.pem"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	// A dump cut off before its end marker is not trusted at all.
	if got := parseShellEnv([]byte(envBegin + "\nPATH=/a\x00")); len(got) != 0 {
		t.Errorf("truncated dump parsed: %v", got)
	}
}

func TestResolverUsesShellPathThenCandidates(t *testing.T) {
	bin := fakeClaude(t)
	shellDir := t.TempDir()
	shell := filepath.Join(shellDir, "sh")
	// A "login shell" that reports a PATH containing the fake claude.
	script := "#!/bin/sh\nprintf 'motd\\n" + envBegin + "\\n'; printf 'PATH=" + filepath.Dir(bin) + ":/usr/bin\\0HTTPS_PROXY=http://p:1\\0'; printf '" + envEnd + "'\n"
	if err := os.WriteFile(shell, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	settings := DirAt(t.TempDir())
	r := &CLIResolver{Shell: shell, Candidates: []string{}, SettingsDir: &settings}
	cli, err := r.Resolve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if cli.Path != bin {
		t.Fatalf("Path = %q, want %q", cli.Path, bin)
	}
	env := strings.Join(cli.Env, "\n")
	if !strings.Contains(env, "HTTPS_PROXY=http://p:1") {
		t.Errorf("proxy not carried: %v", cli.Env)
	}

	// The shell knows nothing: fall back to a known install location.
	empty := filepath.Join(shellDir, "empty")
	if err := os.WriteFile(empty, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/usr/bin:/bin")
	r2 := &CLIResolver{Shell: empty, Candidates: []string{"/nonexistent/claude", bin}, SettingsDir: &settings}
	cli, err = r2.Resolve(context.Background())
	if err != nil || cli.Path != bin {
		t.Fatalf("fallback = %+v, %v", cli, err)
	}
	if !strings.Contains(strings.Join(cli.Env, "\n"), "PATH="+filepath.Dir(bin)+":") {
		t.Errorf("fallback PATH does not lead with the binary's dir: %v", cli.Env)
	}

	// Nowhere at all.
	r3 := &CLIResolver{Shell: empty, Candidates: []string{"/nonexistent/claude"}, SettingsDir: &settings}
	if _, err := r3.Resolve(context.Background()); !errors.Is(err, ErrCLINotFound) {
		t.Fatalf("err = %v, want ErrCLINotFound", err)
	}
}

func TestResolverTimesOutAHangingShell(t *testing.T) {
	shell := filepath.Join(t.TempDir(), "sh")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/usr/bin:/bin")
	settings := DirAt(t.TempDir())
	r := &CLIResolver{Shell: shell, Candidates: []string{}, Timeout: 300 * time.Millisecond, SettingsDir: &settings}
	start := time.Now()
	if _, err := r.Resolve(context.Background()); !errors.Is(err, ErrCLINotFound) {
		t.Fatalf("err = %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Fatalf("hanging shell held the lookup for %v", time.Since(start))
	}
}

func TestCleanExitWithOutputStillHeldCountsAsFinished(t *testing.T) {
	// The sign-in exits 0 but leaves a child holding its output open — what
	// WaitDelay reports as ErrWaitDelay.
	bin := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\nprintf 'Login successful.\\n'\n/bin/sleep 30 &\nexit 0\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	s, err := StartLogin(LoginOptions{CLI: CLI{Path: bin, Env: []string{"PATH=/usr/bin:/bin"}}, ConfigDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = exec.Command("/usr/bin/pkill", "-g", strconv.Itoa(s.PID())).Run() })
	waitDone(t, s)
	if err := s.Err(); err != nil {
		t.Fatalf("a clean exit read as a failure: %v", err)
	}
}

func TestResolverCarriesProxyFromClaudeSettings(t *testing.T) {
	bin := fakeClaude(t)
	settings := DirAt(t.TempDir())
	doc := `{"env":{"HTTPS_PROXY":"http://corp:3128","NODE_EXTRA_CA_CERTS":"/etc/corp.pem","ANTHROPIC_API_KEY":"sk-nope","PATH":"/evil"}}`
	if err := os.WriteFile(settings.SettingsPath(), []byte(doc), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(t.TempDir(), "sh")
	if err := os.WriteFile(empty, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/usr/bin:/bin")
	r := &CLIResolver{Shell: empty, Candidates: []string{bin}, SettingsDir: &settings}
	cli, err := r.Resolve(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	env := strings.Join(cli.Env, "\n")
	for _, want := range []string{"HTTPS_PROXY=http://corp:3128", "NODE_EXTRA_CA_CERTS=/etc/corp.pem"} {
		if !strings.Contains(env, want) {
			t.Errorf("missing %s in %v", want, cli.Env)
		}
	}
	if strings.Contains(env, "sk-nope") || strings.Contains(env, "/evil") {
		t.Errorf("settings carried more than network keys: %v", cli.Env)
	}
	// The shell never answered, so the fallback is not cached.
	if r.cached != nil {
		t.Error("a fallback lookup was cached")
	}
}
