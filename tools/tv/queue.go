package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"
)

const (
	maxQueued   = 10
	maxDuration = 4 * time.Hour
	keepFailed  = 5 * time.Minute
)

// request is a queued or play-now item until its prepare is done.
type request struct {
	URL      string `json:"url"`
	Title    string `json:"title"`
	Duration int64  `json:"duration"`
	PlayNow  bool   `json:"play_now,omitempty"`
	State    string `json:"state"` // waiting, preparing or failed
	Error    string `json:"error,omitempty"`
	c        candidate
	file     string
	failedAt int64
}

var (
	youtubeID  = regexp.MustCompile(`^[A-Za-z0-9_-]{11}$`)
	jellyfinID = regexp.MustCompile(`^[0-9a-fA-F]{32}$`)
)

// parseURL turns a YouTube video URL, a Jellyfin item id or a Jellyfin web
// URL into a candidate without metadata.
func parseURL(raw string) (candidate, error) {
	raw = strings.TrimSpace(raw)
	if jellyfinID.MatchString(raw) {
		return candidate{ID: "jf:" + strings.ToLower(raw), ref: strings.ToLower(raw)}, nil
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return candidate{}, errors.New("not a YouTube video or Jellyfin item URL")
	}
	var id string
	switch strings.TrimPrefix(strings.TrimPrefix(strings.ToLower(u.Hostname()), "www."), "m.") {
	case "youtu.be":
		id = strings.Trim(u.Path, "/")
	case "youtube.com":
		if u.Path == "/watch" {
			id = u.Query().Get("v")
		} else if rest, ok := strings.CutPrefix(u.Path, "/shorts/"); ok {
			id = strings.Trim(rest, "/")
		}
	default:
		// Jellyfin's web UI keeps the item id in the fragment: /web/#/details?id=...
		id = u.Query().Get("id")
		if _, q, ok := strings.Cut(u.Fragment, "?"); ok && id == "" {
			fq, _ := url.ParseQuery(q)
			id = fq.Get("id")
		}
		if !jellyfinID.MatchString(id) {
			return candidate{}, errors.New("not a YouTube video or Jellyfin item URL")
		}
		id = strings.ToLower(id)
		return candidate{ID: "jf:" + id, ref: id}, nil
	}
	if !youtubeID.MatchString(id) {
		return candidate{}, errors.New("not a YouTube video URL")
	}
	return candidate{ID: "yt:" + id, Kind: "youtube", ref: "https://www.youtube.com/watch?v=" + id}, nil
}

// lookup fills in the title, kind and duration of a parsed candidate.
func (s *server) lookup(ctx context.Context, c candidate) (candidate, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if c.Kind == "youtube" {
		args := append(append([]string{}, s.cfg.YtDlpArgs...), "--no-playlist", "-J", c.ref)
		out, err := run(ctx, s.cfg.YtDlp, args...)
		if err != nil {
			return c, err
		}
		var v struct {
			Title      string
			Duration   float64
			LiveStatus string `json:"live_status"`
		}
		if err := json.Unmarshal(out, &v); err != nil {
			return c, err
		}
		if v.Duration <= 0 || v.LiveStatus == "is_live" || v.LiveStatus == "is_upcoming" {
			return c, errors.New("live streams and premieres cannot be queued")
		}
		c.Title, c.Duration = v.Title, int64(v.Duration)
		return c, nil
	}
	if s.cfg.JellyfinURL == "" {
		return c, errors.New("no Jellyfin configured")
	}
	items, err := s.jellyfinItems(ctx, "/Items", url.Values{"Ids": {c.ref}})
	if err != nil {
		return c, err
	}
	if len(items) == 0 || items[0].MediaType != "Video" || items[0].RunTimeTicks <= 0 {
		return c, errors.New("no Jellyfin video with this id")
	}
	it := items[0]
	c.Kind, c.Title, c.Duration = "movie", it.Name, it.RunTimeTicks/10_000_000
	if it.Type == "Episode" {
		c.Kind, c.Title = "episode", fmt.Sprintf("%s S%02dE%02d %s", it.SeriesName, it.Season, it.Episode, it.Name)
	}
	return c, nil
}

