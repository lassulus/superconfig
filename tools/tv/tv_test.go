package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// times renders a schedule as "id start-end" for compact comparisons.
func times(es []entry) []string {
	var out []string
	for _, e := range es {
		q := ""
		if e.Queued {
			q = " queued"
		}
		out = append(out, e.ID+" "+time.Duration(e.Start).String()+"-"+time.Duration(e.Start+e.Duration).String()+q)
	}
	return out
}

func checkSchedule(t *testing.T, name string, got []entry, want ...string) {
	t.Helper()
	if g := times(got); !reflect.DeepEqual(g, want) {
		t.Errorf("%s:\n got %q\nwant %q", name, g, want)
	}
}

func TestEnqueue(t *testing.T) {
	st := state{Schedule: []entry{
		{ID: "old", Start: 0, Duration: 100},
		{ID: "a", Start: 100, Duration: 1000},
		{ID: "b", Start: 1100, Duration: 500},
		{ID: "c", Start: 1600, Duration: 500},
	}}
	st.enqueue(entry{ID: "q1", Duration: 50}, 500)
	checkSchedule(t, "first", st.Schedule, "a 100ns-1.1µs", "q1 1.1µs-1.15µs queued", "b 1.15µs-1.65µs", "c 1.65µs-2.15µs")
	st.enqueue(entry{ID: "q2", Duration: 30}, 600)
	checkSchedule(t, "after the earlier queued one", st.Schedule, "a 100ns-1.1µs", "q1 1.1µs-1.15µs queued", "q2 1.15µs-1.18µs queued", "b 1.18µs-1.68µs", "c 1.68µs-2.18µs")
	// once q1 plays, the next one goes right after it, still before q2's followers
	st.enqueue(entry{ID: "q3", Duration: 20}, 1120)
	checkSchedule(t, "while a queued one plays", st.Schedule, "q1 1.1µs-1.15µs queued", "q2 1.15µs-1.18µs queued", "q3 1.18µs-1.2µs queued", "b 1.2µs-1.7µs", "c 1.7µs-2.2µs")

	var empty state
	empty.enqueue(entry{ID: "q", Duration: 10}, 42)
	checkSchedule(t, "empty schedule", empty.Schedule, "q 42ns-52ns queued")
}

func TestSkip(t *testing.T) {
	st := state{Schedule: []entry{
		{ID: "a", Start: 0, Duration: 1000},
		{ID: "b", Start: 1000, Duration: 1000},
		{ID: "c", Start: 2000, Duration: 500},
	}}
	st.skip(300)
	checkSchedule(t, "skip", st.Schedule, "b 300ns-1.3µs", "c 1.3µs-1.8µs")
	st.skip(300)
	checkSchedule(t, "skip right after a skip", st.Schedule, "c 300ns-800ns")
}

func TestPlayAt(t *testing.T) {
	sched := func() []entry {
		return []entry{
			{ID: "a", Start: 0, Duration: 1000},
			{ID: "b", Start: 1000, Duration: 1000, Queued: true},
			{ID: "c", Start: 2000, Duration: 500},
		}
	}
	st := state{Schedule: sched()}
	st.playAt(entry{ID: "n", Duration: 200}, 300, 305)
	checkSchedule(t, "cut", st.Schedule, "a 0s-305ns", "n 305ns-505ns", "b 505ns-1.505µs queued", "c 1.505µs-2.005µs")

	st = state{Schedule: sched()}
	st.playAt(entry{ID: "n", Duration: 200}, 998, 1003)
	checkSchedule(t, "playing entry ends before the cut", st.Schedule, "a 0s-1µs", "n 1µs-1.2µs", "b 1.2µs-2.2µs queued", "c 2.2µs-2.7µs")

	var empty state
	empty.playAt(entry{ID: "n", Duration: 10}, 100, 105)
	checkSchedule(t, "empty schedule", empty.Schedule, "n 105ns-115ns")
}

func TestDropMissing(t *testing.T) {
	sched := func() []entry {
		return []entry{
			{ID: "a", Start: 0, Duration: 1000, File: "a"},
			{ID: "b", Start: 1000, Duration: 1000, File: "b"},
			{ID: "c", Start: 2000, Duration: 500, File: "c"},
		}
	}
	without := func(missing string) func(string) bool {
		return func(f string) bool { return f != missing }
	}
	st := state{Schedule: sched()}
	st.dropMissing(500, without("b"))
	checkSchedule(t, "next one missing", st.Schedule, "a 0s-1µs", "c 1µs-1.5µs")

	st = state{Schedule: sched()}
	st.dropMissing(500, without("a"))
	checkSchedule(t, "playing one missing", st.Schedule, "b 500ns-1.5µs", "c 1.5µs-2µs")

	st = state{Schedule: sched()}
	st.dropMissing(500, without("x"))
	checkSchedule(t, "nothing missing", st.Schedule, "a 0s-1µs", "b 1µs-2µs", "c 2µs-2.5µs")
}

