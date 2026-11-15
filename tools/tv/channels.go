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

// channel is a YouTube channel the picker lists, or a suggested one.
type channel struct {
	URL   string `json:"url"` // https://www.youtube.com/@<handle>/videos
	Title string `json:"title"`
	At    int64  `json:"at"` // unix ms it was added or suggested
}

var channelHandle = regexp.MustCompile(`^[\pL\pN._-]{3,30}$`)

var errChannelURL = errors.New("not a YouTube channel URL or @handle")

// channelURL turns "@handle", "/@handle" or a youtube.com/@handle URL with
// any tab into https://www.youtube.com/@<handle>/videos.
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
	if v.Channel != "" {
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

// channels is the api/channels response; callers hold s.mu.
func (s *server) channels() map[string]any {
	return map[string]any{
		"channels":    append([]channel{}, s.st.Channels...),
		"suggestions": append([]channel{}, s.st.ChannelSuggestions...),
	}
}

// checkNew refuses a channel that is already listed or suggested, or a
// suggestion beyond the cap; callers hold s.mu.
func (s *server) checkNew(u, action string) (int, error) {
	if channelIndex(s.st.Channels, u) >= 0 {
		return http.StatusConflict, fmt.Errorf("%s is already a channel", u)
	}
	if action == "suggest" {
		if channelIndex(s.st.ChannelSuggestions, u) >= 0 {
			return http.StatusConflict, fmt.Errorf("%s is already suggested", u)
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
			st.Channels = append(st.Channels, c)
		}
	case "remove":
		i := channelIndex(st.Channels, u)
		if i < 0 {
			writeError(w, http.StatusNotFound, fmt.Sprintf("%s is not a channel", u))
			return
		}
		title = st.Channels[i].Title
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
	}
	s.save()
	log.Printf("channel %s: %s %q", action, u, title)
	writeJSON(w, http.StatusOK, s.channels())
}
