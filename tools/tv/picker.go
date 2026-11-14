package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type candidate struct {
	ID       string // "jf:<item id>" or "yt:<video id>"
	Kind     string // movie, episode or youtube
	Title    string
	Group    string // series or channel
	Duration int64  // seconds
	Series   string // Jellyfin series id of an episode
	ref      string // Jellyfin item id or video URL
}

func (c candidate) source() string {
	if c.Kind == "youtube" {
		return "youtube"
	}
	return "jellyfin"
}

type ytList struct {
	fetched time.Time
	videos  []candidate
}

// next returns the next item to prepare, asking the picker when the queue
// of its last answer is used up.
func (s *server) next(ctx context.Context) (candidate, bool) {
	if len(s.queue) == 0 {
		s.queue = s.pick(ctx)
		if len(s.queue) == 0 {
			return candidate{}, false
		}
	}
	c := s.queue[0]
	s.queue = s.queue[1:]
	return c, true
}

func (s *server) pick(ctx context.Context) []candidate {
	var all []candidate
	if s.cfg.JellyfinURL != "" {
		cands, err := s.jellyfinCandidates(ctx)
		if err != nil {
			log.Printf("jellyfin: %v", err)
		}
		all = append(all, cands...)
	}
	for _, ch := range s.cfg.YouTubeChannels {
		l, ok := s.ytLists[ch]
		if !ok || time.Since(l.fetched) > 6*time.Hour {
			videos, err := s.youtubeCandidates(ctx, ch)
			if err != nil {
				log.Printf("listing %s: %v", ch, err)
			} else {
				l = ytList{fetched: time.Now(), videos: videos}
				s.ytLists[ch] = l
			}
		}
		all = append(all, l.videos...)
	}
	s.mu.Lock()
	recent := map[string]bool{}
	var history []string
	for i, p := range s.st.History {
		recent[p.ID] = true
		if i >= len(s.st.History)-30 {
			history = append(history, p.Title)
		}
	}
	s.mu.Unlock()
	var fresh []candidate
	for _, c := range all {
		if !recent[c.ID] {
			fresh = append(fresh, c)
		}
	}
	// a small library may run out of unplayed items; repeats beat silence
	if len(fresh) == 0 {
		fresh = all
	}
	if len(fresh) == 0 {
		log.Printf("no candidates")
		return nil
	}
	return s.choose(ctx, fresh, history)
}

func (s *server) choose(ctx context.Context, cands []candidate, history []string) []candidate {
	picks, err := s.askLLM(ctx, cands, history)
	if err != nil {
		log.Printf("llm pick failed, picking at random: %v", err)
		return s.randomPicks(cands)
	}
	return picks
}

func (s *server) randomPicks(cands []candidate) []candidate {
	cands = append([]candidate{}, cands...)
	rand.Shuffle(len(cands), func(i, j int) { cands[i], cands[j] = cands[j], cands[i] })
	var total int64
	for i, c := range cands {
		total += c.Duration
		if time.Duration(total)*time.Second >= s.lookAhead {
			return cands[:i+1]
		}
	}
	return cands
}

func (s *server) askLLM(ctx context.Context, cands []candidate, history []string) ([]candidate, error) {
	if s.cfg.LLMURL == "" {
		return nil, errors.New("no llm_url configured")
	}
	var list strings.Builder
	for _, c := range cands {
		fmt.Fprintf(&list, "%s | %s | %d min | %s | %s\n", c.ID, c.Kind, (c.Duration+30)/60, c.Group, c.Title)
	}
	prompt := fmt.Sprintf("Recently played, oldest first:\n%s\n\nCandidates (id | kind | length | series or channel | title):\n%s",
		strings.Join(history, "\n"), list.String())
	system := fmt.Sprintf("You program a 24/7 TV channel. From the candidates, pick an ordered list for the next %s "+
		"that makes a varied, enjoyable channel: mix movies, series episodes and YouTube videos, avoid the same "+
		"series or channel back to back, and avoid what was played recently. "+
		`Answer only with JSON: {"ids": ["<candidate id>", ...]}`, s.lookAhead)
	body, _ := json.Marshal(map[string]any{
		"model": s.cfg.LLMModel,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": prompt},
		},
	})
	ctx, cancel := context.WithTimeout(ctx, 3*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "POST", strings.TrimSuffix(s.cfg.LLMURL, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.llmKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s", resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	if len(out.Choices) == 0 {
		return nil, errors.New("no choices in the answer")
	}
	return validPicks(out.Choices[0].Message.Content, cands)
}