func TestParseURL(t *testing.T) {
	const jf = "0123456789abcdef0123456789abcdef"
	for raw, want := range map[string]string{
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ":                           "yt:dQw4w9WgXcQ",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ&pp=ygUJcmljayByb2xs&t=42s": "yt:dQw4w9WgXcQ",
		"https://m.youtube.com/watch?list=PL1&v=dQw4w9WgXcQ":                    "yt:dQw4w9WgXcQ",
		"youtube.com/watch?v=dQw4w9WgXcQ":                                       "yt:dQw4w9WgXcQ",
		"https://youtu.be/dQw4w9WgXcQ?si=abc":                                   "yt:dQw4w9WgXcQ",
		"https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share":              "yt:dQw4w9WgXcQ",
		" " + jf + "\n":     "jf:" + jf,
		strings.ToUpper(jf): "jf:" + jf,
		"https://flix.example.org/web/#/details?id=" + jf + "&serverId=ff":           "jf:" + jf,
		"https://flix.example.org/web/index.html#!/details?id=" + jf + "&context=tv": "jf:" + jf,
		"http://10.0.0.1:8096/Items/x?id=" + jf:                                      "jf:" + jf,
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx&index=3&pp=x":          "yt:dQw4w9WgXcQ",
		"https://www.youtube.com/watch?v=short":                                      "",
		"https://www.youtube.com/@kurzgesagt/videos":                                 "",
		"https://www.youtube.com/playlist?list=PL1":                                  "",
		"https://youtu.be/": "",
		"https://flix.example.org/web/#/details?id=nothex": "",
		"https://example.org/video.mp4":                    "",
		"ftp://youtu.be/dQw4w9WgXcQ":                       "",
		"":                                                 "",
		"0123456789abcdef":                                 "",
		"javascript:alert(1)":                              "",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ/../../x":                                "",
		"https://www.youtube.com/embed/dQw4w9WgXcQ":                                          "",
		"https://evil.example/watch?v=dQw4w9WgXcQ":                                           "",
		"https://flix.example.org/web/#/details?id=" + jf + "0":                              "",
		"https://www.youtube.com.evil.example/watch?v=dQw4w9WgXcQ":                           "",
		"https://www.youtube.com/shorts/":                                                    "",
		"https://youtu.be/dQw4w9WgXcQ/extra":                                                 "",
		"https://www.youtube.com/watch":                                                      "",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ#t=1":                                    "yt:dQw4w9WgXcQ",
		"https://flix.example.org/web/#/details?serverId=ff":                                 "",
		"https://flix.example.org/web/#/details?id=" + jf[:31]:                               "",
		"https://flix.example.org/web/#/details?id=" + jf + "&id=" + strings.Repeat("0", 32): "jf:" + jf,
	} {
		c, err := parseURL(raw)
		if want == "" {
			if err == nil {
				t.Errorf("%q: got %s, want an error", raw, c.ID)
			}
			continue
		}
		if err != nil || c.ID != want {
			t.Errorf("%q: got %q, %v, want %s", raw, c.ID, err, want)
		}
		if c.Kind == "youtube" && c.ref != "https://www.youtube.com/watch?v="+strings.TrimPrefix(want, "yt:") {
			t.Errorf("%q: ref %q is not the plain video URL", raw, c.ref)
		}
	}
}

func TestAdminAuth(t *testing.T) {
	for _, tc := range []struct {
		key, header string
		code        int
	}{
		{"right", "", http.StatusUnauthorized},
		{"right", "Bearer wrong", http.StatusUnauthorized},
		{"right", "Bearer righ", http.StatusUnauthorized},
		{"right", "right", http.StatusUnauthorized},
		{"right", "Basic right", http.StatusUnauthorized},
		{"", "Bearer ", http.StatusUnauthorized},
		{"right", "Bearer right", http.StatusNoContent},
	} {
		s := &server{secret: "s", adminKey: tc.key, statePath: filepath.Join(t.TempDir(), "state.json"),
			st: state{Schedule: []entry{{ID: "a", Start: nowMs() - 1000, Duration: 60_000}}}}
		req := httptest.NewRequest("POST", "/s/api/skip", nil)
		if tc.header != "" {
			req.Header.Set("Authorization", tc.header)
		}
		rec := httptest.NewRecorder()
		s.handler().ServeHTTP(rec, req)
		skipped := len(s.st.Schedule) == 0
		if rec.Code != tc.code || skipped != (tc.code == http.StatusNoContent) {
			t.Errorf("key %q, header %q: %d (skipped %t), want %d", tc.key, tc.header, rec.Code, skipped, tc.code)
		}
	}
}

