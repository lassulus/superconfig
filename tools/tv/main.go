package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed static
var staticFiles embed.FS

type config struct {
	Listen            string   `json:"listen"`
	StateDir          string   `json:"state_dir"`
	CacheDir          string   `json:"cache_dir"`
	CacheMaxBytes     int64    `json:"cache_max_bytes"`
	SecretFile        string   `json:"secret_file"`
	JellyfinURL       string   `json:"jellyfin_url"`
	JellyfinKeyFile   string   `json:"jellyfin_key_file"`
	YtDlp             string   `json:"yt_dlp"`
	YtDlpArgs         []string `json:"yt_dlp_args"`
	FFmpeg            string   `json:"ffmpeg"`
	LLMURL            string   `json:"llm_url"`
	LLMModel          string   `json:"llm_model"`
	LLMKeyFile        string   `json:"llm_key_file"`
	LookAhead         string   `json:"look_ahead"`
	AdminKeyFile      string   `json:"admin_key_file"`
	JellyseerrURL     string   `json:"jellyseerr_url"`
	JellyseerrKeyFile string   `json:"jellyseerr_key_file"`
	RequestsPerDay    int      `json:"requests_per_day"`
	SubtitleLanguages []string `json:"subtitle_languages"`
	// SponsorBlock categories yt-dlp cuts out of YouTube videos
	SponsorblockCategories []string `json:"sponsorblock_categories"`
	// newest videos per channel the picker may choose from
	YouTubeVideosPerChannel int `json:"youtube_videos_per_channel"`
	// fraction of the picked airtime that is YouTube, 0 leaves it to the LLM
	YouTubeShare float64 `json:"youtube_share"`
}

type server struct {
	cfg           config
	secret        string
	jellyfinKey   string
	llmKey        string
	jellyseerrKey string
	adminKey      string
	lookAhead     time.Duration
	statePath     string

	mu sync.Mutex
	st state
	// queued and play-now items until they are in the schedule
	requests []*request
	// file of the picker's running prepare
	preparing string
	wake      chan struct{}

	// only used by the scheduler goroutine
	queue   []candidate
	ytLists map[string]ytList
}

