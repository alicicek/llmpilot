package claudecfg

// Claude Code's own sign-in, driven headlessly. llmpilot never runs an OAuth
// flow of its own: it runs `claude auth login` in a config dir it chooses
// and reads the result back through the same adapter that reads every other
// dir. Verified against Claude Code 2.1.312 on 2026-10-29:
//   - `claude auth login --claudeai [--email <e>]` opens the browser itself
//     and catches the approval on its own localhost listener.
//   - It also prints a manual URL as an OSC 8 hyperlink
//     ("If the browser didn't open, visit: ESC]8;;<url>ESC\..."), and reads
//     a pasted "<code>#<state>" from stdin ("Paste code here if prompted > ").
//     Plain readline: works without a TTY, input is not echoed.
//   - CLAUDE_CONFIG_DIR steers both the .claude.json it writes and the
//     Keychain service name (see KeychainService).
//   - The process outlives a killed parent (it is re-parented, not
//     signalled), so callers must stop it explicitly — StartLogin puts it in
//     its own process group for that.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ErrCLINotFound means no Claude Code executable could be found the way the
// user's own terminal would find it, nor in any known install location.
var ErrCLINotFound = errors.New("no Claude Code installation found on this Mac")

// CLI is a runnable Claude Code: the executable plus the environment it
// runs with. Env is complete — the child inherits nothing else.
type CLI struct {
	Path string
	Env  []string
}

// shellEnvKeys are the variables carried from the user's login shell into
// Claude Code: where it and its runtime live (PATH), and what a company
// network needs to reach Anthropic at all (proxies, extra CAs). A daemon
// started by launchd has none of them. Everything else stays behind — the
// user's shell may carry settings (CLAUDE_CONFIG_DIR, API keys) that must
// not leak into a sign-in llmpilot started. BROWSER stays behind too: a
// browser started from it would join the sign-in's process group, and
// stopping the sign-in would stop the user's browser with it.
var shellEnvKeys = map[string]bool{
	"PATH":                true,
	"HTTP_PROXY":          true,
	"HTTPS_PROXY":         true,
	"NO_PROXY":            true,
	"ALL_PROXY":           true,
	"http_proxy":          true,
	"https_proxy":         true,
	"no_proxy":            true,
	"all_proxy":           true,
	"NODE_EXTRA_CA_CERTS": true,
	"NODE_OPTIONS":        true,
	"NODE_USE_SYSTEM_CA":  true,
	"SSL_CERT_FILE":       true,
	"SSL_CERT_DIR":        true,
}

// processEnvKeys come from this process: the basics every macOS program
// expects, which launchd does provide.
var processEnvKeys = []string{"HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SSH_AUTH_SOCK"}

// CLIResolver finds Claude Code once and remembers it. The first lookup
// asks the user's login shell (about a second and a half on a typical
// zsh setup), so the answer is cached until the executable disappears.
type CLIResolver struct {
	// Shell overrides the login shell ("" = the account's UserShell, else
	// /bin/zsh). Tests point it at a stub.
	Shell string
	// Candidates overrides the known install locations (nil = defaults).
	Candidates []string
	// Timeout bounds the shell lookup (0 = 10s).
	Timeout time.Duration
	// SettingsDir overrides where settings.json's env block is read from
	// (nil = the global config dir). Tests point it at a sandbox.
	SettingsDir *Dir

	mu     sync.Mutex
	cached *CLI
}

// Resolve returns the Claude Code to run, or ErrCLINotFound.
func (r *CLIResolver) Resolve(ctx context.Context) (CLI, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cached != nil && isExecutable(r.cached.Path) {
		return *r.cached, nil
	}
	cli, shellAnswered, err := r.resolve(ctx)
	if err != nil {
		return CLI{}, err
	}
	// Only a lookup the shell answered is worth keeping: a timed-out shell
	// gives a fallback without the user's proxy settings, and the next
	// sign-in should ask again.
	if shellAnswered {
		r.cached = &cli
	}
	return cli, nil
}