func TestQueueRequests(t *testing.T) {
	runtimes := map[string]int64{"0123456789abcdef0123456789abcdef": 600, "ffffffffffffffffffffffffffffffff": 5 * 3600}
	jellyfin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("Ids")
		items := []map[string]any{}
		if secs, ok := runtimes[id]; ok {
			items = append(items, map[string]any{"Id": id, "Name": "Item " + id[:4], "Type": "Movie", "MediaType": "Video", "RunTimeTicks": secs * 10_000_000})
		}
		json.NewEncoder(w).Encode(map[string]any{"Items": items})
	}))
	defer jellyfin.Close()
	s := &server{secret: "s", cfg: config{JellyfinURL: jellyfin.URL}}
	post := func(body string) (int, map[string]any) {
		rec := httptest.NewRecorder()
		s.handler().ServeHTTP(rec, httptest.NewRequest("POST", "/s/api/queue", strings.NewReader(body)))
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	code, out := post(`{"url": "https://flix.example.org/web/#/details?id=0123456789abcdef0123456789abcdef"}`)
	if code != http.StatusAccepted || out["title"] != "Item 0123" || out["state"] != "waiting" || out["duration"] != 600_000.0 {
		t.Errorf("queueing: %d %v", code, out)
	}
	for body, want := range map[string]int{
		`{"url": "ffffffffffffffffffffffffffffffff"}`: http.StatusBadRequest,
		`{"url": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}`: http.StatusBadRequest,
		`{"url": "https://example.org/"}`:             http.StatusBadRequest,
		`{}`:                                          http.StatusBadRequest,
		`not json`:                                    http.StatusBadRequest,
	} {
		if code, out := post(body); code != want || out["error"] == "" {
			t.Errorf("%s: %d %v, want %d with an error", body, code, out, want)
		}
	}
	for range maxQueued - 1 {
		if code, out := post(`{"url": "0123456789abcdef0123456789abcdef"}`); code != http.StatusAccepted {
			t.Fatalf("filling the queue: %d %v", code, out)
		}
	}
	if code, out := post(`{"url": "0123456789abcdef0123456789abcdef"}`); code != http.StatusTooManyRequests || out["error"] == "" {
		t.Errorf("full queue: %d %v", code, out)
	}
	// failed items do not count
	s.requests[0].State = "failed"
	if code, out := post(`{"url": "0123456789abcdef0123456789abcdef"}`); code != http.StatusAccepted {
		t.Errorf("after a failure: %d %v", code, out)
	}
}

func TestCleanCacheKeepsPending(t *testing.T) {
	dir := t.TempDir()
	s := &server{cfg: config{CacheDir: dir}, preparing: "jf-p-1.mp4",
		st:       state{Schedule: []entry{{File: "yt-a-1.mp4"}}},
		requests: []*request{{file: "yt-q-1.mp4", State: "preparing"}, {file: "yt-n-1.mp4", State: "waiting"}}}
	keep := []string{"yt-a-1.mp4", "yt-a-1.mp4.0.vtt", "yt-a-1.mp4.1.vtt", "jf-p-1.mp4.part", "jf-p-1.mp4.0.vtt",
		"yt-q-1.mp4.part", "yt-q-1.mp4.dl/video.webm", "yt-q-1.mp4.dl/sub.en.vtt", "yt-n-1.mp4", "yt-n-1.mp4.0.vtt"}
	garbage := []string{"yt-old-1.mp4", "yt-old-1.mp4.0.vtt", "yt-old-2.mp4.part", "yt-old-3.mp4.1.vtt",
		"download/video.mp4", "yt-gone-1.mp4.dl/video.mp4"}
	for _, f := range append(keep, garbage...) {
		os.MkdirAll(filepath.Dir(filepath.Join(dir, f)), 0o755)
		os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644)
	}
	s.cleanCache()
	for _, f := range keep {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Errorf("%s was deleted", f)
		}
	}
	for _, f := range garbage {
		if _, err := os.Stat(filepath.Join(dir, strings.Split(f, "/")[0])); err == nil {
			t.Errorf("%s was kept", f)
		}
	}
}

