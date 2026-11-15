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
	ID        string     `json:"id"`
	Source    string     `json:"source"`
	Title     string     `json:"title"`
	Start     int64      `json:"start"`
	Duration  int64      `json:"duration"`
	File      string     `json:"file"`
	Queued    bool       `json:"queued,omitempty"`
	Link      string     `json:"link,omitempty"`
	Subtitles []subtitle `json:"subtitles,omitempty"`
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
	// YouTube channels the picker lists, and suggested ones waiting for the
	// admin
	Channels           []channel `json:"channels,omitempty"`
	ChannelSuggestions []channel `json:"channel_suggestions,omitempty"`
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

// slot addresses a schedule entry for edits: start is unique, id guards
// against a schedule that moved since the client looked.
type slot struct {
	Start int64  `json:"start"`
	ID    string `json:"id"`
}

var (
	errPlaying = errors.New("the playing entry cannot be edited, only skipped")
	errStale   = errors.New("no upcoming entry with this start and id, the schedule moved")
)

// first drops finished entries and returns the index of the first entry
// after the playing one.
func (st *state) first(now int64) int {
	if st.playing(now) {
		return 1
	}
	return 0
}

// find returns the index of the upcoming, not playing entry at sl.
func (st *state) find(now int64, sl slot) (int, error) {
	i := st.first(now)
	if i == 1 && st.Schedule[0].Start == sl.Start && st.Schedule[0].ID == sl.ID {
		return 0, errPlaying
	}
	for ; i < len(st.Schedule); i++ {
		if st.Schedule[i].Start == sl.Start && st.Schedule[i].ID == sl.ID {
			return i, nil
		}
	}
	return 0, errStale
}

// scheduled returns the index of the upcoming, not playing entry of source
// id, or -1.
func (st *state) scheduled(now int64, id string) int {
	for i := st.first(now); i < len(st.Schedule); i++ {
		if st.Schedule[i].ID == id {
			return i
		}
	}
	return -1
}

// take removes entry i; the ones after it move up into its start.
func (st *state) take(i int) entry {
	e := st.Schedule[i]
	st.Schedule = slices.Delete(st.Schedule, i, i+1)
	st.retime(i, e.Start)
	return e
}

// insertAt puts e at index i (not before the playing entry) back to back
// after its predecessor and moves the rest back. Like enqueue, it is queued
// when it lands in the run of queued entries after the playing one, so later
// requests line up behind it.
func (st *state) insertAt(e entry, now int64, i int) {
	f := st.first(now)
	start := now
	if i > 0 {
		start = st.Schedule[i-1].Start + st.Schedule[i-1].Duration
	} else if len(st.Schedule) > 0 {
		start = st.Schedule[0].Start
	}
	e.Queued = !slices.ContainsFunc(st.Schedule[f:i], func(e entry) bool { return !e.Queued })
	st.Schedule = slices.Insert(st.Schedule, i, e)
	st.retime(i, start)
}

// after returns the index an entry goes to when it follows after, or the
// playing entry for nil; after may be the playing entry itself.
func (st *state) after(now int64, after *slot) (int, error) {
	if after == nil {
		return st.first(now), nil
	}
	j, err := st.find(now, *after)
	if errors.Is(err, errPlaying) {
		return 1, nil
	}
	return j + 1, err
}

// remove deletes the upcoming entry at sl.
func (st *state) remove(now int64, sl slot) (entry, error) {
	i, err := st.find(now, sl)
	if err != nil {
		return entry{}, err
	}
	return st.take(i), nil
}

// move puts the upcoming entry at sl right after the one at after, or right
// after the playing one for nil.
func (st *state) move(now int64, sl slot, after *slot) (entry, error) {
	i, err := st.find(now, sl)
	if err != nil {
		return entry{}, err
	}
	j, err := st.after(now, after)
	if err != nil {
		return entry{}, err
	}
	if j == i || j == i+1 {
		// already there
		return st.Schedule[i], nil
	}
	e := st.take(i)
	if j > i {
		j--
	}
	st.insertAt(e, now, j)
	return st.Schedule[j], nil
}

// insert puts e right after the entry at after, or after the playing one if
// after is nil or gone.
func (st *state) insert(e entry, now int64, after *slot) {
	j, err := st.after(now, after)
	if err != nil {
		j = st.first(now)
	}
	st.insertAt(e, now, j)
}

// playNow moves the upcoming entry i to start at t, cutting the playing one.
func (st *state) playNow(i int, now, t int64) {
	st.playAt(st.take(i), now, t)
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
	e, err := s.prepare(ctx, c, file)
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
		e.Start = start
		s.st.Schedule = append(s.st.Schedule, e)
		if c.Series != "" {
			s.st.Series[c.Series] = c.ref
		}
		log.Printf("scheduled %s %q at %s for %s", c.ID, c.Title, time.UnixMilli(start).Format(time.TimeOnly), time.Duration(e.Duration)*time.Millisecond)
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