func (r *CLIResolver) resolve(ctx context.Context) (CLI, bool, error) {
	env := baseEnv()
	shellVars := r.shellEnv(ctx)
	for k, v := range shellVars {
		env[k] = v
	}
	// Proxy and CA settings Claude Code takes from the user's own
	// ~/.claude/settings.json do not reach a sign-in in another config dir;
	// carry them over unless the shell already set them.
	for k, v := range r.settingsEnv() {
		if _, set := env[k]; !set {
			env[k] = v
		}
	}
	answered := len(shellVars) > 0
	if p := lookPath("claude", env["PATH"]); p != "" {
		return CLI{Path: p, Env: flattenEnv(env)}, answered, nil
	}
	// The shell didn't know it (or couldn't be asked): try where the
	// installers put it, and give the child a PATH that can run it.
	for _, c := range r.candidates() {
		if !isExecutable(c) {
			continue
		}
		path := filepath.Dir(c) + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		if env["PATH"] != "" {
			path += ":" + env["PATH"]
		}
		env["PATH"] = path
		return CLI{Path: c, Env: flattenEnv(env)}, answered, nil
	}
	return CLI{}, false, ErrCLINotFound
}

// settingsEnv reads the network keys of the "env" block in the global
// config dir's settings.json (the ones Claude Code applies to itself).
func (r *CLIResolver) settingsEnv() map[string]string {
	out := map[string]string{}
	dir := r.SettingsDir
	if dir == nil {
		d, err := GlobalDir()
		if err != nil {
			return out
		}
		dir = &d
	}
	doc, err := dir.readSettings()
	if err != nil {
		return out
	}
	var env map[string]string
	if raw, ok := doc["env"]; !ok || json.Unmarshal(raw, &env) != nil {
		return out
	}
	for k, v := range env {
		if shellEnvKeys[k] && k != "PATH" && !strings.ContainsAny(v, "\x00\n") {
			out[k] = v
		}
	}
	return out
}

func (r *CLIResolver) candidates() []string {
	if r.Candidates != nil {
		return r.Candidates
	}
	home, _ := os.UserHomeDir()
	return []string{
		filepath.Join(home, ".local/bin/claude"), // native installer
		filepath.Join(home, ".claude/local/claude"),
		"/opt/homebrew/bin/claude",
		"/usr/local/bin/claude",
		filepath.Join(home, ".npm-global/bin/claude"),
		filepath.Join(home, ".bun/bin/claude"),
		filepath.Join(home, ".volta/bin/claude"),
	}
}

const (
	envBegin = "__LLMPILOT_ENV__"
	envEnd   = "__LLMPILOT_END__"
)

// shellEnv asks the user's interactive login shell for its environment —
// the only place PATH additions (nvm, the native installer) and proxy
// settings reliably live. Profile output before or after the dump is
// ignored; a shell that fails or hangs just yields nothing.
func (r *CLIResolver) shellEnv(ctx context.Context) map[string]string {
	shell := r.Shell
	if shell == "" {
		shell = userShell(ctx)
	}
	timeout := r.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	script := fmt.Sprintf(`printf '\n%s\n'; /usr/bin/env -0; printf '%s'`, envBegin, envEnd)
	cmd := exec.CommandContext(ctx, shell, "-ilc", script)
	cmd.Env = flattenEnv(baseEnv())
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	out, _ := cmd.Output() // a profile that exits non-zero still printed its env
	return parseShellEnv(out)
}

func parseShellEnv(out []byte) map[string]string {
	vars := map[string]string{}
	start := bytes.LastIndex(out, []byte(envBegin+"\n"))
	if start < 0 {
		return vars
	}
	body := out[start+len(envBegin)+1:]
	if end := bytes.LastIndex(body, []byte(envEnd)); end >= 0 {
		body = body[:end]
	} else {
		return vars // cut off mid-dump: trust none of it
	}
	for _, kv := range bytes.Split(body, []byte{0}) {
		k, v, ok := strings.Cut(string(kv), "=")
		if ok && shellEnvKeys[k] && !strings.ContainsAny(v, "\x00\n") {
			vars[k] = v
		}
	}
	return vars
}