func TestUpcoming(t *testing.T) {
	st := state{Schedule: []entry{
		{ID: "a", Start: 1000, Duration: 500},
		{ID: "b", Start: 1500, Duration: 250},
	}}
	for _, tc := range []struct {
		t        int64
		playing  string
		upcoming int
	}{{999, "", 2}, {1000, "a", 2}, {1499, "a", 2}, {1500, "b", 1}, {1749, "b", 1}, {1750, "", 0}} {
		up := st.upcoming(tc.t)
		playing := ""
		if len(up) > 0 && up[0].Start <= tc.t {
			playing = up[0].ID
		}
		if playing != tc.playing || len(up) != tc.upcoming {
			t.Errorf("at %d: playing %q with %d entries, want %q with %d", tc.t, playing, len(up), tc.playing, tc.upcoming)
		}
	}
}

func TestStateRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	empty, err := loadState(path)
	if err != nil || len(empty.Schedule) != 0 || empty.Series == nil {
		t.Fatalf("loading a missing state: %+v, %v", empty, err)
	}
	st := state{
		Schedule: []entry{{ID: "yt:x", Source: "youtube", Title: "X", Start: 1, Duration: 2, File: "yt-x-1.mp4"}},
		History:  []played{{ID: "yt:x", Title: "X", At: 3}},
		Series:   map[string]string{"s": "e"},
	}
	if err := saveState(path, st); err != nil {
		t.Fatal(err)
	}
	got, err := loadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, st) {
		t.Fatalf("got %+v, want %+v", got, st)
	}
}

func TestSecretGating(t *testing.T) {
	s := &server{secret: "Ab3dE9", cfg: config{CacheDir: t.TempDir()}}
	h := s.handler()
	get := func(path string) (int, string) {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		b, _ := io.ReadAll(rec.Body)
		return rec.Code, string(b)
	}
	for _, path := range []string{"/Ab3dE9/", "/Ab3dE9/api/time", "/Ab3dE9/api/schedule", "/Ab3dE9/player.js"} {
		if code, _ := get(path); code != http.StatusOK {
			t.Errorf("%s: %d, want 200", path, code)
		}
	}
	_, notFound := get("/nope")
	for _, path := range []string{"/", "/Ab3dE9", "/ab3dE9/", "/api/time", "/Ab3dE8/api/time", "/x/Ab3dE9/", "/Ab3dE9/media/../state.json"} {
		if code, body := get(path); code != http.StatusNotFound || body != notFound {
			t.Errorf("%s: %d %q, want the same 404 as everywhere", path, code, body)
		}
	}
}

func TestLLMPicks(t *testing.T) {
	cands := []candidate{
		{ID: "jf:1", Kind: "movie", Title: "One", Duration: 3600},
		{ID: "yt:2", Kind: "youtube", Title: "Two", Duration: 600},
		{ID: "jf:3", Kind: "episode", Title: "Three", Duration: 1800},
	}
	answer := ""
	llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer key" {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		if answer == "" {
			http.Error(w, "overloaded", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte(answer))
	}))
	defer llm.Close()
	s := &server{cfg: config{LLMURL: llm.URL + "/v1/", LLMModel: "m"}, llmKey: "key", lookAhead: time.Hour}

	answer = `{"choices":[{"message":{"content":"` + "```json\\n" + `{\"ids\": [\"yt:2\", \"nope\", \"jf:1\", \"yt:2\"]}` + "\\n```" + `"}}]}`
	picks, err := s.askLLM(t.Context(), cands, nil)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, p := range picks {
		ids = append(ids, p.ID)
	}
	if !reflect.DeepEqual(ids, []string{"yt:2", "jf:1"}) {
		t.Errorf("picks %v, want the known ids once in order", ids)
	}

	for _, a := range []string{"", `{"choices":[{"message":{"content":"{\"ids\": [\"nope\"]}"}}]}`, `{"choices":[{"message":{"content":"sorry"}}]}`} {
		answer = a
		if _, err := s.askLLM(t.Context(), cands, nil); err == nil {
			t.Errorf("answer %q: no error", a)
		}
		// the fallback fills the look-ahead with distinct candidates
		seen := map[string]bool{}
		var total int64
		for _, p := range s.choose(t.Context(), cands, nil) {
			if seen[p.ID] || p.Title == "" {
				t.Errorf("answer %q: bad fallback pick %+v", a, p)
			}
			seen[p.ID] = true
			total += p.Duration
		}
		if time.Duration(total)*time.Second < s.lookAhead {
			t.Errorf("answer %q: fallback covers only %ds", a, total)
		}
	}
}

