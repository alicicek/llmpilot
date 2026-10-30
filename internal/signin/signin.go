// Package signin runs Claude Code's own sign-in for llmpilot. Each attempt
// gets a private staging folder under the llmpilot home; `claude auth
// login` signs in there, and when it finishes the result is filed into the
// fleet (switcher.ImportSignIn). The staging folder and its Keychain item
// are removed on every path — success, failure, cancel, timeout, and, for a
// daemon that died mid-attempt, the next start's Sweep.
package signin

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/switcher"
)

const (
	// stagingRoot is the folder under the llmpilot home that holds attempts.
	stagingRoot = "signin"
	// attemptPrefix names every staging folder; cleanup removes nothing else.
	attemptPrefix = "attempt-"
	// pidFile records the sign-in process so a later Sweep can stop it.
	pidFile = ".llmpilot-signin.pid"
)

// Manager starts sign-ins and cleans up after them.
type Manager struct {
	// Home is the llmpilot home; attempts live in Home/signin.
	Home string
	// Switcher files finished sign-ins into the fleet and forgets staging
	// Keychain items.
	Switcher *switcher.Switcher
	// CLI finds Claude Code (claudecfg.CLIResolver.Resolve in production).
	CLI func(ctx context.Context) (claudecfg.CLI, error)
	Log *slog.Logger
}

// Attempt is one running sign-in.
type Attempt struct {
	m    *Manager
	dir  claudecfg.Dir
	sess *claudecfg.LoginSession
	once sync.Once
}

func (m *Manager) log() *slog.Logger {
	if m.Log != nil {
		return m.Log
	}
	return slog.Default()
}

func (m *Manager) root() string { return filepath.Join(m.Home, stagingRoot) }

// Start launches `claude auth login` in a fresh staging folder. email, when
// set, pre-fills the sign-in page. Claude Code opens the browser itself.
func (m *Manager) Start(ctx context.Context, email string) (*Attempt, error) {
	cli, err := m.CLI(ctx)
	if err != nil {
		return nil, err
	}
	root := m.root()
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return nil, err
	}
	path, err := os.MkdirTemp(root, attemptPrefix) // 0700
	if err != nil {
		return nil, err
	}
	// The Keychain service name is a hash of the path Claude Code sees, so
	// both sides must use one spelling — the canonical one.
	if real, err := filepath.EvalSymlinks(path); err == nil {
		path = real
	}
	a := &Attempt{m: m, dir: claudecfg.DirAt(path)}
	sess, err := claudecfg.StartLogin(claudecfg.LoginOptions{CLI: cli, ConfigDir: path, Email: email})
	if err != nil {
		a.cleanup(ctx)
		return nil, err
	}
	a.sess = sess
	if err := os.WriteFile(filepath.Join(path, pidFile), []byte(strconv.Itoa(sess.PID())), 0o600); err != nil {
		m.log().Warn("sign-in: could not record the process id", "err", err)
	}
	return a, nil
}

// ManualURL is the link for a browser that didn't open ("" until known).
func (a *Attempt) ManualURL() string { return a.sess.ManualURL() }

// SubmitCode hands a code pasted from the sign-in page to Claude Code.
func (a *Attempt) SubmitCode(code string) error { return a.sess.SubmitCode(code) }

// Done is closed when Claude Code's sign-in has exited.
func (a *Attempt) Done() <-chan struct{} { return a.sess.Done() }

// Finish files the finished sign-in into the fleet, then removes the
// staging copy. Call after Done.
func (a *Attempt) Finish(ctx context.Context) (switcher.ImportResult, error) {
	defer a.cleanup(ctx)
	if err := a.sess.Err(); err != nil {
		return switcher.ImportResult{}, err
	}
	return a.m.Switcher.ImportSignIn(ctx, a.dir)
}

// Abort stops the sign-in and removes the staging copy. Idempotent.
func (a *Attempt) Abort() {
	if a.sess != nil {
		a.sess.Stop()
	}
	a.cleanup(context.Background())
}

// cleanup forgets the staging Keychain item and deletes the folder — once.
func (a *Attempt) cleanup(ctx context.Context) {
	a.once.Do(func() { a.m.remove(ctx, a.dir.Path()) })
}

// remove deletes one staging folder and its Keychain item. It refuses any
// path that is not an attempt folder directly inside the staging root.
func (m *Manager) remove(ctx context.Context, path string) {
	if err := m.isStaging(path); err != nil {
		m.log().Error("sign-in cleanup refused", "err", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
	defer cancel()
	if err := m.Switcher.ForgetDir(ctx, claudecfg.DirAt(path)); err != nil {
		// Leave the folder: the next Sweep retries the Keychain item, and it
		// finds the item through the folder's path.
		m.log().Warn("sign-in cleanup: staging Keychain item not removed yet", "err", err)
		return
	}
	if err := os.RemoveAll(path); err != nil {
		m.log().Warn("sign-in cleanup: staging folder not removed", "err", err)
	}
}

// isStaging is the guard every deletion passes: an attempt-* folder whose
// parent is exactly the staging root, symlinks resolved on both sides.
func (m *Manager) isStaging(path string) error {
	root := m.root()
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}
	p := filepath.Clean(path)
	if r, err := filepath.EvalSymlinks(p); err == nil {
		p = r
	}
	if filepath.Dir(p) != root || !strings.HasPrefix(filepath.Base(p), attemptPrefix) {
		return fmt.Errorf("%s is not a sign-in staging folder", path)
	}
	return nil
}

// Sweep clears what a daemon that died mid-sign-in left behind: it stops a
// sign-in process still running for a staging folder, then removes the
// folder and its Keychain item. Run once at daemon start, before any new
// attempt.
func (m *Manager) Sweep(ctx context.Context) {
	entries, err := os.ReadDir(m.root())
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			m.log().Warn("sign-in sweep", "err", err)
		}
		return
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), attemptPrefix) {
			continue
		}
		path := filepath.Join(m.root(), e.Name())
		if r, err := filepath.EvalSymlinks(path); err == nil {
			path = r
		}
		stopLeftover(ctx, path)
		m.remove(ctx, path)
		m.log().Info("sign-in sweep: removed a leftover staging folder", "folder", e.Name())
	}
}

// stopLeftover stops the sign-in process recorded for a staging folder, if
// that process is still a `claude auth login` running in that folder. A
// recycled pid belonging to anything else is left alone.
func stopLeftover(ctx context.Context, path string) {
	raw, err := os.ReadFile(filepath.Join(path, pidFile))
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		return
	}
	if !isOurSignIn(ctx, pid, path) {
		return
	}
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	for i := 0; i < 20; i++ {
		if syscall.Kill(pid, 0) != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
}

// isOurSignIn checks a pid before Sweep signals it: its command line must be
// `auth login` and its working folder this staging folder (StartLogin runs
// Claude Code there). macOS hides other processes' environments from ps, so
// the folder is the identifying mark.
func isOurSignIn(ctx context.Context, pid int, path string) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmdline, err := exec.CommandContext(ctx, "/bin/ps", "-ww", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil || !strings.Contains(string(cmdline), "auth login") {
		return false
	}
	out, err := exec.CommandContext(ctx, "/usr/sbin/lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(out), "\n") {
		if cwd, ok := strings.CutPrefix(line, "n"); ok {
			if r, err := filepath.EvalSymlinks(cwd); err == nil {
				cwd = r
			}
			return cwd == path
		}
	}
	return false
}
