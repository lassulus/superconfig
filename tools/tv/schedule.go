package main

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

const (
	repeatAfter = 30 * 24 * time.Hour
	// lets clients load an item that cuts in before it starts
	cutoverLead = 5 * time.Second
)

type entry struct {
	ID       string `json:"id"`
	Source   string `json:"source"`
	Title    string `json:"title"`
	Start    int64  `json:"start"`
	Duration int64  `json:"duration"`
	File     string `json:"file"`
	Queued   bool   `json:"queued,omitempty"`
}

type played struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	At    int64  `json:"at"`
}

type state struct {
	Schedule []entry  `json:"schedule"`
	History  []played `json:"history"`
	// series id -> id of the last scheduled episode
	Series map[string]string `json:"series"`
	// unix ms of the last daily Jellyseerr run
	MoviesRequestedAt int64 `json:"movies_requested_at,omitempty"`
	// TMDB ids requested through Jellyseerr
	RequestedMovies []int `json:"requested_movies,omitempty"`
}

// upcoming returns the entry playing at t (unix ms), if any, and the ones
// after it.
func (st *state) upcoming(t int64) []entry {
	for i, e := range st.Schedule {
		if t < e.Start+e.Duration {
			return st.Schedule[i:]
		}
	}
	return nil
}

// retime moves the entries from i on back to back, the first one starting at
// start.
func (st *state) retime(i int, start int64) {
	for ; i < len(st.Schedule); i++ {
		st.Schedule[i].Start = start
		start += st.Schedule[i].Duration
	}
}

// playing drops finished entries and reports whether the first one plays at
// now.
func (st *state) playing(now int64) bool {
	st.Schedule = st.upcoming(now)
	return len(st.Schedule) > 0 && st.Schedule[0].Start <= now
}

// enqueue inserts e after the playing entry and the queued ones after it.
func (st *state) enqueue(e entry, now int64) {
	i, start := 0, now
	if st.playing(now) {
		i = 1
	}
	for i < len(st.Schedule) && st.Schedule[i].Queued {
		i++
	}
	if i > 0 {
		start = st.Schedule[i-1].Start + st.Schedule[i-1].Duration
	}
	e.Queued = true
	st.Schedule = slices.Insert(st.Schedule, i, e)
	st.retime(i, start)
}

// skip ends the playing entry now and moves the rest earlier.
func (st *state) skip(now int64) {
	if st.playing(now) {
		st.Schedule = st.Schedule[1:]
	}
	st.retime(0, now)
}

// playAt cuts the playing entry at t and starts e there; the rest moves back.
func (st *state) playAt(e entry, now, t int64) {
	i := 0
	if st.playing(now) {
		i = 1
		cur := &st.Schedule[0]
		cur.Duration = min(cur.Duration, t-cur.Start)
		t = cur.Start + cur.Duration
	}
	st.Schedule = slices.Insert(st.Schedule, i, e)
	st.retime(i, t)
}

// dropMissing removes entries without a file and retimes the rest back to
// back from the playing entry, or from now if that one is gone too.
func (st *state) dropMissing(now int64, exists func(file string) bool) {
	start := now
	if st.playing(now) && exists(st.Schedule[0].File) {
		start = st.Schedule[0].Start
	}
	st.Schedule = slices.DeleteFunc(st.Schedule, func(e entry) bool { return !exists(e.File) })
	st.retime(0, start)
}

func loadState(path string) (state, error) {
	st := state{Series: map[string]string{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return st, nil
	}
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(b, &st); err != nil {
		return st, err
	}
	if st.Series == nil {
		st.Series = map[string]string{}
	}
	return st, nil
}

func saveState(path string, st state) error {
	b, err := json.MarshalIndent(st, "", " ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (s *server) run(ctx context.Context) {
	for {
		worked := s.tick(ctx)
		if worked {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(30 * time.Second):
		}
	}
}

// tick drops finished entries and prepares at most one new item; it reports
// whether it added one, so the caller can go on filling right away. Pending
// requests go first, so it waits while there are any.
func (s *server) tick(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	now := nowMs()
	s.mu.Lock()
	s.st.Schedule = s.st.upcoming(now)
	end := now
	if n := len(s.st.Schedule); n > 0 {
		end = max(end, s.st.Schedule[n-1].Start+s.st.Schedule[n-1].Duration)
	}
	cutoff := now - repeatAfter.Milliseconds()
	var history []played
	for _, p := range s.st.History {
		if p.At > cutoff {
			history = append(history, p)
		}
	}
	s.st.History = history
	busy := slices.ContainsFunc(s.requests, func(r *request) bool { return r.State != "failed" })
	s.mu.Unlock()

	if s.cleanCache() >= s.cfg.CacheMaxBytes || busy || time.Duration(end-now)*time.Millisecond >= s.lookAhead {
		return false
	}
	c, ok := s.next(ctx)
	if !ok {
		return false
	}
	log.Printf("preparing %s %q", c.ID, c.Title)
	file := fileName(c)
	s.mu.Lock()
	s.preparing = file
	s.mu.Unlock()
	dur, err := s.prepare(ctx, c, file)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.preparing = ""
	// failed items go into the history too, so they are not picked again soon
	s.st.History = append(s.st.History, played{ID: c.ID, Title: c.Title, At: nowMs()})
	if err != nil {
		log.Printf("preparing %s failed: %v", c.ID, err)
	} else {
		start := nowMs()
		if n := len(s.st.Schedule); n > 0 {
			start = max(start, s.st.Schedule[n-1].Start+s.st.Schedule[n-1].Duration)
		}
		s.st.Schedule = append(s.st.Schedule, entry{ID: c.ID, Source: c.source(), Title: c.Title, Start: start, Duration: dur, File: file})
		if c.Series != "" {
			s.st.Series[c.Series] = c.ref
		}
		log.Printf("scheduled %s %q at %s for %s", c.ID, c.Title, time.UnixMilli(start).Format(time.TimeOnly), time.Duration(dur)*time.Millisecond)
	}
	s.save()
	return err == nil
}

// save persists the state; callers hold s.mu.
func (s *server) save() {
	if err := saveState(s.statePath, s.st); err != nil {
		log.Printf("saving state: %v", err)
	}
}

// cleanCache deletes everything in the cache dir that neither an entry nor a
// running or pending prepare uses and returns the size of what is left.
func (s *server) cleanCache() int64 {
	s.mu.Lock()
	keep := map[string]bool{s.preparing: true}
	for _, e := range s.st.Schedule {
		keep[e.File] = true
	}
	for _, r := range s.requests {
		keep[r.file] = true
	}
	// files are registered before they are created, so listed and not kept means garbage
	des, err := os.ReadDir(s.cfg.CacheDir)
	s.mu.Unlock()
	if err != nil {
		log.Printf("reading cache dir: %v", err)
		return 0
	}
	var size int64
	for _, de := range des {
		path := filepath.Join(s.cfg.CacheDir, de.Name())
		// work files are named <file>.part and <file>.dl
		base, _, _ := strings.Cut(de.Name(), ".mp4")
		if !keep[base+".mp4"] {
			if err := os.RemoveAll(path); err != nil {
				log.Printf("cleaning cache: %v", err)
			}
			continue
		}
		if fi, err := de.Info(); err == nil {
			size += fi.Size()
		}
	}
	return size
}