func TestRequestMovies(t *testing.T) {
	var prompts []string
	var posted []string
	answer := ""
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/api/") && r.Header.Get("X-Api-Key") != "seer" {
			http.Error(w, "no key", http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/Items":
			if r.URL.Query().Get("Fields") != "ProviderIds" {
				http.Error(w, "no provider ids", http.StatusBadRequest)
				return
			}
			w.Write([]byte(`{"Items": [
				{"Id": "a", "Name": "A", "ProviderIds": {"Tmdb": "1"}},
				{"Id": "b", "Name": "B", "ProviderIds": {"Tmdb": "2"}},
				{"Id": "c", "Name": "C", "ProviderIds": {"Tmdb": "10"}},
				{"Id": "d", "Name": "D", "ProviderIds": {}}]}`))
		case "/api/v1/movie/1/recommendations":
			w.Write([]byte(`{"results": [
				{"id": 10, "mediaType": "movie", "title": "In Jellyfin"},
				{"id": 11, "mediaType": "movie", "title": "Available", "mediaInfo": {"status": 5}},
				{"id": 12, "mediaType": "movie", "title": "Twelve", "releaseDate": "1999-03-31"},
				{"id": 13, "mediaType": "movie", "title": "Thirteen", "releaseDate": "2001-05-01"}]}`))
		case "/api/v1/movie/2/recommendations":
			w.Write([]byte(`{"results": [
				{"id": 12, "mediaType": "movie", "title": "Twelve", "releaseDate": "1999-03-31", "voteAverage": 8.2, "overview": "Line one.\nLine two."},
				{"id": 14, "mediaType": "movie", "title": "Fourteen", "releaseDate": "2010-01-01"}]}`))
		case "/api/v1/discover/trending":
			w.Write([]byte(`{"results": [
				{"id": 15, "mediaType": "tv", "name": "A Series"},
				{"id": 16, "mediaType": "movie", "title": "Sixteen", "releaseDate": "2020-01-01"},
				{"id": 18, "mediaType": "movie", "title": "Unreleased", "releaseDate": "2999-01-01"},
				{"id": 17, "mediaType": "movie", "title": "Pending", "mediaInfo": {"status": 2}}]}`))
		case "/api/v1/request":
			b, _ := io.ReadAll(r.Body)
			posted = append(posted, string(b))
			w.WriteHeader(http.StatusCreated)
			w.Write([]byte(`{}`))
		case "/llm/chat/completions":
			var req struct {
				Messages []struct{ Content string }
			}
			json.NewDecoder(r.Body).Decode(&req)
			prompts = append(prompts, req.Messages[1].Content)
			if answer == "" {
				http.Error(w, "overloaded", http.StatusServiceUnavailable)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": answer}}}})
		default:
			http.NotFound(w, r)
		}
	}))
	defer stub.Close()

	dir := t.TempDir()
	write := func(name, content string) string {
		path := filepath.Join(dir, name)
		os.WriteFile(path, []byte(content), 0o600)
		return path
	}
	cfg, _ := json.Marshal(config{Listen: "127.0.0.1:0", StateDir: filepath.Join(dir, "state"), CacheDir: filepath.Join(dir, "cache"),
		SecretFile: write("secret", "s"), JellyfinURL: stub.URL, LLMURL: stub.URL + "/llm/", LookAhead: "3h",
		JellyseerrURL: stub.URL, JellyseerrKeyFile: write("seer", "seer\n"), RequestsPerDay: 2})
	cfgPath := write("tv.json", string(cfg))
	start := func() *server {
		s, err := newServer(cfgPath)
		if err != nil {
			t.Fatal(err)
		}
		return s
	}

	s := start()
	s.st.History = []played{{ID: "jf:a", Title: "A"}, {ID: "yt:x", Title: "X"}, {ID: "jf:b", Title: "B"}, {ID: "jf:d", Title: "D"}}
	answer = "```json\n" + `{"ids": ["tmdb:99", "tmdb:10", "tmdb:15", "tmdb:13", "tmdb:13", "tmdb:12", "tmdb:14"]}` + "\n```"
	s.requestMovies(t.Context())
	if len(prompts) != 1 {
		t.Fatalf("%d llm calls, want 1", len(prompts))
	}
	var offered []string
	for _, line := range strings.Split(prompts[0], "\n") {
		if id, _, ok := strings.Cut(line, " | "); ok && strings.HasPrefix(id, "tmdb:") {
			offered = append(offered, id)
		}
	}
	// recommendations for the last played movie come first
	if want := []string{"tmdb:12", "tmdb:14", "tmdb:13", "tmdb:16"}; !reflect.DeepEqual(offered, want) {
		t.Errorf("offered %v, want %v", offered, want)
	}
	if !strings.Contains(prompts[0], "A\nX\nB\nD\n") || !strings.Contains(prompts[0], "tmdb:12 | Twelve | 1999 | 8.2 | Line one. Line two.\n") {
		t.Errorf("prompt lacks the history or a candidate line:\n%s", prompts[0])
	}
	if want := []string{`{"mediaId":13,"mediaType":"movie"}`, `{"mediaId":12,"mediaType":"movie"}`}; !reflect.DeepEqual(posted, want) {
		t.Errorf("posted %v, want %v", posted, want)
	}
	if !reflect.DeepEqual(s.st.RequestedMovies, []int{13, 12}) {
		t.Errorf("requested %v, want [13 12]", s.st.RequestedMovies)
	}

	// the same day, also after a restart, nothing happens
	s.requestMovies(t.Context())
	s = start()
	s.requestMovies(t.Context())
	if len(prompts) != 1 || len(posted) != 2 {
		t.Errorf("same day: %d llm calls and %d requests, want 1 and 2", len(prompts), len(posted))
	}

	// a day later a failing LLM means no requests that day
	s.st.MoviesRequestedAt -= (25 * time.Hour).Milliseconds()
	answer = ""
	s.requestMovies(t.Context())
	if len(prompts) != 2 || len(posted) != 2 {
		t.Errorf("llm failure: %d llm calls and %d requests, want 2 and 2", len(prompts), len(posted))
	}
	s.requestMovies(t.Context())
	if len(prompts) != 2 {
		t.Errorf("retried after the llm failure on the same day")
	}

	// the next day, an answer without known ids requests nothing
	s.st.MoviesRequestedAt -= (25 * time.Hour).Milliseconds()
	answer = `{"ids": ["tmdb:13", "16", "tmdb:10"]}`
	s.requestMovies(t.Context())
	if len(prompts) != 3 || len(posted) != 2 || strings.Contains(prompts[2], "tmdb:13 |") {
		t.Errorf("invalid ids: %d llm calls and %d requests, offered again:\n%s", len(prompts), len(posted), prompts[2])
	}
}

