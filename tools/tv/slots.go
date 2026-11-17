package main

import (
	"cmp"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"
)

// a failed slot prepare is tried again after this
const slotRetry = 10 * time.Minute

// timeSlot is a one-off item at a fixed time (unix ms). It is prepared once
// its time is within the look-ahead plus slotLead; its entry (entry.Slot)
// then starts at it, or as soon as it is ready if that is later.
type timeSlot struct {
	ID string `json:"id"`
	At int64  `json:"at"`
	// candidate id of the item: "jf:<item id>" or "yt:<video id>"
	Item     string `json:"item"`
	Source   string `json:"source"`
	Title    string `json:"title"`
	Duration int64  `json:"duration"`
	// "admin" for the admin key, else the name of the logged-in user
	By string `json:"by"`
	// the prepared file, once its entry is in the schedule
	File string `json:"file,omitempty"`
	// of the last failed prepare
	Error string `json:"error,omitempty"`
	// waiting, preparing, scheduled or failed; only in api/schedule
	State    string `json:"state,omitempty"`
	failedAt int64
}

var (
	errPast   = errors.New("this time is in the past")
	errNoSlot = errors.New("no slot with this id")
)

// itemCandidate turns a candidate id back into a candidate without metadata.
func itemCandidate(id string) (candidate, error) {
	src, ref, _ := strings.Cut(id, ":")
	if src == "yt" {
		ref = "https://youtu.be/" + ref
	}
	return parseURL(ref)
}

// addSlot adds sl unless its time is past or its item would overlap the
// item of another slot.
func (st *state) addSlot(sl timeSlot, now int64) error {
	if sl.At <= now {
		return errPast
	}
	for _, o := range st.Slots {
		if sl.At < o.At+o.Duration && o.At < sl.At+sl.Duration {
			return fmt.Errorf("it overlaps the slot of %q", o.Title)
		}
	}
	i, _ := slices.BinarySearchFunc(st.Slots, sl.At, func(o timeSlot, at int64) int { return cmp.Compare(o.At, at) })
	st.Slots = slices.Insert(st.Slots, i, sl)
	return nil
}

// removeSlot drops the slot id and its entry, unless that plays; the entries
// after it move up, the one before it gets back what the slot cut off.
func (st *state) removeSlot(now int64, id string) (timeSlot, error) {
	i := slices.IndexFunc(st.Slots, func(sl timeSlot) bool { return sl.ID == id })
	if i < 0 {
		return timeSlot{}, errNoSlot
	}
	f := st.first(now)
	if j := slices.IndexFunc(st.Schedule, func(e entry) bool { return e.Slot == id }); j >= 0 {
		if j < f {
			return timeSlot{}, errPlaying
		}
		st.Schedule = slices.Delete(st.Schedule, j, j+1)
		start := now
		if j > 0 {
			start = st.Schedule[j-1].Start + st.Schedule[j-1].Duration
		}
		if j > f {
			j--
			start = st.Schedule[j].Start
		}
		st.retime(j, start)
	}
	sl := st.Slots[i]
	st.Slots = slices.Delete(st.Slots, i, i+1)
	return sl, nil
}

// pruneSlots drops the slots whose entry played and the ones that were never
// ready before their item would have ended.
func (st *state) pruneSlots(now int64) {
	st.Slots = slices.DeleteFunc(st.Slots, func(sl timeSlot) bool {
		if sl.File != "" {
			return !slices.ContainsFunc(st.Schedule, func(e entry) bool { return e.Slot == sl.ID })
		}
		if now > sl.At+sl.Duration {
			log.Printf("slot %s %q at %s missed: %s", sl.ID, sl.Title, time.UnixMilli(sl.At).Format(time.DateTime), sl.Error)
			return true
		}
		return false
	})
}

// dueSlot returns the earliest slot to prepare: not prepared, within horizon
// and not failed within slotRetry.
func (st *state) dueSlot(now int64, horizon time.Duration) (timeSlot, bool) {
	for _, sl := range st.Slots {
		if sl.File == "" && sl.At-now <= horizon.Milliseconds() && (sl.failedAt == 0 || now-sl.failedAt > slotRetry.Milliseconds()) {
			return sl, true
		}
	}
	return timeSlot{}, false
}

// slots returns copies of the slots with their state; callers hold s.mu.
func (s *server) slots() []timeSlot {
	out := []timeSlot{}
	for _, sl := range s.st.Slots {
		switch {
		case sl.File != "":
			sl.State = "scheduled"
		case sl.ID == s.preparingSlot:
			sl.State = "preparing"
		case sl.Error != "":
			sl.State = "failed"
		default:
			sl.State = "waiting"
		}
		out = append(out, sl)
	}
	return out
}

