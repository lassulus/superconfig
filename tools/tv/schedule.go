package main

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"
)

const repeatAfter = 30 * 24 * time.Hour

type entry struct {
	ID       string `json:"id"`
	Source   string `json:"source"`
	Title    string `json:"title"`
	Start    int64  `json:"start"`
	Duration int64  `json:"duration"`
	File     string `json:"file"`
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
// whether it added one, so the caller can go on filling right away.
func (s *server) tick(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}
	now := nowMs()
	s.mu.Lock()
	kept := s.st.upcoming(now)
	s.st.Schedule = kept
	end := now
	if len(kept) > 0 {
		end = max(end, kept[len(kept)-1].Start+kept[len(kept)-1].Duration)
	}
	cutoff := now - repeatAfter.Milliseconds()
	var history []played
	for _, p := range s.st.History {
		if p.At > cutoff {
			history = append(history, p)
		}
	}
	s.st.History = history
	files := map[string]bool{}
	for _, e := range kept {
		files[e.File] = true
	}
	s.mu.Unlock()

	if s.cleanCache(files) >= s.cfg.CacheMaxBytes || time.Duration(end-now)*time.Millisecond >= s.lookAhead {
		return false
	}
	c, ok := s.next(ctx)
	if !ok {
		return false
	}
	log.Printf("preparing %s %q", c.ID, c.Title)
	file, dur, err := s.prepare(ctx, c)
	s.mu.Lock()
	defer s.mu.Unlock()
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
	if err := saveState(s.statePath, s.st); err != nil {
		log.Printf("saving state: %v", err)
	}
	return err == nil
}

// cleanCache deletes everything in the cache dir that no entry uses and
// returns the size of what is left.
func (s *server) cleanCache(keep map[string]bool) int64 {
	des, err := os.ReadDir(s.cfg.CacheDir)
	if err != nil {
		log.Printf("reading cache dir: %v", err)
		return 0
	}
	var size int64
	for _, de := range des {
		path := filepath.Join(s.cfg.CacheDir, de.Name())
		if !keep[de.Name()] {
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
