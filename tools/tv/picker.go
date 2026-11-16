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
	"slices"
	"strconv"
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
	s.mu.Lock()
	var channels []string
	for _, c := range s.st.Channels {
		channels = append(channels, c.URL)
	}
	s.mu.Unlock()
	// removed channels leave the picker
	for ch := range s.ytLists {
		if !slices.Contains(channels, ch) {
			delete(s.ytLists, ch)
		}
	}
	for _, ch := range channels {
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
	return balance(picks, shuffled(cands), s.cfg.YouTubeShare, s.lookAhead)
}

func shuffled(cands []candidate) []candidate {
	cands = append([]candidate{}, cands...)
	rand.Shuffle(len(cands), func(i, j int) { cands[i], cands[j] = cands[j], cands[i] })
	return cands
}

func (s *server) randomPicks(cands []candidate) []candidate {
	cands = shuffled(cands)
	n := len(cands)
	var total int64
	for i, c := range cands {
		total += c.Duration
		if time.Duration(total)*time.Second >= s.lookAhead {
			n = i + 1
			break
		}
	}
	return balance(cands[:n], cands, s.cfg.YouTubeShare, s.lookAhead)
}

// balance makes YouTube at least share of the airtime of picks, an ordered
// batch. Jellyfin items stay in order while their airtime fits the rest of
// the look-ahead, (1-share)*lookAhead, later ones are dropped. The first one
// always stays, so a movie longer than that still airs (at most one per batch
// then); the batch grows past the look-ahead until YouTube matches it.
// YouTube videos of extra are appended in order, preferring another channel
// than the item before, until YouTube has its share and the batch covers the
// look-ahead. Without any YouTube candidate picks stay as they are.
func balance(picks, extra []candidate, share float64, lookAhead time.Duration) []candidate {
	if share <= 0 {
		return picks
	}
	used := map[string]bool{}
	hasYouTube := false
	for _, c := range picks {
		used[c.ID] = true
		hasYouTube = hasYouTube || c.Kind == "youtube"
	}
	var spare []candidate
	for _, c := range extra {
		if c.Kind == "youtube" && !used[c.ID] {
			spare = append(spare, c)
			used[c.ID] = true
		}
	}
	if !hasYouTube && len(spare) == 0 {
		return picks
	}
	look := int64(lookAhead / time.Second)
	jfBudget := (1 - share) * float64(look)
	var out []candidate
	var yt, jf int64
	for _, c := range picks {
		switch {
		case c.Kind == "youtube":
			yt += c.Duration
		case share < 1 && (jf == 0 || float64(jf+c.Duration) <= jfBudget):
			jf += c.Duration
		default:
			continue
		}
		out = append(out, c)
	}
	for len(spare) > 0 && (float64(yt) < share*float64(yt+jf) || yt+jf < look) {
		i := 0
		if len(out) > 0 {
			last := out[len(out)-1].Group
			if j := slices.IndexFunc(spare, func(c candidate) bool { return c.Group != last }); j >= 0 {
				i = j
			}
		}
		out = append(out, spare[i])
		yt += spare[i].Duration
		spare = slices.Delete(spare, i, i+1)
	}
	return out
}

func (s *server) askLLM(ctx context.Context, cands []candidate, history []string) ([]candidate, error) {
	system, prompt := s.llmPrompt(cands, history)
	content, err := s.chat(ctx, system, prompt)
	if err != nil {
		return nil, err
	}
	return validPicks(content, cands)
}

func (s *server) llmPrompt(cands []candidate, history []string) (system, prompt string) {
	var list strings.Builder
	for _, c := range cands {
		fmt.Fprintf(&list, "%s | %s | %d min | %s | %s\n", c.ID, c.Kind, (c.Duration+30)/60, c.Group, c.Title)
	}
	prompt = fmt.Sprintf("Recently played, oldest first:\n%s\n\nCandidates (id | kind | length | series or channel | title):\n%s",
		strings.Join(history, "\n"), list.String())
	share := ""
	if s.cfg.YouTubeShare > 0 {
		share = fmt.Sprintf("YouTube videos should fill about %.0f%% of the airtime. ", s.cfg.YouTubeShare*100)
	}
	system = fmt.Sprintf("You program a 24/7 TV channel. From the candidates, pick an ordered list for the next %s "+
		"that makes a varied, enjoyable channel: mix movies, series episodes and YouTube videos, avoid the same "+
		"series or channel back to back, and avoid what was played recently. %s"+
		`Answer only with JSON: {"ids": ["<candidate id>", ...]}`, s.lookAhead, share)
	return system, prompt
}