// userShell reads the account's login shell from Directory Services — a
// launchd job has no $SHELL.
func userShell(ctx context.Context) string {
	if s := os.Getenv("SHELL"); s != "" && isExecutable(s) {
		return s
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/dscl", ".", "-read", "/Users/"+os.Getenv("USER"), "UserShell").Output()
	if err == nil {
		if _, s, ok := strings.Cut(strings.TrimSpace(string(out)), "UserShell:"); ok {
			if s = strings.TrimSpace(s); isExecutable(s) {
				return s
			}
		}
	}
	return "/bin/zsh"
}

func baseEnv() map[string]string {
	env := map[string]string{}
	for _, k := range processEnvKeys {
		if v := os.Getenv(k); v != "" {
			env[k] = v
		}
	}
	if os.Getenv("PATH") != "" {
		env["PATH"] = os.Getenv("PATH")
	}
	return env
}

func flattenEnv(env map[string]string) []string {
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	return out
}

func lookPath(name, path string) string {
	for _, dir := range filepath.SplitList(path) {
		if dir == "" || !filepath.IsAbs(dir) {
			continue
		}
		if p := filepath.Join(dir, name); isExecutable(p) {
			return p
		}
	}
	return ""
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Mode()&0o111 != 0
}

// LoginOptions configures one `claude auth login`.
type LoginOptions struct {
	CLI CLI
	// ConfigDir is the CLAUDE_CONFIG_DIR the sign-in lands in.
	ConfigDir string
	// Email pre-fills the sign-in page ("" = none).
	Email string
}

// LoginSession is one running `claude auth login`.
type LoginSession struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	done  chan struct{}

	mu        sync.Mutex
	manualURL string
	tail      []string // last few output lines, for an honest failure reason
	err       error
	stopped   bool
}

// manualURLRe finds the manual sign-in link in Claude Code's output. The URL
// rides an OSC 8 hyperlink, so it ends at the escape that closes it.
var manualURLRe = regexp.MustCompile(`https://[^\s\x1b\x07]+/oauth/authorize\?[^\s\x1b\x07]+`)

// ansiRe strips terminal escapes (CSI and OSC sequences) from output lines.
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)`)

// StartLogin starts Claude Code's own sign-in. It returns once the process
// is running; Claude Code opens the browser by itself.
func StartLogin(opts LoginOptions) (*LoginSession, error) {
	if opts.CLI.Path == "" {
		return nil, ErrCLINotFound
	}
	if opts.ConfigDir == "" || !filepath.IsAbs(opts.ConfigDir) {
		return nil, errors.New("sign-in needs an absolute config dir")
	}
	args := []string{"auth", "login", "--claudeai"}
	if opts.Email != "" {
		args = append(args, "--email", opts.Email)
	}
	cmd := exec.Command(opts.CLI.Path, args...)
	cmd.Dir = opts.ConfigDir
	cmd.Env = append(withoutKey(opts.CLI.Env, "CLAUDE_CONFIG_DIR"),
		"CLAUDE_CONFIG_DIR="+opts.ConfigDir,
		// A background sign-in must not update the user's install.
		"DISABLE_AUTOUPDATER=1",
	)
	// Its own process group, so Stop reaches anything it spawned too.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Wait must not hang on a grandchild that kept the output pipe open.
	cmd.WaitDelay = 2 * time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw
	if err := cmd.Start(); err != nil {
		_ = pw.Close()
		return nil, fmt.Errorf("start Claude Code: %w", err)
	}
	s := &LoginSession{cmd: cmd, stdin: stdin, done: make(chan struct{})}
	go s.scan(pr)
	go func() {
		werr := cmd.Wait()
		// WaitDelay reports a clean exit as ErrWaitDelay when something the
		// sign-in started still holds its output open. The exit status is
		// what says whether the sign-in finished.
		if errors.Is(werr, exec.ErrWaitDelay) && cmd.ProcessState != nil && cmd.ProcessState.Success() {
			werr = nil
		}
		_ = pw.Close()
		s.mu.Lock()
		s.err = werr
		s.mu.Unlock()
		close(s.done)
	}()
	return s, nil
}

func withoutKey(env []string, key string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if !strings.HasPrefix(kv, key+"=") {
			out = append(out, kv)
		}
	}
	return out
}

// scan reads Claude Code's output: it picks out the manual sign-in link and
// keeps the last few lines as the failure reason. Output is never logged.
func (s *LoginSession) scan(r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		s.mu.Lock()
		if s.manualURL == "" {
			if u := manualURLRe.FindString(line); u != "" && validManualURL(u) {
				s.manualURL = u
			}
		}
		if clean := strings.TrimSpace(ansiRe.ReplaceAllString(line, "")); clean != "" {
			s.tail = append(s.tail, clean)
			if len(s.tail) > 6 {
				s.tail = s.tail[1:]
			}
		}
		s.mu.Unlock()
	}
	_, _ = io.Copy(io.Discard, r)
}

// validManualURL accepts only an https link on an Anthropic host — this URL
// is opened in the user's browser, so it must not be whatever a hostile
// binary on PATH chose to print.
func validManualURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" {
		return false
	}
	h := strings.ToLower(u.Hostname())
	for _, ok := range []string{"claude.com", "claude.ai", "anthropic.com"} {
		if h == ok || strings.HasSuffix(h, "."+ok) {
			return true
		}
	}
	return false
}

// ManualURL is the sign-in link for a browser that didn't open (or opened
// somewhere unhelpful); approving there shows a code to paste. "" until
// Claude Code prints it.
func (s *LoginSession) ManualURL() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.manualURL
}

// ErrBadCode is a pasted code that cannot be what the sign-in page shows.
var ErrBadCode = errors.New("that doesn't look like the code from the sign-in page — copy it again")

// codeRe is the shape of the "<code>#<state>" the sign-in page shows.
var codeRe = regexp.MustCompile(`^[A-Za-z0-9._~+/=-]{8,}#[A-Za-z0-9._~+/=-]{8,}$`)

