package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"maps"
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

const youtubeFormat = "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/b[vcodec^=avc1][acodec^=mp4a][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b"

func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := stderr.String()
		if len(msg) > 1000 {
			msg = msg[len(msg)-1000:]
		}
		return nil, fmt.Errorf("%s: %w: %s", filepath.Base(name), err, strings.TrimSpace(msg))
	}
	return stdout.Bytes(), nil
}

type probe struct {
	Streams []struct {
		CodecType string `json:"codec_type"`
		CodecName string `json:"codec_name"`
		PixFmt    string `json:"pix_fmt"`
		Height    int    `json:"height"`
	} `json:"streams"`
	Format struct {
		Duration string `json:"duration"`
	} `json:"format"`
}

func (s *server) probe(ctx context.Context, headers []string, input string) (probe, error) {
	// ffprobe ships next to ffmpeg
	ffprobe := strings.TrimSuffix(s.cfg.FFmpeg, "ffmpeg") + "ffprobe"
	args := append(append([]string{"-v", "error"}, headers...),
		"-show_entries", "stream=codec_type,codec_name,pix_fmt,height:format=duration", "-of", "json", input)
	var p probe
	out, err := run(ctx, ffprobe, args...)
	if err != nil {
		return p, err
	}
	return p, json.Unmarshal(out, &p)
}

// fileName returns a cache file name for c that no other prepare uses.
func fileName(c candidate) string {
	return fmt.Sprintf("%s-%d.mp4", strings.NewReplacer(":", "-", "/", "-").Replace(c.ID), time.Now().UnixNano())
}