// prepareSlot prepares the item of sl and places its entry; it reports
// whether it did.
func (s *server) prepareSlot(ctx context.Context, sl timeSlot) bool {
	c, err := itemCandidate(sl.Item)
	if err != nil {
		log.Printf("slot %s: %v", sl.ID, err)
		return false
	}
	c.Title = sl.Title
	log.Printf("preparing slot %s %s %q for %s", sl.ID, c.ID, c.Title, time.UnixMilli(sl.At).Format(time.DateTime))
	file := fileName(c)
	s.mu.Lock()
	s.preparing, s.preparingSlot = file, sl.ID
	s.mu.Unlock()
	e, err := s.prepare(ctx, c, file)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.preparing, s.preparingSlot = "", ""
	now := nowMs()
	i := slices.IndexFunc(s.st.Slots, func(x timeSlot) bool { return x.ID == sl.ID })
	if i < 0 {
		log.Printf("slot %s was removed while preparing", sl.ID)
		return false
	}
	p := &s.st.Slots[i]
	if err != nil {
		log.Printf("preparing slot %s failed: %v", sl.ID, err)
		p.Error, p.failedAt = err.Error(), now
		s.save()
		return false
	}
	e.Slot, e.Start = sl.ID, max(p.At, now+cutoverLead.Milliseconds())
	s.st.place(e)
	p.File, p.Duration, p.Error = file, e.Duration, ""
	s.st.History = append(s.st.History, played{ID: c.ID, Title: c.Title, At: now})
	s.save()
	log.Printf("scheduled slot %s %q at %s", sl.ID, c.Title, time.UnixMilli(e.Start).Format(time.DateTime))
	return true
}

// handleSlot serves api/slots/add and api/slots/remove for the editor by.
func (s *server) handleSlot(w http.ResponseWriter, r *http.Request, by string, add bool) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "use POST")
		return
	}
	var body struct {
		URL string `json:"url"`
		At  int64  `json:"at"`
		ID  string `json:"id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, `body must be JSON like {"url": "...", "at": <unix ms>} or {"id": "..."}`)
		return
	}
	if !add {
		s.mu.Lock()
		now := nowMs()
		sl, err := s.st.removeSlot(now, body.ID)
		if err == nil {
			s.save()
		}
		out := s.schedule(now)
		s.mu.Unlock()
		switch {
		case errors.Is(err, errNoSlot):
			writeError(w, http.StatusNotFound, err.Error())
		case err != nil:
			writeError(w, http.StatusConflict, err.Error())
		default:
			log.Printf("removed slot %s %q (by %s)", sl.ID, sl.Title, by)
			writeJSON(w, http.StatusOK, out)
		}
		return
	}
	c, err := parseURL(body.URL)
	if err == nil && body.At <= nowMs() {
		err = errPast
	}
	if err == nil {
		c, err = s.lookup(r.Context(), c)
	}
	if d := time.Duration(c.Duration) * time.Second; err == nil && d > maxDuration {
		err = fmt.Errorf("%q is %s long, the limit is %s", c.Title, d, maxDuration)
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	sl := timeSlot{ID: rand.Text(), At: body.At, Item: c.ID, Source: c.source(), Title: c.Title, Duration: c.Duration * 1000, By: by}
	s.mu.Lock()
	if err = s.st.addSlot(sl, nowMs()); err == nil {
		s.save()
	}
	s.mu.Unlock()
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	log.Printf("slot %s: %s %q at %s by %s", sl.ID, sl.Item, sl.Title, time.UnixMilli(sl.At).Format(time.DateTime), by)
	writeJSON(w, http.StatusOK, sl)
}

// handleSearch serves api/search?q=: Jellyfin movies and episodes by name.
func (s *server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" || s.cfg.JellyfinURL == "" {
		writeError(w, http.StatusBadRequest, "needs ?q= and a Jellyfin")
		return
	}
	items, err := s.jellyfinItems(r.Context(), "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Movie,Episode"},
		"searchTerm": {q}, "Limit": {"20"}})
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	type result struct {
		ID       string `json:"id"`
		Title    string `json:"title"`
		Year     int    `json:"year,omitempty"`
		Duration int64  `json:"duration"`
	}
	out := []result{}
	for _, it := range items {
		if it.RunTimeTicks > 0 && it.LocationType != "Virtual" {
			out = append(out, result{it.ID, itemTitle(it), it.Year, it.RunTimeTicks / 10_000})
		}
	}
	writeJSON(w, http.StatusOK, out)
}
