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
	keep := []string{"yt-a-1.mp4", "jf-p-1.mp4.part", "yt-q-1.mp4.part", "yt-q-1.mp4.dl/video.webm", "yt-n-1.mp4"}
	garbage := []string{"yt-old-1.mp4", "yt-old-2.mp4.part", "download/video.mp4", "yt-gone-1.mp4.dl/video.mp4"}
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
