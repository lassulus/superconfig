package main

import (
	"context"
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

// pending suggestions the public may add before the admin goes through them
const maxSuggestions = 20

// rejected channel URLs remembered, the oldest are forgotten
const maxRejected = 200

// channel is a YouTube channel the picker lists, or a suggested one.
type channel struct {
	URL   string `json:"url"` // https://www.youtube.com/@<handle>/videos
	Title string `json:"title"`
	At    int64  `json:"at"`           // unix ms it was added or suggested
	By    string `json:"by,omitempty"` // "llm" if the weekly LLM suggested it
}

var channelHandle = regexp.MustCompile(`^[\pL\pN._-]{3,30}$`)

var playlistID = regexp.MustCompile(`^[A-Za-z0-9_-]{10,64}$`)

var errChannelURL = errors.New("not a YouTube channel URL, @handle or playlist URL")

// isPlaylist tells a playlist URL from channelURL apart from a channel.
func isPlaylist(u string) bool {
	return strings.HasPrefix(u, "https://www.youtube.com/playlist?list=")
}

// channelURL turns "@handle", "/@handle" or a youtube.com/@handle URL with
// any tab into https://www.youtube.com/@<handle>/videos, and a playlist URL
// into https://www.youtube.com/playlist?list=<id>.
func channelURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	path := "/" + strings.TrimPrefix(raw, "/")
	if !strings.HasPrefix(path, "/@") {
		if !strings.Contains(raw, "://") {
			raw = "https://" + raw
		}
		u, err := url.Parse(raw)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") {
			return "", errChannelURL
		}
		switch strings.ToLower(u.Hostname()) {
		case "youtube.com", "www.youtube.com", "m.youtube.com":
		default:
			return "", errChannelURL
		}
		if id := u.Query().Get("list"); u.Path == "/playlist" && playlistID.MatchString(id) {
			return "https://www.youtube.com/playlist?list=" + id, nil
		}
		path = u.Path
	}
	handle, ok := strings.CutPrefix(path, "/@")
	if !ok {
		return "", errChannelURL
	}
	handle, _, _ = strings.Cut(handle, "/")
	if !channelHandle.MatchString(handle) {
		return "", errChannelURL
	}
	return "https://www.youtube.com/@" + handle + "/videos", nil
}

// channelTitle asks yt-dlp for the newest video of a channel URL, so only
// channels it can list get in, and returns the channel's name.
func (s *server) channelTitle(ctx context.Context, u string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	args := append(append([]string{}, s.cfg.YtDlpArgs...), "--flat-playlist", "--playlist-end", "1", "-J", u)
	out, err := run(ctx, s.cfg.YtDlp, args...)
	if err != nil {
		return "", err
	}
	var v struct{ Channel, Title string }
	if err := json.Unmarshal(out, &v); err != nil {
		return "", err
	}
	// a playlist is named by its own title, not by its uploader
	if v.Channel != "" && !isPlaylist(u) {
		return v.Channel, nil
	}
	if v.Title == "" {
		return "", errors.New("yt-dlp found no channel")
	}
	return v.Title, nil
}

// channelIndex returns the index of u in cs, or -1; handles are not case
// sensitive.
func channelIndex(cs []channel, u string) int {
	return slices.IndexFunc(cs, func(c channel) bool { return strings.EqualFold(c.URL, u) })
}

// handleOf returns the "@handle" of a channelURL.
func handleOf(u string) string {
	return strings.TrimSuffix(strings.TrimPrefix(u, "https://www.youtube.com/"), "/videos")
}

func (st *state) rejected(u string) bool {
	return slices.ContainsFunc(st.RejectedChannels, func(r string) bool { return strings.EqualFold(r, u) })
}

func (st *state) unreject(u string) {
	st.RejectedChannels = slices.DeleteFunc(st.RejectedChannels, func(r string) bool { return strings.EqualFold(r, u) })
}

// reject remembers u as rejected, keeping the newest maxRejected.
func (st *state) reject(u string) {
	st.unreject(u)
	st.RejectedChannels = append(st.RejectedChannels, u)
	if n := len(st.RejectedChannels) - maxRejected; n > 0 {
		st.RejectedChannels = slices.Delete(st.RejectedChannels, 0, n)
	}
}

