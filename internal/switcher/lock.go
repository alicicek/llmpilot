// Package switcher performs corruption-proof account swaps: lock-first,
// backup-first, atomic writes, verified after. It is the ONLY credential
// write path in llmpilot; every other component switches through it.
//
// Lock design (verified against the real Claude Code 2.1.205 binary by
// strings-dump on 2026-07-09):
//   - Claude Code guards its OAuth token refresh with a proper-lockfile-style
//     mkdir-mutex at <configdir>/.oauth_refresh.lock (stale 10s) and its
//     secure-storage (Keychain) writes with <configdir>/.storage-write
//     (stale 15s). Holding both blocks a concurrent CC refresh — that closes
//     the refresh-clobber race (hazard #1).
//   - ~/.claude.json itself has NO lock in CC; its writes are atomic
//     tempfile+rename. We splice it the same way.
//   - We ALSO take claude-swap's legacy paths (~/.claude.lock,
//     ~/.claude.json.lock) so a claude-swap running beside us can't
//     interleave.
package switcher

import (
	"context"
	"fmt"
	"os"
	"time"
)

// mutexLock is a proper-lockfile-compatible mkdir mutex: mkdir to acquire,
// mtime for liveness (touched at stale/3 like proper-lockfile's default
// update), rmdir to release; a lock whose mtime is older than stale is dead
// and may be taken over.
type mutexLock struct {
	dir   string
	stale time.Duration
	// owned identifies OUR mkdir by inode (os.SameFile): if a peer reaped
	// this lock as stale (e.g. we were frozen across a system sleep) and
	// re-created it, the inode differs and we must neither touch nor remove
	// what is now THEIR lock.
	owned os.FileInfo
	stop  chan struct{}
	done  chan struct{}
}

// acquireLock takes the mkdir mutex at dir, waiting up to timeout.
func acquireLock(ctx context.Context, dir string, stale, timeout time.Duration) (*mutexLock, error) {
	deadline := time.Now().Add(timeout)
	for {
		err := os.Mkdir(dir, 0o755)
		if err == nil {
			fi, statErr := os.Stat(dir)
			if statErr != nil {
				_ = os.Remove(dir) // don't orphan the lock we just created
				return nil, fmt.Errorf("acquire lock %s: %w", dir, statErr)
			}
			l := &mutexLock{dir: dir, stale: stale, owned: fi, stop: make(chan struct{}), done: make(chan struct{})}
			go l.touch()
			return l, nil
		}
		if !os.IsExist(err) {
			return nil, fmt.Errorf("acquire lock %s: %w", dir, err)
		}
		// Held by someone. Dead if the holder stopped touching it.
		if fi, statErr := os.Stat(dir); statErr == nil && time.Since(fi.ModTime()) > stale {
			// Stale takeover: remove and retry. A racing takeover loses the
			// Mkdir on the next spin — that is the correctness point.
			_ = os.Remove(dir)
			continue
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("lock %s: held by a live process after %s (is a Claude Code refresh or another switcher running?)", dir, timeout)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// touch keeps the lock's mtime fresh so live holders are never reaped.
func (l *mutexLock) touch() {
	defer close(l.done)
	t := time.NewTicker(l.stale / 3)
	defer t.Stop()
	for {
		select {
		case <-l.stop:
			return
		case <-t.C:
			if !l.stillOwned() {
				return // compromised: a peer reaped us — never touch their lock
			}
			now := time.Now()
			_ = os.Chtimes(l.dir, now, now)
		}
	}
}

// stillOwned reports whether the lock dir is still the one WE created.
func (l *mutexLock) stillOwned() bool {
	fi, err := os.Stat(l.dir)
	return err == nil && os.SameFile(fi, l.owned)
}

// release stops the toucher and removes the lock directory — only if it is
// still ours. Removing a successor's lock would let a third party in.
func (l *mutexLock) release() {
	close(l.stop)
	<-l.done
	if l.stillOwned() {
		_ = os.Remove(l.dir)
	}
}
