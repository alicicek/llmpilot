package daemon

import "sync"

// broadcaster fans one State stream out to any number of SSE subscribers.
// Slow subscribers drop intermediate states (each channel holds the latest).
type broadcaster struct {
	mu   sync.Mutex
	subs map[chan State]struct{}
}

func newBroadcaster() *broadcaster {
	return &broadcaster{subs: map[chan State]struct{}{}}
}

func (b *broadcaster) subscribe() chan State {
	ch := make(chan State, 1)
	b.mu.Lock()
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch
}

func (b *broadcaster) unsubscribe(ch chan State) {
	b.mu.Lock()
	delete(b.subs, ch)
	b.mu.Unlock()
}

func (b *broadcaster) publish(st State) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs {
		select {
		case ch <- st:
		default:
			// subscriber still holds an unread state: replace it with the
			// newer one so it never reads stale-behind-latest.
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- st:
			default:
			}
		}
	}
}
