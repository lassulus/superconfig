package main

import "sync"

const (
	// how often a player polls api/time (player.js: setInterval(sampleClock, 3000))
	viewerPoll = 3000
	// a viewer counts while its last poll is at most two polls old, so one lost poll does not drop it
	viewerWindow = 2 * viewerPoll
	// at most this many ids, so made-up ones cannot grow memory
	maxViewers = 1000
	// a player's id: 16 lowercase hex digits, random per page load
	viewerIDLen = 16
)

type viewer struct {
	seen  int64
	audio bool
}

// viewers counts the players polling api/time with an id; ids live in memory only.
type viewers struct {
	mu  sync.Mutex
	ids map[string]viewer
}

func validViewerID(id string) bool {
	if len(id) != viewerIDLen {
		return false
	}
	for _, c := range id {
		if !('0' <= c && c <= '9' || 'a' <= c && c <= 'f') {
			return false
		}
	}
	return true
}

// see records a poll of id at now (unix ms); invalid ids and new ones beyond maxViewers are ignored.
func (v *viewers) see(id string, audio bool, now int64) {
	if !validViewerID(id) {
		return
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.ids == nil {
		v.ids = map[string]viewer{}
	}
	if _, ok := v.ids[id]; !ok && len(v.ids) >= maxViewers {
		v.prune(now)
		if len(v.ids) >= maxViewers {
			return
		}
	}
	v.ids[id] = viewer{now, audio}
}

// prune drops the ids not seen within viewerWindow; callers hold v.mu.
func (v *viewers) prune(now int64) {
	for id, vw := range v.ids {
		if now-vw.seen > viewerWindow {
			delete(v.ids, id)
		}
	}
}

// count returns how many players polled within viewerWindow, and how many of them play audio only.
func (v *viewers) count(now int64) (all, audio int) {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.prune(now)
	for _, vw := range v.ids {
		if vw.audio {
			audio++
		}
	}
	return len(v.ids), audio
}
