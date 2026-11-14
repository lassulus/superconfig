package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
)

// movie is a Jellyseerr search result.
type movie struct {
	ID          int     `json:"id"` // TMDB id
	MediaType   string  `json:"mediaType"`
	Title       string  `json:"title"`
	ReleaseDate string  `json:"releaseDate"`
	Overview    string  `json:"overview"`
	VoteAverage float64 `json:"voteAverage"`
	// set once anyone requested the movie
	MediaInfo *struct {
		Status int `json:"status"`
	} `json:"mediaInfo"`
}

func (s *server) requestMoviesDaily(ctx context.Context) {
	if s.cfg.JellyseerrURL == "" || s.cfg.RequestsPerDay <= 0 {
		return
	}
	for {
		s.requestMovies(ctx)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Hour):
		}
	}
}

// requestMovies requests up to requests_per_day new movies the LLM picks
// from Jellyseerr's suggestions, at most once a day.
func (s *server) requestMovies(ctx context.Context) {
	now := nowMs()
	s.mu.Lock()
	due := now-s.st.MoviesRequestedAt >= (24 * time.Hour).Milliseconds()
	if due {
		s.st.MoviesRequestedAt = now
		s.save()
	}
	history := append([]played{}, s.st.History...)
	requested := map[int]bool{}
	for _, id := range s.st.RequestedMovies {
		requested[id] = true
	}
	s.mu.Unlock()
	if !due {
		return
	}
	cands, err := s.movieCandidates(ctx, history, requested)
	if err != nil {
		log.Printf("movie requests: %v", err)
		return
	}
	if len(cands) == 0 {
		log.Printf("movie requests: no candidates")
		return
	}
	var titles []string
	for _, p := range history[max(0, len(history)-30):] {
		titles = append(titles, p.Title)
	}
	picks, err := s.askMovies(ctx, cands, titles)
	if err != nil {
		log.Printf("llm movie pick failed, requesting nothing today: %v", err)
		return
	}
	for _, m := range picks {
		if err := s.jellyseerr(ctx, "POST", "/api/v1/request", map[string]any{"mediaType": "movie", "mediaId": m.ID}, nil); err != nil {
			log.Printf("requesting %q (TMDB %d): %v", m.Title, m.ID, err)
			continue
		}
		log.Printf("requested %q (TMDB %d) through Jellyseerr", m.Title, m.ID)
		s.mu.Lock()
		s.st.RequestedMovies = append(s.st.RequestedMovies, m.ID)
		s.save()
		s.mu.Unlock()
	}
}

// movieCandidates returns Jellyseerr's recommendations for the movies played
// last and its trending movies, without the ones anyone requested already or
// Jellyfin has.
func (s *server) movieCandidates(ctx context.Context, history []played, requested map[int]bool) ([]movie, error) {
	items, err := s.jellyfinItems(ctx, "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Movie"}, "Fields": {"ProviderIds"}})
	if err != nil {
		return nil, err
	}
	tmdbOf := map[string]int{}
	have := map[int]bool{}
	for _, it := range items {
		if id, err := strconv.Atoi(it.ProviderIDs["Tmdb"]); err == nil {
			tmdbOf["jf:"+it.ID] = id
			have[id] = true
		}
	}
	var paths []string
	var seeds []int
	for i := len(history) - 1; i >= 0 && len(seeds) < 5; i-- {
		if id, ok := tmdbOf[history[i].ID]; ok && !slices.Contains(seeds, id) {
			seeds = append(seeds, id)
			paths = append(paths, fmt.Sprintf("/api/v1/movie/%d/recommendations?page=1", id))
		}
	}
	paths = append(paths, "/api/v1/discover/trending?page=1")
	seen := map[int]bool{}
	var cands []movie
	for _, path := range paths {
		var out struct {
			Results []movie `json:"results"`
		}
		if err := s.jellyseerr(ctx, "GET", path, nil, &out); err != nil {
			log.Printf("jellyseerr: %v", err)
			continue
		}
		today := time.Now().Format("2006-01-02")
		for _, m := range out.Results {
			// unreleased movies (trending lists many) cannot be downloaded yet
			released := m.ReleaseDate != "" && m.ReleaseDate <= today
			if m.MediaType == "movie" && released && m.MediaInfo == nil && !have[m.ID] && !requested[m.ID] && !seen[m.ID] {
				seen[m.ID] = true
				cands = append(cands, m)
			}
		}
	}
	return cands, nil
}

// askMovies lets the LLM pick at most requests_per_day of cands.
func (s *server) askMovies(ctx context.Context, cands []movie, history []string) ([]movie, error) {
	var list strings.Builder
	byID := map[string]movie{}
	for _, m := range cands {
		id := fmt.Sprintf("tmdb:%d", m.ID)
		byID[id] = m
		overview := strings.Join(strings.Fields(m.Overview), " ")
		if r := []rune(overview); len(r) > 200 {
			overview = string(r[:200]) + "…"
		}
		fmt.Fprintf(&list, "%s | %s | %s | %.1f | %s\n", id, m.Title, m.ReleaseDate[:min(4, len(m.ReleaseDate))], m.VoteAverage, overview)
	}
	n := s.cfg.RequestsPerDay
	prompt := fmt.Sprintf("Recently played, oldest first:\n%s\n\nCandidates (id | title | year | rating | overview):\n%s",
		strings.Join(history, "\n"), list.String())
	system := fmt.Sprintf("You program a 24/7 TV channel and may add up to %d new movies to its library. "+
		"From the candidates, pick the ones that fit the channel and what it played recently, or fewer if nothing fits. "+
		`Answer only with JSON: {"ids": ["<candidate id>", ...]}`, n)
	content, err := s.chat(ctx, system, prompt)
	if err != nil {
		return nil, err
	}
	ids, err := answerIDs(content)
	if err != nil {
		return nil, err
	}
	var picks []movie
	for _, id := range ids {
		if m, ok := byID[id]; ok && len(picks) < n {
			picks = append(picks, m)
			delete(byID, id)
		}
	}
	return picks, nil
}

func (s *server) jellyseerr(ctx context.Context, method, path string, in, out any) error {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimSuffix(s.cfg.JellyseerrURL, "/")+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("X-Api-Key", s.jellyseerrKey)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s %s: %s", method, path, resp.Status)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