func (s *server) isAdmin(r *http.Request) bool {
	key, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(key), []byte(s.adminKey)) == 1
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// pending returns copies of the requests and drops failed ones after a
// while; callers hold s.mu.
func (s *server) pending(now int64) []request {
	s.requests = slices.DeleteFunc(s.requests, func(r *request) bool {
		return r.State == "failed" && now-r.failedAt > keepFailed.Milliseconds()
	})
	out := []request{}
	for _, r := range s.requests {
		out = append(out, *r)
	}
	return out
}

// queueFull reports whether the queue takes no more items; callers hold s.mu.
func (s *server) queueFull() bool {
	n := 0
	for _, r := range s.requests {
		if !r.PlayNow && r.State != "failed" {
			n++
		}
	}
	return n >= maxQueued
}

// handleRequest serves api/queue and api/skip.
func (s *server) handleRequest(w http.ResponseWriter, r *http.Request, playNow bool) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "use POST")
		return
	}
	var body struct {
		URL string `json:"url"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "body must be JSON like {\"url\": \"...\"}")
		return
	}
	if playNow && body.URL == "" {
		s.mu.Lock()
		s.st.skip(nowMs())
		s.save()
		s.mu.Unlock()
		log.Printf("skipped")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	c, err := parseURL(body.URL)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.mu.Lock()
	full := !playNow && s.queueFull()
	s.mu.Unlock()
	if full {
		writeError(w, http.StatusTooManyRequests, fmt.Sprintf("the queue is full (%d items)", maxQueued))
		return
	}
	if c, err = s.lookup(r.Context(), c); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if d := time.Duration(c.Duration) * time.Second; d > maxDuration {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("%q is %s long, the limit is %s", c.Title, d, maxDuration))
		return
	}
	req := &request{URL: body.URL, Title: c.Title, Duration: c.Duration * 1000, PlayNow: playNow, State: "waiting", c: c, file: fileName(c)}
	s.mu.Lock()
	if !playNow && s.queueFull() {
		s.mu.Unlock()
		writeError(w, http.StatusTooManyRequests, fmt.Sprintf("the queue is full (%d items)", maxQueued))
		return
	}
	s.requests = append(s.requests, req)
	out := *req
	s.mu.Unlock()
	log.Printf("requested %s %q (play now: %t)", c.ID, c.Title, playNow)
	select {
	case s.wake <- struct{}{}:
	default:
	}
	writeJSON(w, http.StatusAccepted, out)
}

// nextRequest returns the oldest waiting request, play-now ones first;
// callers hold s.mu.
func (s *server) nextRequest() *request {
	var next *request
	for _, r := range s.requests {
		if r.State == "waiting" && (next == nil || r.PlayNow && !next.PlayNow) {
			next = r
		}
	}
	return next
}

// serveRequests prepares requests one at a time and puts them into the
// schedule as soon as they are ready.
func (s *server) serveRequests(ctx context.Context) {
	for {
		s.mu.Lock()
		r := s.nextRequest()
		if r != nil {
			r.State = "preparing"
		}
		s.mu.Unlock()
		if r == nil {
			select {
			case <-ctx.Done():
				return
			case <-s.wake:
			}
			continue
		}
		log.Printf("preparing request %s %q", r.c.ID, r.c.Title)
		e, err := s.prepare(ctx, r.c, r.file)
		s.mu.Lock()
		now := nowMs()
		if err != nil {
			log.Printf("preparing request %s failed: %v", r.c.ID, err)
			r.State, r.Error, r.failedAt = "failed", err.Error(), now
		} else {
			s.requests = slices.DeleteFunc(s.requests, func(x *request) bool { return x == r })
			if r.PlayNow {
				s.st.playAt(e, now, now+cutoverLead.Milliseconds())
			} else {
				s.st.enqueue(e, now)
			}
			s.st.History = append(s.st.History, played{ID: r.c.ID, Title: r.c.Title, At: now})
			s.save()
			log.Printf("scheduled request %s %q", r.c.ID, r.c.Title)
		}
		s.mu.Unlock()
	}
}