func main() {
	configPath := flag.String("config", "", "JSON config file")
	flag.Parse()
	s, err := newServer(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go s.run(ctx)
	go s.serveRequests(ctx)
	go s.requestMoviesDaily(ctx)
	srv := &http.Server{Addr: s.cfg.Listen, Handler: s.handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		srv.Close()
	}()
	log.Printf("listening on %s", s.cfg.Listen)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func readSecret(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	b, err := os.ReadFile(path)
	return strings.TrimSpace(string(b)), err
}

func newServer(configPath string) (*server, error) {
	b, err := os.ReadFile(configPath)
	if err != nil {
		return nil, err
	}
	cfg := config{YtDlp: "yt-dlp", FFmpeg: "ffmpeg", LookAhead: "3h", CacheMaxBytes: 20 << 30}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, err
	}
	if cfg.Listen == "" || cfg.StateDir == "" || cfg.CacheDir == "" {
		return nil, errors.New("config: listen, state_dir and cache_dir are required")
	}
	if cfg.YouTubeShare < 0 || cfg.YouTubeShare > 1 {
		return nil, errors.New("config: youtube_share must be between 0 and 1")
	}
	if cfg.YouTubeVideosPerChannel <= 0 {
		cfg.YouTubeVideosPerChannel = 15
	}
	s := &server{cfg: cfg, statePath: filepath.Join(cfg.StateDir, "state.json"), ytLists: map[string]ytList{}, wake: make(chan struct{}, 1)}
	if s.lookAhead, err = time.ParseDuration(cfg.LookAhead); err != nil {
		return nil, err
	}
	if s.secret, err = readSecret(cfg.SecretFile); err != nil {
		return nil, err
	}
	if s.secret == "" || strings.Contains(s.secret, "/") {
		return nil, errors.New("config: secret_file must contain a non-empty secret without slashes")
	}
	if s.jellyfinKey, err = readSecret(cfg.JellyfinKeyFile); err != nil {
		return nil, err
	}
	if s.llmKey, err = readSecret(cfg.LLMKeyFile); err != nil {
		return nil, err
	}
	if s.adminKey, err = readSecret(cfg.AdminKeyFile); err != nil {
		return nil, err
	}
	if s.jellyseerrKey, err = readSecret(cfg.JellyseerrKeyFile); err != nil {
		return nil, err
	}
	for _, dir := range []string{cfg.StateDir, cfg.CacheDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	if s.st, err = loadState(s.statePath); err != nil {
		return nil, err
	}
	// entries whose file is gone (cache wiped) cannot play
	s.st.dropMissing(nowMs(), func(file string) bool {
		_, err := os.Stat(filepath.Join(cfg.CacheDir, file))
		return err == nil
	})
	if err := saveState(s.statePath, s.st); err != nil {
		return nil, err
	}
	return s, nil
}

func nowMs() int64 { return time.Now().UnixMilli() }

// handler serves everything under /<secret>/:
//
//	GET  api/time      server clock, unix ms
//	GET  api/schedule  {"entries": [playing, upcoming...], "pending": [requests]}
//	POST api/queue     {"url"}: queue a YouTube video or Jellyfin item; 409 with
//	                   its "start" if it is already scheduled or requested
//	GET  media/<file>  prepared videos and subtitles
//	GET  api/channels  {"channels": [...], "suggestions": [...]}, each
//	                   {"url", "title", "at"}: the YouTube channels the picker
//	                   lists and the suggested ones
//	POST api/channels/suggest {"url"}: suggest a channel URL or @handle; yt-dlp
//	                   has to list it; 409 if it is a channel or suggested
//	                   already, 429 with 20 suggestions waiting
//
// Admin, with "Authorization: Bearer <admin key>" (401 without):
//
//	POST api/skip      {}: skip the playing entry; {"url"}: play it now, an
//	                   already scheduled entry of it moves to now
//	POST api/schedule/delete  {"start", "id"}: remove an upcoming entry, the
//	                   rest moves up
//	POST api/schedule/move    {"start", "id", "after": {"start", "id"} | null}:
//	                   put an upcoming entry right after another one, or after
//	                   the playing one for null
//	POST api/schedule/insert  {"url", "after": {"start", "id"} | null}: like
//	                   api/queue, but goes after that entry once prepared (after
//	                   the playing one if it is gone by then)
//	POST api/channels/add     {"url"}: add a channel (checked like suggest),
//	                   dropping its suggestion; 409 if it is one already
//	POST api/channels/remove  {"url"}: remove a channel; its videos leave the
//	                   picker with the next pick
//	POST api/channels/approve {"url"}: make a suggestion a channel
//	POST api/channels/reject  {"url"}: drop a suggestion
//
// Edits address entries by start (unix ms) and id; 409 if no upcoming entry
// matches (the schedule moved) or it is the playing one. They answer 200 with
// the new api/schedule. Channel changes answer 200 with the new api/channels,
// 404 if the channel or suggestion to remove, approve or reject is not there.
func (s *server) handler() http.Handler {
	static, _ := fs.Sub(staticFiles, "static")
	files := http.FileServerFS(static)
	prefix := "/" + s.secret + "/"
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rest, ok := strings.CutPrefix(r.URL.Path, prefix)
		if !ok {
			http.NotFound(w, r)
			return
		}
		switch {
		case rest == "api/time":
			t := time.Now()
			w.Header().Set("Cache-Control", "no-store")
			w.Write(strconv.AppendFloat(nil, float64(t.UnixNano())/1e6, 'f', 3, 64))
		case rest == "api/schedule":
			s.mu.Lock()
			out := s.schedule(nowMs())
			s.mu.Unlock()
			writeJSON(w, http.StatusOK, out)
		case rest == "api/queue":
			s.handleRequest(w, r, queued)
		case rest == "api/channels":
			s.mu.Lock()
			out := s.channels()
			s.mu.Unlock()
			writeJSON(w, http.StatusOK, out)
		case rest == "api/channels/suggest":
			s.handleChannel(w, r, "suggest")
		case rest == "api/skip" || strings.HasPrefix(rest, "api/schedule/") || strings.HasPrefix(rest, "api/channels/"):
			if !s.isAdmin(r) {
				writeError(w, http.StatusUnauthorized, "admin key required")
				return
			}
			switch rest {
			case "api/skip":
				s.handleRequest(w, r, playNow)
			case "api/schedule/insert":
				s.handleRequest(w, r, inserted)
			case "api/schedule/move":
				s.handleEdit(w, r, true)
			case "api/schedule/delete":
				s.handleEdit(w, r, false)
			case "api/channels/add", "api/channels/remove", "api/channels/approve", "api/channels/reject":
				s.handleChannel(w, r, strings.TrimPrefix(rest, "api/channels/"))
			default:
				http.NotFound(w, r)
			}
		case strings.HasPrefix(rest, "media/"):
			name := strings.TrimPrefix(rest, "media/")
			if name == "" || name != filepath.Base(name) || strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".mp4") && !strings.HasSuffix(name, ".vtt") {
				http.NotFound(w, r)
				return
			}
			f, err := os.Open(filepath.Join(s.cfg.CacheDir, name))
			if err != nil {
				http.NotFound(w, r)
				return
			}
			defer f.Close()
			fi, err := f.Stat()
			if err != nil {
				http.NotFound(w, r)
				return
			}
			// Go's built-in MIME table has no .vtt; browsers ignore tracks of other types
			if strings.HasSuffix(name, ".vtt") {
				w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
			}
			http.ServeContent(w, r, name, fi.ModTime(), f)
		default:
			r2 := r.Clone(r.Context())
			r2.URL.Path = "/" + rest
			files.ServeHTTP(w, r2)
		}
	})
}
