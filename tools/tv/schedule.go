package main

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"math"
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
	// slots are prepared this long before the look-ahead reaches them, so
	// their entry is in the schedule before the filler gets there and it
	// fills the gap up to it with items that fit
	slotLead = 6 * time.Hour
)

type entry struct {
	ID       string `json:"id"`
	Source   string `json:"source"`
	Title    string `json:"title"`
	Start    int64  `json:"start"`
	Duration int64  `json:"duration"`
	// the full length of File when a slot entry cuts it short (Duration)
	Length int64  `json:"length,omitempty"`
	File   string `json:"file"`
	// the audio of File alone (media.go copyAudio), if it has any
	Audio     string     `json:"audio,omitempty"`
	Queued    bool       `json:"queued,omitempty"`
	Link      string     `json:"link,omitempty"`
	Subtitles []subtitle `json:"subtitles,omitempty"`
	// id of the slot (state.Slots) this entry plays for; it stays at its start
	Slot string `json:"slot,omitempty"`
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
	// unix ms of the last weekly LLM channel suggestion run, and of its last
	// try, which failed if it is later
	ChannelsSuggestedAt    int64 `json:"channels_suggested_at,omitempty"`
	ChannelsSuggestTriedAt int64 `json:"channels_suggest_tried_at,omitempty"`
	// URLs of rejected suggestions and removed channels, oldest first; they
	// cannot be suggested again
	RejectedChannels []string `json:"rejected_channels,omitempty"`
	// one-off items at a fixed time, until their entry played
	Slots []timeSlot `json:"slots,omitempty"`
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

// fixed reports whether e is a slot's entry, which no edit moves.
func (e entry) fixed() bool { return e.Slot != "" }

// retime moves the entries from i on back to back, the first one starting at
// start. Slot entries keep their start: an entry that runs into one is cut
// at it (and gets its full length back when a later retime leaves room), one
// that would start at or after it goes behind it with the ones following.
func (st *state) retime(i int, start int64) {
	for ; i < len(st.Schedule); i++ {
		e := &st.Schedule[i]
		if e.fixed() {
			start = e.Start + e.Duration
			continue
		}
		if e.Length == 0 {
			e.Length = e.Duration
		}
		e.Duration = e.Length
		if j := slices.IndexFunc(st.Schedule[i+1:], entry.fixed); j >= 0 {
			j += i + 1
			f := st.Schedule[j]
			if start >= f.Start {
				copy(st.Schedule[i+1:j+1], st.Schedule[i:j])
				st.Schedule[i] = f
				start = f.Start + f.Duration
				continue
			}
			e.Duration = min(e.Duration, f.Start-start)
		}
		e.Start = start
		start += e.Duration
	}
}

// free returns where the filler puts its next item: the index after the
// entries that run back to back from now, and the time they end. Only a slot
// entry can follow a gap, so the item at the index, if any, is one.
func (st *state) free(now int64) (int, int64) {
	t := now
	for i, e := range st.Schedule {
		if e.fixed() && e.Start > t {
			return i, t
		}
		t = max(t, e.Start+e.Duration)
	}
	return len(st.Schedule), t
}

// fill puts a filler item at the free spot (free) and returns its entry,
// cut at the slot entry it runs into.
func (st *state) fill(e entry, now int64) entry {
	k, t := st.free(now)
	st.Schedule = slices.Insert(st.Schedule, k, e)
	st.retime(k, t)
	return st.Schedule[k]
}

// place puts the entry of a slot into the schedule at its start: the entry
// running then is cut there, the ones after it move behind it.
func (st *state) place(e entry) {
	i := slices.IndexFunc(st.Schedule, func(x entry) bool { return x.Start+x.Duration > e.Start })
	if i < 0 {
		i = len(st.Schedule)
	}
	if i < len(st.Schedule) && st.Schedule[i].Start < e.Start {
		r := &st.Schedule[i]
		if r.Length == 0 {
			r.Length = r.Duration
		}
		r.Duration = e.Start - r.Start
		i++
	}
	st.Schedule = slices.Insert(st.Schedule, i, e)
	st.retime(i+1, e.Start+e.Duration)
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
	errFixed   = errors.New("a slot's entry stays at its time, remove the slot instead")
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
	} else if len(st.Schedule) > 0 && !st.Schedule[0].fixed() {
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
	if err == nil && st.Schedule[i].fixed() {
		err = errFixed
	}
	if err != nil {
		return entry{}, err
	}
	return st.take(i), nil
}

// move puts the upcoming entry at sl right after the one at after, or right
// after the playing one for nil.
func (st *state) move(now int64, sl slot, after *slot) (entry, error) {
	i, err := st.find(now, sl)
	if err == nil && st.Schedule[i].fixed() {
		err = errFixed
	}
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
// back after the playing entry, or from now if that one is gone too.
func (st *state) dropMissing(now int64, exists func(file string) bool) {
	i, start := 0, now
	if st.playing(now) && exists(st.Schedule[0].File) {
		// it may be cut short by a play-now, which a retime would undo
		i, start = 1, st.Schedule[0].Start+st.Schedule[0].Duration
	}
	st.Schedule = slices.DeleteFunc(st.Schedule, func(e entry) bool { return !exists(e.File) })
	st.retime(i, start)
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

// covered reports whether the upcoming entries fill the look-ahead without a
// gap and something follows the playing one, also when it alone runs past
// it.
func covered(upcoming []entry, now int64, lookAhead time.Duration) bool {
	_, t := (&state{Schedule: upcoming}).free(now)
	return len(upcoming) > 1 && time.Duration(t-now)*time.Millisecond >= lookAhead
}

// tick drops finished entries and prepares at most one new item, a due slot
// first; it reports whether it added one, so the caller can go on filling
// right away. Pending requests go before filling, so it waits while there
// are any.
func (s *server) tick(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	now := nowMs()
	s.mu.Lock()
	s.st.Schedule = s.st.upcoming(now)
	cutoff := now - repeatAfter.Milliseconds()
	var history []played
	for _, p := range s.st.History {
		if p.At > cutoff {
			history = append(history, p)
		}
	}
	s.st.History = history
	s.st.pruneSlots(now)
	sl, due := s.st.dueSlot(now, s.lookAhead+slotLead)
	busy := slices.ContainsFunc(s.requests, func(r *request) bool { return r.State != "failed" })
	full := covered(s.st.Schedule, now, s.lookAhead)
	// the gap before the slot entry the filler runs into, if any
	gap := int64(math.MaxInt64)
	if k, t := s.st.free(now); k < len(s.st.Schedule) {
		gap = s.st.Schedule[k].Start - t
	}
	s.mu.Unlock()

	if s.cleanCache() >= s.cfg.CacheMaxBytes {
		return false
	}
	if due {
		return s.prepareSlot(ctx, sl)
	}
	if busy || full {
		return false
	}
	c, ok := s.next(ctx, gap)
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
		e = s.st.fill(e, nowMs())
		if c.Series != "" {
			s.st.Series[c.Series] = c.ref
		}
		log.Printf("scheduled %s %q at %s for %s", c.ID, c.Title, time.UnixMilli(e.Start).Format(time.TimeOnly), time.Duration(e.Duration)*time.Millisecond)
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

// cleanCache deletes everything in the cache dir that neither an entry, a
// slot nor a running or pending prepare uses and returns the size of what is
// left.
func (s *server) cleanCache() int64 {
	s.mu.Lock()
	keep := map[string]bool{s.preparing: true}
	for _, e := range s.st.Schedule {
		keep[e.File] = true
	}
	for _, sl := range s.st.Slots {
		keep[sl.File] = true
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