func TestItemLink(t *testing.T) {
	movie := jellyfinItem{Type: "Movie", ProviderIDs: map[string]string{"Tmdb": "603", "Imdb": "tt0133093"}}
	episode := jellyfinItem{Type: "Episode", Season: 2, Episode: 5, ProviderIDs: map[string]string{"Tmdb": "999", "Imdb": "tt0959621"}}
	series := jellyfinItem{Type: "Series", ProviderIDs: map[string]string{"Tmdb": "1396"}}
	jf := candidate{ID: "jf:x", Kind: "movie"}
	for _, tc := range []struct {
		name       string
		c          candidate
		it, series jellyfinItem
		want       string
	}{
		{"youtube", candidate{ID: "yt:dQw4w9WgXcQ", Kind: "youtube", ref: "https://youtu.be/dQw4w9WgXcQ"}, jellyfinItem{}, jellyfinItem{}, "https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
		{"movie", jf, movie, jellyfinItem{}, "https://www.themoviedb.org/movie/603"},
		{"episode", jf, episode, series, "https://www.themoviedb.org/tv/1396/season/2/episode/5"},
		{"episode without series tmdb", jf, episode, jellyfinItem{}, "https://www.imdb.com/title/tt0959621/"},
		{"movie with imdb only", jf, jellyfinItem{Type: "Movie", ProviderIDs: map[string]string{"Imdb": "tt1"}}, jellyfinItem{}, "https://www.imdb.com/title/tt1/"},
		{"none", jf, jellyfinItem{Type: "Movie"}, jellyfinItem{}, ""},
	} {
		if got := itemLink(tc.c, tc.it, tc.series); got != tc.want {
			t.Errorf("%s: %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestJellyfinSubtitles(t *testing.T) {
	streams := []mediaStream{
		{Type: "Video", Index: 0},
		{Type: "Audio", Index: 1, Language: "eng"},
		{Type: "Subtitle", Index: 2, Language: "eng", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 3, Language: "ger", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 4, Language: "eng", Title: "PGS", IsTextSubtitleStream: false},
		{Type: "Subtitle", Index: 5, Language: "eng", Title: "SDH", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 6, Language: "eng", Title: "english (forced)", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 7, Language: "fre", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 8, Language: "und", IsTextSubtitleStream: true},
		{Type: "Subtitle", Index: 9, Language: "tlh", Title: "Klingon", IsTextSubtitleStream: true},
	}
	want := []subtitle{
		{"f.mp4.0.vtt", "en", "English", "2"},
		{"f.mp4.1.vtt", "de", "Deutsch", "3"},
		{"f.mp4.2.vtt", "en", "English SDH", "5"},
		{"f.mp4.3.vtt", "en", "english (forced)", "6"},
		{"f.mp4.4.vtt", "fr", "Français", "7"},
		{"f.mp4.5.vtt", "", "Unknown", "8"},
		{"f.mp4.6.vtt", "tlh", "tlh Klingon", "9"},
	}
	if got := jellyfinSubtitles("f.mp4", streams); !reflect.DeepEqual(got, want) {
		t.Errorf("got  %+v\nwant %+v", got, want)
	}
}

func TestPickYouTubeSubtitles(t *testing.T) {
	keys := func(ks ...string) map[string]json.RawMessage {
		m := map[string]json.RawMessage{}
		for _, k := range ks {
			m[k] = nil
		}
		return m
	}
	auto := keys("en", "en-orig", "de", "fr")
	got := pickYouTubeSubtitles("v.mp4", []string{"en", "de", "es"}, keys("en-US", "en-GB", "live_chat"), auto)
	want := []subtitle{{"v.mp4.0.vtt", "en", "English", "en-GB"}, {"v.mp4.1.vtt", "de", "Deutsch (auto)", "de"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("regional manual and auto:\n got  %+v\nwant %+v", got, want)
	}
	got = pickYouTubeSubtitles("v.mp4", []string{"en", "de"}, keys("en-GB", "en", "de"), auto)
	want = []subtitle{{"v.mp4.0.vtt", "en", "English", "en"}, {"v.mp4.1.vtt", "de", "Deutsch", "de"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("exact manual:\n got  %+v\nwant %+v", got, want)
	}
}

func TestCutVTT(t *testing.T) {
	vtt := "WEBVTT\nKind: captions\nLanguage: en\n\n" +
		"00:00:01.000 --> 00:00:04.000\nbefore\n\n" +
		"00:00:09.000 --> 00:00:12.000 align:start position:0%\noverlaps first cut start\n\n" +
		"00:00:11.000 --> 00:00:19.000\ninside first cut\n\n" +
		"00:00:19.000 --> 00:00:22.000\noverlaps first cut end\n\n" +
		"00:00:25.000 --> 00:00:28.000\nbetween\n\n" +
		"00:30.000 --> 00:40.000\nspans second cut\n\n" +
		"cue-id\n00:01:00.000 --> 00:01:02.500\nafter<00:01:01.250><c> both</c>\n"
	// [10, 20] and [32, 35] removed: 13s
	got := string(cutVTT([]byte(vtt), [][2]float64{{10, 20}, {32, 35}}))
	want := "WEBVTT\nKind: captions\nLanguage: en\n\n" +
		"00:00:01.000 --> 00:00:04.000\nbefore\n\n" +
		"00:00:09.000 --> 00:00:10.000 align:start position:0%\noverlaps first cut start\n\n" +
		"00:00:10.000 --> 00:00:12.000\noverlaps first cut end\n\n" +
		"00:00:15.000 --> 00:00:18.000\nbetween\n\n" +
		"00:00:20.000 --> 00:00:27.000\nspans second cut\n\n" +
		"cue-id\n00:00:47.000 --> 00:00:49.500\nafter<00:00:48.250><c> both</c>\n"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	if got := string(cutVTT([]byte(vtt), nil)); got != vtt {
		t.Errorf("no cuts changed the file:\n%s", got)
	}
}

func TestYouTubeInfoCuts(t *testing.T) {
	var info youtubeInfo
	json.Unmarshal([]byte(`{"sponsorblock_chapters": [
		{"start_time": 827.821, "end_time": 878.245, "type": "skip"},
		{"start_time": 0, "end_time": 12, "type": "skip"},
		{"start_time": 732.147, "end_time": 828.353, "type": "skip"},
		{"start_time": 100, "end_time": 101, "type": "poi"}]}`), &info)
	want := [][2]float64{{0, 12}, {732.147, 878.245}}
	if got := info.cuts(); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestYouTubeArgsSponsorBlock(t *testing.T) {
	s := &server{cfg: config{YtDlp: "yt-dlp"}}
	if args := strings.Join(s.youtubeArgs("ref", "dir", true), " "); strings.Contains(args, "sponsorblock") {
		t.Errorf("off, got %s", args)
	}
	s.cfg.SponsorblockCategories = []string{"sponsor", "selfpromo"}
	args := strings.Join(s.youtubeArgs("ref", "dir", true), " ")
	if !strings.HasSuffix(args, " --sponsorblock-mark sponsor,selfpromo --no-embed-chapters ref") {
		t.Errorf("on, got %s", args)
	}
	if args := strings.Join(s.youtubeArgs("ref", "dir", false), " "); strings.Contains(args, "sponsorblock") {
		t.Errorf("uncut retry, got %s", args)
	}
}

func TestCutGraph(t *testing.T) {
	scale := "[cv]" + scaleFilter + "[v]"
	// a cut at 0, one in the middle and one past the end
	got := cutGraph([][2]float64{{0, 12}, {149.5, 229}, {761, 840}}, 839.84, true)
	want := "[0:v:0]trim=start=12.000:end=149.500,setpts=PTS-STARTPTS[v0];[0:a:0]atrim=start=12.000:end=149.500,asetpts=PTS-STARTPTS[a0];" +
		"[0:v:0]trim=start=229.000:end=761.000,setpts=PTS-STARTPTS[v1];[0:a:0]atrim=start=229.000:end=761.000,asetpts=PTS-STARTPTS[a1];" +
		"[v0][a0][v1][a1]concat=n=2:v=1:a=1[cv][a];" + scale
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	got = cutGraph([][2]float64{{5, 6}}, 10, false)
	want = "[0:v:0]trim=start=0.000:end=5.000,setpts=PTS-STARTPTS[v0];[0:v:0]trim=start=6.000,setpts=PTS-STARTPTS[v1];" +
		"[v0][v1]concat=n=2:v=1:a=0[cv];" + scale
	if got != want {
		t.Errorf("no audio, open end: got\n%s\nwant\n%s", got, want)
	}
	if got := cutGraph(nil, 10, true); got != "" {
		t.Errorf("no cuts: got %s", got)
	}
	if got := cutGraph([][2]float64{{0, 11}}, 10, true); got != "" {
		t.Errorf("all cut: got %s", got)
	}
}

func TestJellyfinExtrasSkipsFailedSubtitles(t *testing.T) {
	jellyfin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path + "?" + r.URL.Query().Get("Ids") {
		case "/Items?ep":
			w.Write([]byte(`{"Items": [{"Id": "ep", "Type": "Episode", "SeriesId": "sr", "ParentIndexNumber": 1, "IndexNumber": 3,
				"MediaSources": [{"Id": "ms", "MediaStreams": [
					{"Type": "Subtitle", "Index": 2, "Language": "eng", "IsTextSubtitleStream": true},
					{"Type": "Subtitle", "Index": 3, "Language": "ger", "IsTextSubtitleStream": true},
					{"Type": "Subtitle", "Index": 4, "Language": "ger", "IsTextSubtitleStream": false}]}]}]}`))
		case "/Items?sr":
			w.Write([]byte(`{"Items": [{"Id": "sr", "Type": "Series", "ProviderIds": {"Tmdb": "42"}}]}`))
		case "/Videos/ep/ms/Subtitles/2/Stream.vtt?":
			w.Write([]byte("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n"))
		default:
			http.Error(w, "no", http.StatusInternalServerError)
		}
	}))
	defer jellyfin.Close()
	dir := t.TempDir()
	s := &server{cfg: config{CacheDir: dir, JellyfinURL: jellyfin.URL}}
	it, series, subs := s.jellyfinExtras(t.Context(), "ep", "jf-ep-1.mp4")
	if want := []subtitle{{"jf-ep-1.mp4.0.vtt", "en", "English", "2"}}; !reflect.DeepEqual(subs, want) {
		t.Errorf("subtitles %+v, want %+v", subs, want)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "jf-ep-1.mp4.0.vtt")); err != nil || !strings.Contains(string(b), "Hello") {
		t.Errorf("subtitle file: %q, %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "jf-ep-1.mp4.1.vtt")); err == nil {
		t.Errorf("the failed track left a file")
	}
	if got := itemLink(candidate{Kind: "episode"}, it, series); got != "https://www.themoviedb.org/tv/42/season/1/episode/3" {
		t.Errorf("link %q", got)
	}
}

func TestMediaServesSubtitles(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"jf-a-1.mp4", "jf-a-1.mp4.0.vtt", "jf-a-1.mp4.part", ".x.vtt"} {
		os.WriteFile(filepath.Join(dir, f), []byte("WEBVTT\n"), 0o644)
	}
	h := (&server{secret: "s", cfg: config{CacheDir: dir}}).handler()
	get := func(path string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		return rec
	}
	rec := get("/s/media/jf-a-1.mp4.0.vtt")
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "text/vtt; charset=utf-8" || rec.Body.String() != "WEBVTT\n" {
		t.Errorf("subtitles: %d %q %q", rec.Code, rec.Header().Get("Content-Type"), rec.Body.String())
	}
	if rec := get("/s/media/jf-a-1.mp4"); rec.Code != http.StatusOK {
		t.Errorf("video: %d", rec.Code)
	}
	for _, path := range []string{"/s/media/jf-a-1.mp4.part", "/s/media/.x.vtt", "/s/media/nope.mp4.0.vtt"} {
		if rec := get(path); rec.Code != http.StatusNotFound {
			t.Errorf("%s: %d, want 404", path, rec.Code)
		}
	}
}
