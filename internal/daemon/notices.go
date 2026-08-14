package daemon

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// Notice is the wire shape of one user-facing notification, delivered live
// over the authenticated GET /v1/notices SSE stream to any connected native
// app. Title/body carry the exact copy the legacy osascript banner would
// have shown — the native app posts them through UNUserNotificationCenter
// itself; the daemon never knows or cares how they end up on screen.
type Notice struct {
	ID    string    `json:"id"`
	At    time.Time `json:"at"`
	Title string    `json:"title"`
	Body  string    `json:"body"`
}

// noticeSeq disambiguates two notices dispatched within the same
// nanosecond. Ids are not secret — a process-wide counter is enough, no
// crypto/rand needed.
var noticeSeq atomic.Uint64

func newNoticeID() string {
	return fmt.Sprintf("%d-%d", time.Now().UnixNano(), noticeSeq.Add(1))
}

// noticeBus fans dispatched notices out to any connected /v1/notices SSE
// subscriber. Unlike broadcaster (events.go), it never coalesces to "latest
// wins": every dispatched notice is its own discrete user-facing event, so
// each subscriber gets a small buffered channel instead of a size-1 slot.
//
// Stateless by design (chunk 5B spec): a notice dispatched while nobody is
// subscribed is never queued or replayed for a later connection — see
// dispatch's fallback path. That is the whole point: the legacy osascript
// banner already covers "nobody was watching," so there is nothing to
// replay.
type noticeBus struct {
	mu   sync.Mutex
	subs map[chan Notice]struct{}
}

func newNoticeBus() *noticeBus {
	return &noticeBus{subs: map[chan Notice]struct{}{}}
}

func (b *noticeBus) subscribe() chan Notice {
	ch := make(chan Notice, 4)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *noticeBus) unsubscribe(ch chan Notice) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
	// Deliberately never closed (same discipline as broadcaster.unsubscribe):
	// a send from a dispatch that already snapshotted this channel (see
	// below) must never panic on a closed channel. Unreferenced after this
	// call, the channel is simply garbage.
}

// dispatch delivers n to every subscriber connected AT THIS INSTANT, or —
// only when there were none — runs fallback. The subscriber snapshot is
// taken under the same lock subscribe/unsubscribe use, so the DECISION
// (fan-out vs. fallback) is atomic with respect to concurrent (un)subscribe
// calls; the actual send/fallback work happens after the lock is released,
// since fallback may shell out to osascript and holding the lock across that
// would stall an unrelated concurrent SSE connect/disconnect.
//
// This leaves one narrow, accepted race: a subscriber that connects or
// disconnects in the gap between the snapshot and the send/fallback sees the
// PREVIOUS decision for this one notice. There is no replay/ring buffer
// (stateless by design — see the type doc), so that subscriber simply isn't
// caught up; the NEXT notice always reflects current subscriber state.
func (b *noticeBus) dispatch(n Notice, fallback func()) {
	b.mu.Lock()
	subs := make([]chan Notice, 0, len(b.subs))
	for ch := range b.subs {
		subs = append(subs, ch)
	}
	b.mu.Unlock()

	if len(subs) == 0 {
		fallback()
		return
	}
	for _, ch := range subs {
		select {
		case ch <- n:
		default:
			// This subscriber's buffer is full — notices are rare (threshold
			// crossings, autopilot events), so this only drops under a burst
			// a slow reader was never going to keep up with. Never block the
			// dispatcher over one stuck client.
		}
	}
}

// NoticeDispatcher turns a legacy UserNotifier (macNotify in production, the
// slog sandbox stub under LLMPILOT_TEST) into the fan-out NotifyUser is
// wired to everywhere now: deliver to /v1/notices subscribers, and fall back
// to the wrapped notifier ONLY when nobody was connected at dispatch time.
// The wrapped notifier is never called directly — this is the sole path.
func (d *Daemon) NoticeDispatcher(fallback UserNotifier) UserNotifier {
	return func(ctx context.Context, title, body string) {
		n := Notice{ID: newNoticeID(), At: time.Now(), Title: title, Body: body}
		d.notices.dispatch(n, func() {
			if fallback != nil {
				fallback(ctx, title, body)
			}
		})
	}
}