// maxCodeLen bounds a pasted code; real ones are well under 300 bytes.
const maxCodeLen = 2048

// NormalizeCode turns what a user pasted into the "<code>#<state>" Claude
// Code reads: surrounding space trimmed, and a pasted callback URL reduced
// to its code and state. Anything else is ErrBadCode — the result is
// written to a process's stdin, so it must be one line of known characters.
func NormalizeCode(pasted string) (string, error) {
	p := strings.TrimSpace(pasted)
	if strings.HasPrefix(p, "https://") {
		u, err := url.Parse(p)
		if err != nil {
			return "", ErrBadCode
		}
		q := u.Query()
		if q.Get("code") == "" || q.Get("state") == "" {
			return "", ErrBadCode
		}
		p = q.Get("code") + "#" + q.Get("state")
	}
	if len(p) > maxCodeLen || !codeRe.MatchString(p) {
		return "", ErrBadCode
	}
	return p, nil
}

// SubmitCode hands a pasted code to Claude Code, which finishes the sign-in.
func (s *LoginSession) SubmitCode(pasted string) error {
	code, err := NormalizeCode(pasted)
	if err != nil {
		return err
	}
	select {
	case <-s.done:
		return errors.New("this sign-in already ended — start it again")
	default:
	}
	if _, err := io.WriteString(s.stdin, code+"\n"); err != nil {
		return fmt.Errorf("handing the code to Claude Code: %w", err)
	}
	return nil
}

// Done is closed when the sign-in process has exited.
func (s *LoginSession) Done() <-chan struct{} { return s.done }

// Err is the outcome once Done is closed: nil when Claude Code reported a
// finished sign-in (exit 0). A failure carries Claude Code's own last words,
// escapes and links stripped.
func (s *LoginSession) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.err == nil {
		return nil
	}
	if s.stopped {
		return errStopped
	}
	reason := ""
	for i := len(s.tail) - 1; i >= 0; i-- {
		line := s.tail[i]
		if strings.Contains(line, "Paste code here") || strings.Contains(line, "://") {
			continue
		}
		reason = line
		break
	}
	if len(reason) > 200 {
		reason = reason[:200] + "…"
	}
	if reason == "" {
		return fmt.Errorf("the Claude Code sign-in ended without finishing (%v)", s.err)
	}
	return fmt.Errorf("the Claude Code sign-in ended without finishing: %s", reason)
}

var errStopped = errors.New("sign-in stopped")

// PID is the sign-in process's id (and its process group's).
func (s *LoginSession) PID() int { return s.cmd.Process.Pid }

// Stop ends the sign-in and everything it started: SIGTERM to the process
// group, SIGKILL if it is still there two seconds later. Safe to call more
// than once, and after the process exited.
func (s *LoginSession) Stop() {
	s.mu.Lock()
	select {
	case <-s.done:
		s.mu.Unlock()
		return
	default:
	}
	s.stopped = true
	s.mu.Unlock()
	pgid := s.cmd.Process.Pid
	_ = syscall.Kill(-pgid, syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(2 * time.Second):
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		<-s.done
	}
}