// validPicks keeps the known, distinct ids of an answer in its order.
func validPicks(content string, cands []candidate) ([]candidate, error) {
	// models like to wrap JSON in prose or code fences
	start, end := strings.Index(content, "{"), strings.LastIndex(content, "}")
	if start < 0 || end < start {
		return nil, fmt.Errorf("no JSON object in %q", content)
	}
	var answer struct {
		IDs []string `json:"ids"`
	}
	if err := json.Unmarshal([]byte(content[start:end+1]), &answer); err != nil {
		return nil, err
	}
	byID := map[string]candidate{}
	for _, c := range cands {
		byID[c.ID] = c
	}
	var picks []candidate
	for _, id := range answer.IDs {
		if c, ok := byID[id]; ok {
			picks = append(picks, c)
			delete(byID, id)
		}
	}
	if len(picks) == 0 {
		return nil, fmt.Errorf("no known ids in %q", content)
	}
	return picks, nil
}

func (s *server) jellyfinAuth() string {
	return fmt.Sprintf(`Authorization: MediaBrowser Token="%s"`, s.jellyfinKey)
}

type jellyfinItem struct {
	ID           string `json:"Id"`
	Name         string `json:"Name"`
	RunTimeTicks int64  `json:"RunTimeTicks"`
	SeriesName   string `json:"SeriesName"`
	Season       int    `json:"ParentIndexNumber"`
	Episode      int    `json:"IndexNumber"`
	LocationType string `json:"LocationType"`
}

func (s *server) jellyfinItems(ctx context.Context, path string, query url.Values) ([]jellyfinItem, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimSuffix(s.cfg.JellyfinURL, "/")+path+"?"+query.Encode(), nil)
	if err != nil {
		return nil, err
	}
	name, value, _ := strings.Cut(s.jellyfinAuth(), ": ")
	req.Header.Set(name, value)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", path, resp.Status)
	}
	var out struct{ Items []jellyfinItem }
	return out.Items, json.NewDecoder(resp.Body).Decode(&out)
}

// jellyfinCandidates returns a random sample of movies and, for a random
// sample of series, the episode after the last one this channel played.
func (s *server) jellyfinCandidates(ctx context.Context) ([]candidate, error) {
	ticksToSeconds := func(t int64) int64 { return t / 10_000_000 }
	movies, err := s.jellyfinItems(ctx, "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Movie"}})
	if err != nil {
		return nil, err
	}
	rand.Shuffle(len(movies), func(i, j int) { movies[i], movies[j] = movies[j], movies[i] })
	var cands []candidate
	for _, m := range movies[:min(len(movies), 120)] {
		if m.RunTimeTicks > 0 {
			cands = append(cands, candidate{ID: "jf:" + m.ID, Kind: "movie", Title: m.Name, Duration: ticksToSeconds(m.RunTimeTicks), ref: m.ID})
		}
	}
	series, err := s.jellyfinItems(ctx, "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Series"}})
	if err != nil {
		return cands, err
	}
	rand.Shuffle(len(series), func(i, j int) { series[i], series[j] = series[j], series[i] })
	for _, sr := range series[:min(len(series), 40)] {
		episodes, err := s.jellyfinItems(ctx, "/Shows/"+sr.ID+"/Episodes", url.Values{})
		if err != nil {
			log.Printf("jellyfin: %v", err)
			continue
		}
		var present []jellyfinItem
		for _, e := range episodes {
			if e.LocationType != "Virtual" && e.RunTimeTicks > 0 {
				present = append(present, e)
			}
		}
		if len(present) == 0 {
			continue
		}
		s.mu.Lock()
		last := s.st.Series[sr.ID]
		s.mu.Unlock()
		next := 0
		for i, e := range present {
			if e.ID == last {
				next = (i + 1) % len(present)
			}
		}
		e := present[next]
		cands = append(cands, candidate{
			ID:       "jf:" + e.ID,
			Kind:     "episode",
			Title:    fmt.Sprintf("%s S%02dE%02d %s", sr.Name, e.Season, e.Episode, e.Name),
			Group:    sr.Name,
			Duration: ticksToSeconds(e.RunTimeTicks),
			Series:   sr.ID,
			ref:      e.ID,
		})
	}
	return cands, nil
}

func (s *server) youtubeCandidates(ctx context.Context, channel string) ([]candidate, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	args := append(append([]string{}, s.cfg.YtDlpArgs...), "--flat-playlist", "--playlist-end", "15", "-J", channel)
	out, err := run(ctx, s.cfg.YtDlp, args...)
	if err != nil {
		return nil, err
	}
	var list struct {
		Channel string
		Title   string
		Entries []struct {
			ID       string
			Title    string
			Duration float64
		}
	}
	if err := json.Unmarshal(out, &list); err != nil {
		return nil, err
	}
	group := list.Channel
	if group == "" {
		group = list.Title
	}
	var cands []candidate
	for _, e := range list.Entries {
		// upcoming premieres and live streams have no duration
		if e.Duration > 0 {
			cands = append(cands, candidate{ID: "yt:" + e.ID, Kind: "youtube", Title: e.Title, Group: group,
				Duration: int64(e.Duration), ref: "https://www.youtube.com/watch?v=" + e.ID})
		}
	}
	return cands, nil
}