// chat sends a system and a user message to the LLM and returns its answer.
func (s *server) chat(ctx context.Context, system, prompt string) (string, error) {
	if s.cfg.LLMURL == "" {
		return "", errors.New("no llm_url configured")
	}
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
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.llmKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
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
		return "", fmt.Errorf("%s", resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", err
	}
	if len(out.Choices) == 0 {
		return "", errors.New("no choices in the answer")
	}
	return out.Choices[0].Message.Content, nil
}

// answerIDs returns the ids of an answer like {"ids": [...]}.
func answerIDs(content string) ([]string, error) {
	var answer struct {
		IDs []string `json:"ids"`
	}
	err := answerJSON(content, &answer)
	return answer.IDs, err
}

// answerJSON decodes the JSON object of an LLM answer into v.
func answerJSON(content string, v any) error {
	// models like to wrap JSON in prose or code fences
	start, end := strings.Index(content, "{"), strings.LastIndex(content, "}")
	if start < 0 || end < start {
		return fmt.Errorf("no JSON object in %q", content)
	}
	return json.Unmarshal([]byte(content[start:end+1]), v)
}

// validPicks keeps the known, distinct ids of an answer in its order.
func validPicks(content string, cands []candidate) ([]candidate, error) {
	ids, err := answerIDs(content)
	if err != nil {
		return nil, err
	}
	byID := map[string]candidate{}
	for _, c := range cands {
		byID[c.ID] = c
	}
	var picks []candidate
	for _, id := range ids {
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
	ID           string            `json:"Id"`
	Name         string            `json:"Name"`
	RunTimeTicks int64             `json:"RunTimeTicks"`
	SeriesName   string            `json:"SeriesName"`
	SeriesID     string            `json:"SeriesId"`
	Season       int               `json:"ParentIndexNumber"`
	Episode      int               `json:"IndexNumber"`
	LocationType string            `json:"LocationType"`
	Type         string            `json:"Type"`
	MediaType    string            `json:"MediaType"`
	ProviderIDs  map[string]string `json:"ProviderIds"`
	MediaStreams []mediaStream     `json:"MediaStreams"`
	MediaSources []struct {
		ID           string        `json:"Id"`
		MediaStreams []mediaStream `json:"MediaStreams"`
	} `json:"MediaSources"`
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
	movies, err := s.jellyfinItems(ctx, "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Movie"}, "Fields": {"MediaStreams"}})
	if err != nil {
		return nil, err
	}
	rand.Shuffle(len(movies), func(i, j int) { movies[i], movies[j] = movies[j], movies[i] })
	var cands []candidate
	for _, m := range movies[:min(len(movies), 120)] {
		if m.RunTimeTicks > 0 && understandable(m.MediaStreams, s.cfg.RequiredLanguages) {
			cands = append(cands, candidate{ID: "jf:" + m.ID, Kind: "movie", Title: m.Name, Duration: ticksToSeconds(m.RunTimeTicks), ref: m.ID})
		}
	}
	series, err := s.jellyfinItems(ctx, "/Items", url.Values{"Recursive": {"true"}, "IncludeItemTypes": {"Series"}})
	if err != nil {
		return cands, err
	}
	rand.Shuffle(len(series), func(i, j int) { series[i], series[j] = series[j], series[i] })
	for _, sr := range series[:min(len(series), 40)] {
		episodes, err := s.jellyfinItems(ctx, "/Shows/"+sr.ID+"/Episodes", url.Values{"Fields": {"MediaStreams"}})
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
		if !understandable(e.MediaStreams, s.cfg.RequiredLanguages) {
			continue
		}
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
	args := append(append([]string{}, s.cfg.YtDlpArgs...), "--flat-playlist", "--playlist-end", strconv.Itoa(s.cfg.YouTubeVideosPerChannel), "-J", channel)
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