// prepare turns c into the browser-friendly MP4 name in the cache dir, with
// its text subtitles as name.<n>.vtt next to it, and returns its entry
// without a start.
func (s *server) prepare(ctx context.Context, c candidate, name string) (entry, error) {
	e := entry{ID: c.ID, Source: c.source(), Title: c.Title, File: name}
	var input string
	var headers []string
	dir := filepath.Join(s.cfg.CacheDir, name+".dl")
	if c.Kind == "youtube" {
		defer os.RemoveAll(dir)
		args := append(append([]string{}, s.cfg.YtDlpArgs...),
			"--no-playlist", "--no-progress", "-f", youtubeFormat, "--merge-output-format", "mp4",
			"--ffmpeg-location", s.cfg.FFmpeg, "-o", filepath.Join(dir, "video.%(ext)s"),
			"--write-info-json", "--print", "after_move:filepath", c.ref)
		out, err := run(ctx, s.cfg.YtDlp, args...)
		if err != nil {
			return e, err
		}
		input = strings.TrimSpace(string(out))
	} else {
		input = strings.TrimSuffix(s.cfg.JellyfinURL, "/") + "/Videos/" + c.ref + "/stream?static=true"
		headers = []string{"-headers", s.jellyfinAuth() + "\r\n"}
	}

	p, err := s.probe(ctx, headers, input)
	if err != nil {
		return e, err
	}
	videoArgs := []string{"-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p", "-vf", "scale=-2:'min(1080,trunc(ih/2)*2)'"}
	audioArgs := []string{"-c:a", "aac", "-b:a", "192k", "-ac", "2"}
	hasVideo, hasAudio := false, false
	for _, st := range p.Streams {
		switch {
		case st.CodecType == "video" && !hasVideo:
			hasVideo = true
			if st.CodecName == "h264" && (st.PixFmt == "yuv420p" || st.PixFmt == "yuvj420p") && st.Height <= 1080 {
				videoArgs = []string{"-c:v", "copy"}
			}
		case st.CodecType == "audio" && !hasAudio:
			hasAudio = true
			if st.CodecName == "aac" {
				audioArgs = []string{"-c:a", "copy"}
			}
		}
	}
	if !hasVideo {
		return e, fmt.Errorf("%s has no video stream", input)
	}
	part := filepath.Join(s.cfg.CacheDir, name+".part")
	args := append([]string{"-hide_banner", "-loglevel", "error", "-y"}, headers...)
	args = append(args, "-i", input, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn")
	args = append(append(args, videoArgs...), audioArgs...)
	args = append(args, "-movflags", "+faststart", "-f", "mp4", part)
	if _, err := run(ctx, s.cfg.FFmpeg, args...); err != nil {
		os.Remove(part)
		return e, err
	}
	out, err := s.probe(ctx, nil, part)
	if err != nil {
		os.Remove(part)
		return e, err
	}
	secs, err := strconv.ParseFloat(out.Format.Duration, 64)
	if err != nil || secs <= 0 {
		os.Remove(part)
		return e, fmt.Errorf("no duration for %s", part)
	}
	if err := os.Rename(part, filepath.Join(s.cfg.CacheDir, name)); err != nil {
		return e, err
	}
	e.Duration = int64(math.Round(secs * 1000))
	var it, series jellyfinItem
	if c.Kind == "youtube" {
		e.Subtitles = s.youtubeSubtitles(ctx, dir, name)
	} else {
		it, series, e.Subtitles = s.jellyfinExtras(ctx, c.ref, name)
	}
	e.Link = itemLink(c, it, series)
	return e, nil
}

type subtitle struct {
	File  string `json:"file"`
	Lang  string `json:"lang"`
	Label string `json:"label"`
	// Jellyfin stream index or yt-dlp subtitle key
	src string
}

// languageNames maps ISO 639-1 codes to the language's own name.
var languageNames = map[string]string{
	"en": "English", "de": "Deutsch", "fr": "Français", "es": "Español", "it": "Italiano", "nl": "Nederlands",
	"pt": "Português", "sv": "Svenska", "da": "Dansk", "no": "Norsk", "fi": "Suomi", "pl": "Polski",
	"cs": "Čeština", "tr": "Türkçe", "ru": "Русский", "ja": "日本語", "zh": "中文", "ko": "한국어",
}

// shortCodes maps the ISO 639-2 codes Jellyfin reports to ISO 639-1.
var shortCodes = map[string]string{
	"eng": "en", "ger": "de", "deu": "de", "fre": "fr", "fra": "fr", "spa": "es", "ita": "it", "dut": "nl",
	"nld": "nl", "por": "pt", "swe": "sv", "dan": "da", "nor": "no", "nob": "no", "fin": "fi", "pol": "pl",
	"cze": "cs", "ces": "cs", "tur": "tr", "rus": "ru", "jpn": "ja", "chi": "zh", "zho": "zh", "kor": "ko",
}

// language returns the ISO 639-1 code (if known) and name of a language
// code like "eng", "de" or "en-US".
func language(code string) (string, string) {
	code, _, _ = strings.Cut(strings.ToLower(code), "-")
	if short, ok := shortCodes[code]; ok {
		code = short
	}
	if code == "" || code == "und" {
		return "", "Unknown"
	}
	if name, ok := languageNames[code]; ok {
		return code, name
	}
	return code, code
}

type mediaStream struct {
	Type                 string `json:"Type"`
	Index                int    `json:"Index"`
	Language             string `json:"Language"`
	Title                string `json:"Title"`
	IsTextSubtitleStream bool   `json:"IsTextSubtitleStream"`
}

// jellyfinSubtitles names a cache file for each subtitle stream Jellyfin can
// convert to WebVTT; image ones (PGS, VobSub) cannot be.
func jellyfinSubtitles(file string, streams []mediaStream) []subtitle {
	var subs []subtitle
	for _, st := range streams {
		if st.Type != "Subtitle" || !st.IsTextSubtitleStream {
			continue
		}
		lang, label := language(st.Language)
		if title := strings.TrimSpace(st.Title); title != "" && !strings.Contains(strings.ToLower(title), strings.ToLower(label)) {
			label += " " + title
		} else if title != "" {
			label = title
		}
		subs = append(subs, subtitle{File: fmt.Sprintf("%s.%d.vtt", file, len(subs)), Lang: lang, Label: label, src: strconv.Itoa(st.Index)})
	}
	return subs
}

// itemLink returns the YouTube page of a video, the TMDB page of a movie or
// episode, else its IMDb page; it and series are the Jellyfin item and the
// episode's series.
func itemLink(c candidate, it, series jellyfinItem) string {
	if c.Kind == "youtube" {
		return "https://www.youtube.com/watch?v=" + strings.TrimPrefix(c.ID, "yt:")
	}
	if it.Type == "Episode" {
		if id := series.ProviderIDs["Tmdb"]; id != "" {
			return fmt.Sprintf("https://www.themoviedb.org/tv/%s/season/%d/episode/%d", id, it.Season, it.Episode)
		}
	} else if id := it.ProviderIDs["Tmdb"]; id != "" {
		return "https://www.themoviedb.org/movie/" + id
	}
	if id := it.ProviderIDs["Imdb"]; id != "" {
		return "https://www.imdb.com/title/" + id + "/"
	}
	return ""
}

// jellyfinExtras looks up a Jellyfin item and its series for the link and
// fetches its text subtitles; failures only cost the link or subtitles.
func (s *server) jellyfinExtras(ctx context.Context, id, file string) (it, series jellyfinItem, subs []subtitle) {
	items, err := s.jellyfinItems(ctx, "/Items", url.Values{"Ids": {id}, "Fields": {"MediaSources,ProviderIds"}})
	if err != nil || len(items) == 0 {
		log.Printf("looking up %s for subtitles and link: %v", id, err)
		return it, series, nil
	}
	it = items[0]
	if it.SeriesID != "" {
		ss, err := s.jellyfinItems(ctx, "/Items", url.Values{"Ids": {it.SeriesID}, "Fields": {"ProviderIds"}})
		if err != nil || len(ss) == 0 {
			log.Printf("looking up series %s: %v", it.SeriesID, err)
		} else {
			series = ss[0]
		}
	}
	if len(it.MediaSources) == 0 {
		return it, series, nil
	}
	src := it.MediaSources[0]
	for _, sub := range jellyfinSubtitles(file, src.MediaStreams) {
		path := "/Videos/" + id + "/" + src.ID + "/Subtitles/" + sub.src + "/Stream.vtt"
		if err := s.jellyfinDownload(ctx, path, filepath.Join(s.cfg.CacheDir, sub.File)); err != nil {
			log.Printf("subtitles %q of %s: %v", sub.Label, id, err)
			continue
		}
		subs = append(subs, sub)
	}
	return it, series, subs
}

func (s *server) jellyfinDownload(ctx context.Context, path, dst string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimSuffix(s.cfg.JellyfinURL, "/")+path, nil)
	if err != nil {
		return err
	}
	name, value, _ := strings.Cut(s.jellyfinAuth(), ": ")
	req.Header.Set(name, value)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", path, resp.Status)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

// pickYouTubeSubtitles picks for each language its manual track, else the
// auto-generated one; manual and auto are yt-dlp's subtitle keys.
func pickYouTubeSubtitles(file string, langs []string, manual, auto map[string]json.RawMessage) []subtitle {
	var subs []subtitle
	for _, l := range langs {
		lang, label := language(l)
		key := ""
		if _, ok := manual[l]; ok {
			key = l
		} else {
			// manual tracks can be regional, like en-US
			for _, k := range slices.Sorted(maps.Keys(manual)) {
				if strings.HasPrefix(k, l+"-") {
					key = k
					break
				}
			}
		}
		if _, ok := auto[l]; key == "" && ok {
			key, label = l, label+" (auto)"
		}
		if key != "" {
			subs = append(subs, subtitle{File: fmt.Sprintf("%s.%d.vtt", file, len(subs)), Lang: lang, Label: label, src: key})
		}
	}
	return subs
}

// youtubeSubtitles fetches the subtitles of the video downloaded into dir,
// one yt-dlp run per track, since YouTube often refuses auto translations.
func (s *server) youtubeSubtitles(ctx context.Context, dir, file string) []subtitle {
	if len(s.cfg.SubtitleLanguages) == 0 {
		return nil
	}
	infoFile := filepath.Join(dir, "video.info.json")
	b, err := os.ReadFile(infoFile)
	var info struct {
		Subtitles         map[string]json.RawMessage `json:"subtitles"`
		AutomaticCaptions map[string]json.RawMessage `json:"automatic_captions"`
	}
	if err == nil {
		err = json.Unmarshal(b, &info)
	}
	if err != nil {
		log.Printf("subtitles of %s: %v", file, err)
		return nil
	}
	var subs []subtitle
	for _, sub := range pickYouTubeSubtitles(file, s.cfg.SubtitleLanguages, info.Subtitles, info.AutomaticCaptions) {
		ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
		args := append(append([]string{}, s.cfg.YtDlpArgs...),
			"--load-info-json", infoFile, "--skip-download", "--no-progress", "--write-subs", "--write-auto-subs",
			"--sub-langs", regexp.QuoteMeta(sub.src), "--sub-format", "vtt/best", "--convert-subs", "vtt",
			"--ffmpeg-location", s.cfg.FFmpeg, "-o", filepath.Join(dir, "sub.%(ext)s"))
		_, err := run(ctx, s.cfg.YtDlp, args...)
		cancel()
		if err == nil {
			err = os.Rename(filepath.Join(dir, "sub."+sub.src+".vtt"), filepath.Join(s.cfg.CacheDir, sub.File))
		}
		if err != nil {
			log.Printf("subtitles %q of %s: %v", sub.Label, file, err)
			continue
		}
		subs = append(subs, sub)
	}
	return subs
}