// channels is the api/channels response; callers hold s.mu.
func (s *server) channels() map[string]any {
	return map[string]any{
		"channels":    append([]channel{}, s.st.Channels...),
		"suggestions": append([]channel{}, s.st.ChannelSuggestions...),
	}
}

// checkNew refuses a channel that is already listed or suggested, or a
// suggestion that was rejected or goes beyond the cap; callers hold s.mu.
func (s *server) checkNew(u, action string) (int, error) {
	if channelIndex(s.st.Channels, u) >= 0 {
		return http.StatusConflict, fmt.Errorf("%s is already a channel", u)
	}
	if action == "suggest" {
		if channelIndex(s.st.ChannelSuggestions, u) >= 0 {
			return http.StatusConflict, fmt.Errorf("%s is already suggested", u)
		}
		if s.st.rejected(u) {
			return http.StatusConflict, fmt.Errorf("%s was rejected", u)
		}
		if len(s.st.ChannelSuggestions) >= maxSuggestions {
			return http.StatusTooManyRequests, fmt.Errorf("there are %d suggestions waiting already", maxSuggestions)
		}
	}
	return 0, nil
}

// handleChannel serves api/channels/{suggest,add,remove,approve,reject}.
func (s *server) handleChannel(w http.ResponseWriter, r *http.Request, action string) {
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
	u, err := channelURL(body.URL)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	now := nowMs()
	var title string
	if action == "suggest" || action == "add" {
		s.mu.Lock()
		code, err := s.checkNew(u, action)
		s.mu.Unlock()
		if err != nil {
			writeError(w, code, err.Error())
			return
		}
		if title, err = s.channelTitle(r.Context(), u); err != nil {
			log.Printf("checking channel %s: %v", u, err)
			writeError(w, http.StatusBadRequest, fmt.Sprintf("yt-dlp cannot list %s", u))
			return
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st := &s.st
	switch action {
	case "suggest", "add":
		// the same channel may have come in during the lookup
		if code, err := s.checkNew(u, action); err != nil {
			writeError(w, code, err.Error())
			return
		}
		c := channel{URL: u, Title: title, At: now}
		if action == "suggest" {
			st.ChannelSuggestions = append(st.ChannelSuggestions, c)
		} else {
			st.ChannelSuggestions = slices.DeleteFunc(st.ChannelSuggestions, func(c channel) bool { return strings.EqualFold(c.URL, u) })
			st.unreject(u)
			st.Channels = append(st.Channels, c)
		}
	case "remove":
		i := channelIndex(st.Channels, u)
		if i < 0 {
			writeError(w, http.StatusNotFound, fmt.Sprintf("%s is not a channel", u))
			return
		}
		title = st.Channels[i].Title
		st.reject(st.Channels[i].URL)
		st.Channels = slices.Delete(st.Channels, i, i+1)
	case "approve", "reject":
		i := channelIndex(st.ChannelSuggestions, u)
		if i < 0 {
			writeError(w, http.StatusNotFound, fmt.Sprintf("%s is not suggested", u))
			return
		}
		c := st.ChannelSuggestions[i]
		title = c.Title
		st.ChannelSuggestions = slices.Delete(st.ChannelSuggestions, i, i+1)
		if action == "approve" && channelIndex(st.Channels, u) < 0 {
			c.At = now
			st.Channels = append(st.Channels, c)
		}
		if action == "reject" {
			st.reject(c.URL)
		}
	}
	s.save()
	log.Printf("channel %s: %s %q", action, u, title)
	writeJSON(w, http.StatusOK, s.channels())
}

// channelsDue tells whether the weekly LLM channel suggestions are due at
// now (unix ms): a week after the last run, at most one try a day.
func (st *state) channelsDue(now int64) bool {
	return now-st.ChannelsSuggestedAt >= (7*24*time.Hour).Milliseconds() &&
		now-st.ChannelsSuggestTriedAt >= (24*time.Hour).Milliseconds()
}

// suggestChannels adds up to channel_suggestions_per_week channels the LLM
// finds similar to the current ones to the suggestions, once a week. An LLM
// failure leaves the run due for the next day.
func (s *server) suggestChannels(ctx context.Context) {
	now := nowMs()
	s.mu.Lock()
	due := s.st.channelsDue(now)
	if due {
		s.st.ChannelsSuggestTriedAt = now
		s.save()
	}
	channels := append([]channel{}, s.st.Channels...)
	pending := append([]channel{}, s.st.ChannelSuggestions...)
	rejected := append([]string{}, s.st.RejectedChannels...)
	s.mu.Unlock()
	if !due {
		return
	}
	n := s.cfg.ChannelSuggestionsPerWeek
	system, prompt := channelPrompt(2*n, channels, pending, rejected)
	content, err := s.chat(ctx, system, prompt)
	var answer struct {
		Channels []string `json:"channels"`
	}
	if err == nil {
		err = answerJSON(content, &answer)
	}
	if err != nil {
		log.Printf("llm channel suggestions failed, trying again tomorrow: %v", err)
		return
	}
	added := 0
	for _, h := range answer.Channels {
		if added == n {
			break
		}
		if err := s.suggestChannel(ctx, h); err != nil {
			log.Printf("llm channel suggestion %q: %v", h, err)
			if errors.Is(err, errSuggestionsFull) {
				break
			}
			continue
		}
		added++
	}
	s.mu.Lock()
	s.st.ChannelsSuggestedAt = now
	s.save()
	s.mu.Unlock()
	log.Printf("llm channel suggestions: %d of %d answered handles added", added, len(answer.Channels))
}

var errSuggestionsFull = errors.New("suggestions are full")

// suggestChannel checks an LLM suggested handle like api/channels/suggest
// and adds it to the suggestions with by "llm".
func (s *server) suggestChannel(ctx context.Context, handle string) error {
	u, err := channelURL(handle)
	if err != nil {
		return err
	}
	check := func() error {
		code, err := s.checkNew(u, "suggest")
		if code == http.StatusTooManyRequests {
			return errSuggestionsFull
		}
		return err
	}
	s.mu.Lock()
	err = check()
	s.mu.Unlock()
	if err != nil {
		return err
	}
	title, err := s.channelTitle(ctx, u)
	if err != nil {
		return fmt.Errorf("yt-dlp cannot list %s: %w", u, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := check(); err != nil {
		return err
	}
	s.st.ChannelSuggestions = append(s.st.ChannelSuggestions, channel{URL: u, Title: title, At: nowMs(), By: "llm"})
	s.save()
	log.Printf("channel suggest by llm: %s %q", u, title)
	return nil
}

// channelPrompt asks for n channels like the current ones.
func channelPrompt(n int, channels, pending []channel, rejected []string) (system, prompt string) {
	var b strings.Builder
	b.WriteString("Current channels (title | handle):\n")
	for _, c := range channels {
		fmt.Fprintf(&b, "%s | %s\n", c.Title, handleOf(c.URL))
	}
	if len(pending) > 0 {
		b.WriteString("\nAlready suggested:\n")
		for _, c := range pending {
			fmt.Fprintf(&b, "%s | %s\n", c.Title, handleOf(c.URL))
		}
	}
	if len(rejected) > 0 {
		b.WriteString("\nRejected before:\n")
		for _, u := range rejected {
			fmt.Fprintf(&b, "%s\n", handleOf(u))
		}
	}
	system = fmt.Sprintf("You pick the YouTube channels of a 24/7 TV channel. Suggest %d more YouTube channels "+
		"its viewers would like, similar in topics and style to the current channels. "+
		"Prefer channels made by real people with care, with substantial videos of 10 minutes or more, "+
		"and avoid AI-generated slop, faceless content farms, compilations, reuploads and channels of mostly Shorts. "+
		"Do not suggest current, already suggested or rejected channels. "+
		"Give each channel's exact YouTube @handle, not a name or URL, and leave out channels whose handle you are not sure of. "+
		`Answer only with JSON: {"channels": ["@handle", ...]}`, n)
	return system, b.String()
}
