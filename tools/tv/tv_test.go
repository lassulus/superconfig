package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
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

// backToBack fails if an upcoming entry does not start where the one before
// it ends.
func backToBack(t *testing.T, name string, es []entry) {
	t.Helper()
	for i := 1; i < len(es); i++ {
		if es[i].Start != es[i-1].Start+es[i-1].Duration {
			t.Errorf("%s: gap or overlap before %s: %q", name, es[i].ID, times(es))
		}
	}
}

func editSchedule() []entry {
	return []entry{
		{ID: "a", Start: 0, Duration: 1000},
		{ID: "b", Start: 1000, Duration: 1000},
		{ID: "c", Start: 2000, Duration: 500},
		{ID: "d", Start: 2500, Duration: 500},
	}
}

func TestRemove(t *testing.T) {
	st := state{Schedule: editSchedule()}
	if _, err := st.remove(300, slot{1000, "b"}); err != nil {
		t.Fatal(err)
	}
	checkSchedule(t, "middle", st.Schedule, "a 0s-1µs", "c 1µs-1.5µs", "d 1.5µs-2µs")
	backToBack(t, "middle", st.Schedule)
	if _, err := st.remove(300, slot{1500, "d"}); err != nil {
		t.Fatal(err)
	}
	checkSchedule(t, "last", st.Schedule, "a 0s-1µs", "c 1µs-1.5µs")
	if _, err := st.remove(300, slot{0, "a"}); err != errPlaying {
		t.Errorf("playing: %v", err)
	}
	for _, sl := range []slot{{2000, "c"}, {1000, "b"}, {1000, "x"}} {
		if _, err := st.remove(300, sl); err != errStale {
			t.Errorf("stale %v: %v", sl, err)
		}
	}
	checkSchedule(t, "after the refused ones", st.Schedule, "a 0s-1µs", "c 1µs-1.5µs")

	// nothing playing: the next one takes over the start of the removed one
	st = state{Schedule: editSchedule()}
	st.remove(-100, slot{0, "a"})
	checkSchedule(t, "first while nothing plays", st.Schedule, "b 0s-1µs", "c 1µs-1.5µs", "d 1.5µs-2µs")
}

func TestMove(t *testing.T) {
	st := state{Schedule: editSchedule()}
	step := func(name string, sl slot, after *slot, want ...string) {
		t.Helper()
		if _, err := st.move(300, sl, after); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		checkSchedule(t, name, st.Schedule, want...)
		backToBack(t, name, st.Schedule)
	}
	step("forward", slot{1000, "b"}, &slot{2500, "d"}, "a 0s-1µs", "c 1µs-1.5µs", "d 1.5µs-2µs", "b 2µs-3µs")
	step("backward", slot{2000, "b"}, &slot{1000, "c"}, "a 0s-1µs", "c 1µs-1.5µs", "b 1.5µs-2.5µs", "d 2.5µs-3µs")
	step("to the front", slot{2500, "d"}, nil, "a 0s-1µs", "d 1µs-1.5µs queued", "c 1.5µs-2µs", "b 2µs-3µs")
	// later requests and moves line up behind the ones moved to the front
	step("behind the front one", slot{2000, "b"}, &slot{1000, "d"}, "a 0s-1µs", "d 1µs-1.5µs queued", "b 1.5µs-2.5µs queued", "c 2.5µs-3µs")
	step("after the playing one by its slot", slot{2500, "c"}, &slot{0, "a"}, "a 0s-1µs", "c 1µs-1.5µs queued", "d 1.5µs-2µs queued", "b 2µs-3µs queued")
	step("after itself", slot{1500, "d"}, &slot{1500, "d"}, "a 0s-1µs", "c 1µs-1.5µs queued", "d 1.5µs-2µs queued", "b 2µs-3µs queued")

	for _, tc := range []struct {
		sl    slot
		after *slot
		err   error
	}{
		{slot{1000, "b"}, nil, errStale},
		{slot{2000, "b"}, &slot{2500, "c"}, errStale},
		{slot{0, "a"}, nil, errPlaying},
	} {
		if _, err := st.move(300, tc.sl, tc.after); err != tc.err {
			t.Errorf("move %v after %v: %v, want %v", tc.sl, tc.after, err, tc.err)
		}
	}
	checkSchedule(t, "after the refused ones", st.Schedule, "a 0s-1µs", "c 1µs-1.5µs queued", "d 1.5µs-2µs queued", "b 2µs-3µs queued")

	st = state{Schedule: editSchedule()}
	if _, err := st.move(-100, slot{2000, "c"}, nil); err != nil {
		t.Fatal(err)
	}
	checkSchedule(t, "to the front while nothing plays", st.Schedule, "c 0s-500ns queued", "a 500ns-1.5µs", "b 1.5µs-2.5µs", "d 2.5µs-3µs")
}

func TestInsert(t *testing.T) {
	st := state{Schedule: editSchedule()}
	st.insert(entry{ID: "n", Duration: 100}, 300, &slot{1000, "b"})
	checkSchedule(t, "after b", st.Schedule, "a 0s-1µs", "b 1µs-2µs", "n 2µs-2.1µs", "c 2.1µs-2.6µs", "d 2.6µs-3.1µs")
	st.insert(entry{ID: "m", Duration: 100}, 300, &slot{2000, "c"})
	checkSchedule(t, "after a gone entry", st.Schedule, "a 0s-1µs", "m 1µs-1.1µs queued", "b 1.1µs-2.1µs", "n 2.1µs-2.2µs", "c 2.2µs-2.7µs", "d 2.7µs-3.2µs")
	backToBack(t, "insert", st.Schedule)
}

func TestRequestScheduledSource(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "yt-x-1.mp4"), []byte("x"), 0o644)
	now := nowMs()
	// a lookup or prepare would run the missing yt-dlp and fail
	s := &server{secret: "s", adminKey: "k", statePath: filepath.Join(dir, "state.json"),
		cfg: config{CacheDir: dir, YtDlp: filepath.Join(dir, "no-yt-dlp")},
		st: state{Schedule: []entry{
			{ID: "jf:a", Start: now - 1000, Duration: 600_000, File: "jf-a-1.mp4"},
			{ID: "jf:b", Start: now + 599_000, Duration: 600_000, File: "jf-b-1.mp4"},
			{ID: "yt:dQw4w9WgXcQ", Start: now + 1_199_000, Duration: 200_000, File: "yt-x-1.mp4"},
			{ID: "jf:c", Start: now + 1_399_000, Duration: 600_000, File: "jf-c-1.mp4"},
		}}}
	post := func(path, body string) (int, map[string]any) {
		req := httptest.NewRequest("POST", "/s/"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer k")
		rec := httptest.NewRecorder()
		s.handler().ServeHTTP(rec, req)
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	url := `{"url": "https://youtu.be/dQw4w9WgXcQ"}`
	if code, out := post("api/queue", url); code != http.StatusConflict || out["start"] != float64(now+1_199_000) {
		t.Errorf("queueing a scheduled source: %d %v, want 409 with its start", code, out)
	}
	if code, out := post("api/skip", url); code != http.StatusOK || out["entries"] == nil {
		t.Fatalf("playing a scheduled source now: %d %v", code, out)
	}
	sched := s.st.Schedule
	if len(s.requests) != 0 || len(sched) != 4 || sched[1].ID != "yt:dQw4w9WgXcQ" || sched[1].File != "yt-x-1.mp4" || sched[0].Start+sched[0].Duration != sched[1].Start ||
		sched[1].Start < now+cutoverLead.Milliseconds() || sched[1].Start > nowMs()+cutoverLead.Milliseconds() {
		t.Errorf("play now: requests %v, schedule %q", s.requests, times(sched))
	}
	backToBack(t, "play now", sched)

	// a requested source becomes play-now instead of a second request
	s.requests = []*request{{State: "waiting", c: candidate{ID: "yt:aaaaaaaaaaa"}}}
	if code, _ := post("api/skip", `{"url": "https://youtu.be/aaaaaaaaaaa"}`); code != http.StatusAccepted || len(s.requests) != 1 || !s.requests[0].PlayNow {
		t.Errorf("play now of a request: %d, requests %v", code, s.requests)
	}
	if code, _ := post("api/queue", `{"url": "https://youtu.be/aaaaaaaaaaa"}`); code != http.StatusConflict || len(s.requests) != 1 {
		t.Errorf("queueing a requested source: %d, requests %v", code, s.requests)
	}
}

func TestEditAuth(t *testing.T) {
	s := &server{secret: "s", adminKey: "k", st: state{Schedule: editSchedule()}}
	for _, path := range []string{"api/schedule/delete", "api/schedule/move", "api/schedule/insert"} {
		rec := httptest.NewRecorder()
		s.handler().ServeHTTP(rec, httptest.NewRequest("POST", "/s/"+path, strings.NewReader(`{"start": 1000, "id": "b"}`)))
		if rec.Code != http.StatusUnauthorized || len(s.st.Schedule) != 4 {
			t.Errorf("%s without the admin key: %d", path, rec.Code)
		}
	}
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
	jellyfin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.URL.Query().Get("Ids")
		items := []map[string]any{}
		if id != "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" {
			secs := int64(600)
			if id == "ffffffffffffffffffffffffffffffff" {
				secs = 5 * 3600
			}
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
	if code, out := post(`{"url": "0123456789abcdef0123456789abcdef"}`); code != http.StatusConflict || out["error"] == "" {
		t.Errorf("same source again: %d %v, want 409", code, out)
	}
	for i := range maxQueued - 1 {
		if code, out := post(fmt.Sprintf(`{"url": "%032x"}`, i+1)); code != http.StatusAccepted {
			t.Fatalf("filling the queue: %d %v", code, out)
		}
	}
	if code, out := post(`{"url": "abcdef0123456789abcdef0123456789"}`); code != http.StatusTooManyRequests || out["error"] == "" {
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
	got := cutGraph([][2]float64{{0, 12}, {149.5, 229}, {761, 840}}, 839.84, "0:a:0")
	want := "[0:v:0]trim=start=12.000:end=149.500,setpts=PTS-STARTPTS[v0];[0:a:0]atrim=start=12.000:end=149.500,asetpts=PTS-STARTPTS[a0];" +
		"[0:v:0]trim=start=229.000:end=761.000,setpts=PTS-STARTPTS[v1];[0:a:0]atrim=start=229.000:end=761.000,asetpts=PTS-STARTPTS[a1];" +
		"[v0][a0][v1][a1]concat=n=2:v=1:a=1[cv][a];" + scale
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	got = cutGraph([][2]float64{{5, 6}}, 10, "")
	want = "[0:v:0]trim=start=0.000:end=5.000,setpts=PTS-STARTPTS[v0];[0:v:0]trim=start=6.000,setpts=PTS-STARTPTS[v1];" +
		"[v0][v1]concat=n=2:v=1:a=0[cv];" + scale
	if got != want {
		t.Errorf("no audio, open end: got\n%s\nwant\n%s", got, want)
	}
	if got := cutGraph(nil, 10, "0:a:0"); got != "" {
		t.Errorf("no cuts: got %s", got)
	}
	if got := cutGraph([][2]float64{{0, 11}}, 10, "0:a:0"); got != "" {
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

// A re-encoded item gets a keyframe at least every 2 s whatever the source
// had, so players can seek in it quickly.
func TestPrepareKeyframes(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg on PATH")
	}
	ffprobe := strings.TrimSuffix(ffmpeg, "ffmpeg") + "ffprobe"
	dir := t.TempDir()
	// MPEG-4 Part 2 has to be re-encoded; one keyframe every 10 s
	src := filepath.Join(dir, "src.mkv")
	if _, err := run(t.Context(), ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=s=320x240:r=25",
		"-t", "21", "-c:v", "mpeg4", "-g", "250", src); err != nil {
		t.Fatal(err)
	}
	jellyfin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/Videos/src/stream" {
			http.ServeFile(w, r, src)
			return
		}
		http.Error(w, "no", http.StatusInternalServerError)
	}))
	defer jellyfin.Close()
	s := &server{cfg: config{CacheDir: dir, JellyfinURL: jellyfin.URL, FFmpeg: ffmpeg}}
	if _, err := s.prepare(t.Context(), candidate{ID: "jf:src", Kind: "movie", ref: "src"}, "jf-src-1.mp4"); err != nil {
		t.Fatal(err)
	}
	out, err := run(t.Context(), ffprobe, "-v", "error", "-select_streams", "v", "-skip_frame", "nokey",
		"-show_entries", "frame=pts_time", "-of", "csv=p=0", filepath.Join(dir, "jf-src-1.mp4"))
	if err != nil {
		t.Fatal(err)
	}
	keys := strings.Fields(string(out))
	last := 0.0
	for _, k := range append(keys, "21") {
		at, err := strconv.ParseFloat(strings.TrimSuffix(k, ","), 64)
		if err != nil {
			t.Fatal(err)
		}
		if at-last > 2.05 {
			t.Errorf("keyframes at %v: %.2f s without one after %.2f", keys, at-last, last)
		}
		last = at
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

func TestDedupeVTT(t *testing.T) {
	in := "WEBVTT\n\n00:02:54.560 --> 00:03:00.860\nGolo presents\n\n00:02:54.560 --> 00:03:00.860\nGolo presents\n\n00:02:55.000 --> 00:03:00.860\nGolo presents\n\n00:02:54.560 --> 00:03:00.860\nOther line"
	want := "WEBVTT\n\n00:02:54.560 --> 00:03:00.860\nGolo presents\n\n00:02:55.000 --> 00:03:00.860\nGolo presents\n\n00:02:54.560 --> 00:03:00.860\nOther line"
	if got := string(dedupeVTT([]byte(in))); got != want {
		t.Errorf("dedupeVTT:\n%s\nwant:\n%s", got, want)
	}
}

// airtime returns the YouTube and Jellyfin seconds of a batch.
func airtime(picks []candidate) (yt, jf int64) {
	for _, c := range picks {
		if c.Kind == "youtube" {
			yt += c.Duration
		} else {
			jf += c.Duration
		}
	}
	return yt, jf
}

func ids(picks []candidate) []string {
	var out []string
	for _, p := range picks {
		out = append(out, p.ID)
	}
	return out
}

// videos returns n ten minute YouTube candidates spread over three channels.
func videos(n int) []candidate {
	var out []candidate
	for i := range n {
		out = append(out, candidate{ID: fmt.Sprintf("yt:%d", i), Kind: "youtube", Title: "V", Group: fmt.Sprintf("ch%d", i%3), Duration: 600})
	}
	return out
}

func checkShare(t *testing.T, name string, picks []candidate, share float64, look time.Duration) {
	t.Helper()
	yt, jf := airtime(picks)
	if float64(yt) < share*float64(yt+jf) {
		t.Errorf("%s: YouTube %ds of %ds, want at least %.0f%%: %v", name, yt, yt+jf, share*100, ids(picks))
	}
	if time.Duration(yt+jf)*time.Second < look {
		t.Errorf("%s: covers %ds of %s: %v", name, yt+jf, look, ids(picks))
	}
	seen := map[string]bool{}
	for _, p := range picks {
		if seen[p.ID] {
			t.Errorf("%s: %s twice", name, p.ID)
		}
		seen[p.ID] = true
	}
}

func TestBalance(t *testing.T) {
	look := 3 * time.Hour
	movie := candidate{ID: "jf:m", Kind: "movie", Title: "M", Duration: 7200}
	movie2 := candidate{ID: "jf:m2", Kind: "movie", Title: "M2", Duration: 6000}
	ep := candidate{ID: "jf:e", Kind: "episode", Title: "E", Group: "S", Duration: 2700}
	ep2 := candidate{ID: "jf:e2", Kind: "episode", Title: "E2", Group: "T", Duration: 1500}
	yt := videos(60)

	// share 0 keeps the answer as it is, even all Jellyfin and too long
	picks := []candidate{movie, movie2, ep}
	if got := balance(picks, yt, 0, look); !reflect.DeepEqual(got, picks) {
		t.Errorf("share 0: %v", ids(got))
	}

	// a 2h movie cannot be half of 3h: it stays as the only Jellyfin item and
	// the batch grows until YouTube matches it
	got := balance([]candidate{movie, ep, yt[0], movie2}, yt, 0.5, look)
	checkShare(t, "long movie", got, 0.5, look)
	if got[0].ID != "jf:m" || got[1].ID != "yt:0" {
		t.Errorf("long movie: %v, want the answer's order first", ids(got))
	}
	if _, jf := airtime(got); jf != movie.Duration {
		t.Errorf("long movie: Jellyfin %ds, want only the movie", jf)
	}
	if y, _ := airtime(got); y > movie.Duration+600 {
		t.Errorf("long movie: YouTube %ds, more than needed", y)
	}

	// Jellyfin items that fit the rest of the look-ahead all stay
	got = balance([]candidate{ep, ep2, yt[1]}, yt, 0.5, look)
	checkShare(t, "short episodes", got, 0.5, look)
	if got[0].ID != "jf:e" || got[1].ID != "jf:e2" || got[2].ID != "yt:1" {
		t.Errorf("short episodes: %v", ids(got))
	}

	// only YouTube: topped up to the look-ahead, preferring another channel
	got = balance([]candidate{yt[0]}, yt, 0.5, look)
	checkShare(t, "only YouTube", got, 0.5, look)
	for i := 1; i < len(got); i++ {
		if got[i].Group == got[i-1].Group {
			t.Errorf("only YouTube: %s and %s of the same channel back to back", got[i-1].ID, got[i].ID)
		}
	}

	// no YouTube at all: the share cannot hold, the answer stays
	if got := balance(picks, []candidate{movie, ep}, 0.5, look); !reflect.DeepEqual(got, picks) {
		t.Errorf("only Jellyfin: %v", ids(got))
	}

	// share 1 drops every Jellyfin item
	got = balance([]candidate{movie, yt[2], ep}, yt, 1, look)
	checkShare(t, "share 1", got, 1, look)

	// YouTube runs out: everything there is, the share as close as it gets
	got = balance([]candidate{movie}, yt[:3], 0.5, look)
	if !reflect.DeepEqual(ids(got), []string{"jf:m", "yt:0", "yt:1", "yt:2"}) {
		t.Errorf("few videos: %v", ids(got))
	}
}

func TestPicksKeepYouTubeShare(t *testing.T) {
	var cands []candidate
	for i := range 40 {
		cands = append(cands, candidate{ID: fmt.Sprintf("jf:%d", i), Kind: "movie", Title: "M", Duration: int64(5400 + 60*i)})
	}
	cands = append(cands, videos(100)...)
	// the LLM answers with mostly movies
	llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"choices":[{"message":{"content":"{\"ids\": [\"jf:1\", \"yt:5\", \"jf:2\", \"jf:3\"]}"}}]}`))
	}))
	defer llm.Close()
	s := &server{cfg: config{LLMURL: llm.URL, YouTubeShare: 0.5}, lookAhead: 3 * time.Hour}
	got := s.choose(t.Context(), cands, nil)
	checkShare(t, "llm", got, 0.5, s.lookAhead)
	if got[0].ID != "jf:1" || got[1].ID != "yt:5" {
		t.Errorf("llm: %v, want the answer's order first", ids(got))
	}
	if _, jf := airtime(got); jf != cands[1].Duration {
		t.Errorf("llm: Jellyfin %ds, want only the first movie", jf)
	}

	for i := range 50 {
		checkShare(t, fmt.Sprintf("random %d", i), s.randomPicks(cands), 0.5, s.lookAhead)
	}
}

// TestPromptSize logs the size of a prompt for 35 channels of 30 videos and
// a Jellyfin sample of 120 movies and 40 episodes.
func TestPromptSize(t *testing.T) {
	var cands []candidate
	for i := range 120 {
		cands = append(cands, candidate{ID: fmt.Sprintf("jf:%032x", i), Kind: "movie", Title: "The Quite Long Movie Title Number " + fmt.Sprint(i), Duration: 6600})
	}
	for i := range 40 {
		cands = append(cands, candidate{ID: fmt.Sprintf("jf:%032x", 1000+i), Kind: "episode", Title: fmt.Sprintf("Some Series S02E%02d An Episode Title", i), Group: "Some Series", Duration: 2700})
	}
	for i := range 35 * 30 {
		cands = append(cands, candidate{ID: fmt.Sprintf("yt:%011d", i), Kind: "youtube", Title: "Why This Thing Is Actually Way More Interesting Than You Think", Group: fmt.Sprintf("Channel Name %d", i%35), Duration: 1500})
	}
	history := make([]string, 30)
	for i := range history {
		history[i] = "Something That Played Recently"
	}
	s := &server{cfg: config{YouTubeShare: 0.5}, lookAhead: 3 * time.Hour}
	system, prompt := s.llmPrompt(cands, history)
	n := len(system) + len(prompt)
	t.Logf("%d candidates: prompt %d bytes, ~%d tokens", len(cands), n, n/4)
}

func TestChannelURL(t *testing.T) {
	for in, want := range map[string]string{
		"@veritasium":    "https://www.youtube.com/@veritasium/videos",
		" /@Shaun_vids ": "https://www.youtube.com/@Shaun_vids/videos",
		"https://www.youtube.com/@3blue1brown/videos": "https://www.youtube.com/@3blue1brown/videos",
		"https://youtube.com/@foo.bar/featured":       "https://www.youtube.com/@foo.bar/videos",
		"m.youtube.com/@a-b-c?si=x":                   "https://www.youtube.com/@a-b-c/videos",
		"http://www.youtube.com/@ÄÖü":                 "https://www.youtube.com/@ÄÖü/videos",
	} {
		if got, err := channelURL(in); got != want || err != nil {
			t.Errorf("%q: %q, %v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"", "@", "@ab", "veritasium", "https://example.org/@veritasium", "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA",
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ", "ftp://youtube.com/@veritasium", "@a/b/../c", "@x y z", "@" + strings.Repeat("a", 31)} {
		if got, err := channelURL(in); err == nil {
			t.Errorf("%q: %q, want an error", in, got)
		}
	}
}

// fakeYtDlp writes a yt-dlp that lists one 10 minute video for any
// youtube.com/@<handle> URL, titled "<handle> Channel", and fails for @gone.
// It appends its arguments to log.
func fakeYtDlp(t *testing.T) (bin, log string) {
	dir := t.TempDir()
	bin, log = filepath.Join(dir, "yt-dlp"), filepath.Join(dir, "log")
	script := `#!/bin/sh
echo "$@" >> ` + log + `
for a; do u=$a; done
case $u in *@gone/*) echo "ERROR: This channel does not exist." >&2; exit 1;; esac
h=${u#*@}; h=${h%%/*}
printf '{"channel": "%s Channel", "title": "%s - Videos", "entries": [{"id": "%.11s", "title": "a video of %s", "duration": 600}]}\n' "$h" "$h" "${h}___________" "$h"
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, log
}

func TestChannels(t *testing.T) {
	bin, ytLog := fakeYtDlp(t)
	s := &server{secret: "s", adminKey: "k", statePath: filepath.Join(t.TempDir(), "state.json"),
		cfg: config{YtDlp: bin, YtDlpArgs: []string{"--proxy", "socks5://proxy"}}}
	call := func(method, path, body, key string) (int, map[string]any) {
		t.Helper()
		req := httptest.NewRequest(method, "/s/"+path, strings.NewReader(body))
		if key != "" {
			req.Header.Set("Authorization", "Bearer "+key)
		}
		rec := httptest.NewRecorder()
		s.handler().ServeHTTP(rec, req)
		var out map[string]any
		json.Unmarshal(rec.Body.Bytes(), &out)
		return rec.Code, out
	}
	// names renders the state as "channels | suggestions" of handles
	names := func() string {
		var cs, ss []string
		for _, c := range s.st.Channels {
			cs = append(cs, strings.TrimSuffix(strings.TrimPrefix(c.URL, "https://www.youtube.com/@"), "/videos"))
		}
		for _, c := range s.st.ChannelSuggestions {
			ss = append(ss, strings.TrimSuffix(strings.TrimPrefix(c.URL, "https://www.youtube.com/@"), "/videos"))
		}
		return strings.Join(cs, ",") + " | " + strings.Join(ss, ",")
	}
	step := func(name, method, path, body, key string, code int, want string) {
		t.Helper()
		got, out := call(method, path, body, key)
		if got != code || names() != want {
			t.Errorf("%s: %d %v, state %q; want %d, %q", name, got, out, names(), code, want)
		}
		if got == http.StatusOK && method == "POST" {
			saved, err := loadState(s.statePath)
			if err != nil || !slices.Equal(saved.Channels, s.st.Channels) || !slices.Equal(saved.ChannelSuggestions, s.st.ChannelSuggestions) || !slices.Equal(saved.RejectedChannels, s.st.RejectedChannels) {
				t.Errorf("%s: saved %+v, %v", name, saved, err)
			}
			if len(out["channels"].([]any)) != len(s.st.Channels) || len(out["suggestions"].([]any)) != len(s.st.ChannelSuggestions) {
				t.Errorf("%s: answer %v is not api/channels", name, out)
			}
		}
		if got != http.StatusOK && out["error"] == "" {
			t.Errorf("%s: no error message in %v", name, out)
		}
	}

	if code, out := call("GET", "api/channels", "", ""); code != http.StatusOK || out["channels"] == nil || out["suggestions"] == nil {
		t.Errorf("empty api/channels: %d %v, want both lists", code, out)
	}
	step("suggest", "POST", "api/channels/suggest", `{"url": "@alpha"}`, "", http.StatusOK, " | alpha")
	if c := s.st.ChannelSuggestions[0]; c.Title != "alpha Channel" || c.At == 0 {
		t.Errorf("suggestion %+v, want yt-dlp's channel title and a time", c)
	}
	step("suggest again", "POST", "api/channels/suggest", `{"url": "https://www.youtube.com/@Alpha/featured"}`, "", http.StatusConflict, " | alpha")
	step("suggest unknown", "POST", "api/channels/suggest", `{"url": "@gone"}`, "", http.StatusBadRequest, " | alpha")
	step("suggest junk", "POST", "api/channels/suggest", `{"url": "nope"}`, "", http.StatusBadRequest, " | alpha")
	step("suggest by GET", "GET", "api/channels/suggest", `{"url": "@beta"}`, "", http.StatusMethodNotAllowed, " | alpha")
	for _, action := range []string{"add", "remove", "approve", "reject"} {
		for _, key := range []string{"", "wrong"} {
			step(action+" without the admin key", "POST", "api/channels/"+action, `{"url": "@alpha"}`, key, http.StatusUnauthorized, " | alpha")
		}
	}
	step("approve", "POST", "api/channels/approve", `{"url": "@alpha"}`, "k", http.StatusOK, "alpha | ")
	step("approve again", "POST", "api/channels/approve", `{"url": "@alpha"}`, "k", http.StatusNotFound, "alpha | ")
	step("suggest a channel", "POST", "api/channels/suggest", `{"url": "@alpha"}`, "", http.StatusConflict, "alpha | ")
	step("add a channel", "POST", "api/channels/add", `{"url": "@ALPHA"}`, "k", http.StatusConflict, "alpha | ")
	step("suggest beta", "POST", "api/channels/suggest", `{"url": "youtube.com/@beta"}`, "", http.StatusOK, "alpha | beta")
	step("suggest gamma", "POST", "api/channels/suggest", `{"url": "/@gamma"}`, "", http.StatusOK, "alpha | beta,gamma")
	step("add a suggestion", "POST", "api/channels/add", `{"url": "https://www.youtube.com/@beta"}`, "k", http.StatusOK, "alpha,beta | gamma")
	step("add unknown", "POST", "api/channels/add", `{"url": "@gone"}`, "k", http.StatusBadRequest, "alpha,beta | gamma")
	step("add", "POST", "api/channels/add", `{"url": "@delta"}`, "k", http.StatusOK, "alpha,beta,delta | gamma")
	step("reject", "POST", "api/channels/reject", `{"url": "@gamma"}`, "k", http.StatusOK, "alpha,beta,delta | ")
	step("reject a channel", "POST", "api/channels/reject", `{"url": "@beta"}`, "k", http.StatusNotFound, "alpha,beta,delta | ")
	step("remove", "POST", "api/channels/remove", `{"url": "@beta"}`, "k", http.StatusOK, "alpha,delta | ")
	step("remove again", "POST", "api/channels/remove", `{"url": "@beta"}`, "k", http.StatusNotFound, "alpha,delta | ")
	step("remove junk", "POST", "api/channels/remove", `{"url": "beta"}`, "k", http.StatusBadRequest, "alpha,delta | ")
	rejected := func(name string, want ...string) {
		t.Helper()
		var got []string
		for _, u := range s.st.RejectedChannels {
			got = append(got, handleOf(u))
		}
		if !slices.Equal(got, want) {
			t.Errorf("%s: rejected %v, want %v", name, got, want)
		}
	}
	rejected("after reject and remove", "@gamma", "@beta")
	step("suggest rejected", "POST", "api/channels/suggest", `{"url": "@Gamma"}`, "", http.StatusConflict, "alpha,delta | ")
	if _, out := call("POST", "api/channels/suggest", `{"url": "youtube.com/@beta/streams"}`, ""); !strings.Contains(fmt.Sprint(out["error"]), "was rejected") {
		t.Errorf("suggesting a removed channel: %v, want \"was rejected\"", out)
	}
	step("add rejected", "POST", "api/channels/add", `{"url": "@GAMMA"}`, "k", http.StatusOK, "alpha,delta,GAMMA | ")
	rejected("after adding gamma", "@beta")
	step("remove gamma", "POST", "api/channels/remove", `{"url": "@gamma"}`, "k", http.StatusOK, "alpha,delta | ")
	step("reject unknown", "POST", "api/channels/reject", `{"url": "@zeta"}`, "k", http.StatusNotFound, "alpha,delta | ")
	rejected("after removing gamma", "@beta", "@GAMMA")

	b, _ := os.ReadFile(ytLog)
	if !strings.Contains(string(b), "--proxy socks5://proxy --flat-playlist --playlist-end 1 -J https://www.youtube.com/@alpha/videos\n") {
		t.Errorf("yt-dlp calls:\n%s", b)
	}

	var full []string
	for i := range maxSuggestions {
		full = append(full, fmt.Sprintf("chan%02d", i))
		step("filling", "POST", "api/channels/suggest", fmt.Sprintf(`{"url": "@chan%02d"}`, i), "", http.StatusOK, "alpha,delta | "+strings.Join(full, ","))
	}
	step("full", "POST", "api/channels/suggest", `{"url": "@onemore"}`, "", http.StatusTooManyRequests, "alpha,delta | "+strings.Join(full, ","))
	// the admin still adds directly
	step("add while full", "POST", "api/channels/add", `{"url": "@onemore"}`, "k", http.StatusOK, "alpha,delta,onemore | "+strings.Join(full, ","))
	step("approve while full", "POST", "api/channels/approve", `{"url": "@chan00"}`, "k", http.StatusOK, "alpha,delta,onemore,chan00 | "+strings.Join(full[1:], ","))
	step("suggest after approving", "POST", "api/channels/suggest", `{"url": "@epsilon"}`, "", http.StatusOK, "alpha,delta,onemore,chan00 | "+strings.Join(append(full[1:], "epsilon"), ","))
}

func TestPickUsesStateChannels(t *testing.T) {
	bin, _ := fakeYtDlp(t)
	s := &server{secret: "s", adminKey: "k", statePath: filepath.Join(t.TempDir(), "state.json"), lookAhead: time.Hour,
		cfg: config{YtDlp: bin, YouTubeVideosPerChannel: 30},
		st:  state{Channels: []channel{{URL: "https://www.youtube.com/@alpha/videos", Title: "alpha Channel"}}},
		ytLists: map[string]ytList{"https://www.youtube.com/@old/videos": {fetched: time.Now(),
			videos: []candidate{{ID: "yt:old________", Kind: "youtube", Title: "old", Group: "old Channel", Duration: 600}}}}}
	groups := func() []string {
		var gs []string
		for _, c := range s.pick(t.Context()) {
			gs = append(gs, c.Group)
		}
		slices.Sort(gs)
		return gs
	}
	if got := groups(); !reflect.DeepEqual(got, []string{"alpha Channel"}) {
		t.Errorf("picks from %v, want only the state's channel", got)
	}
	if _, ok := s.ytLists["https://www.youtube.com/@old/videos"]; ok || len(s.ytLists) != 1 {
		t.Errorf("lists %v, want the removed channel gone", s.ytLists)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/s/api/channels/add", strings.NewReader(`{"url": "@beta"}`))
	req.Header.Set("Authorization", "Bearer k")
	s.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("adding: %d %s", rec.Code, rec.Body)
	}
	if got := groups(); !reflect.DeepEqual(got, []string{"alpha Channel", "beta Channel"}) {
		t.Errorf("picks from %v after adding beta", got)
	}
	s.st.Channels = nil
	if got := groups(); got != nil || len(s.ytLists) != 0 {
		t.Errorf("without channels: picks from %v, lists %v", got, s.ytLists)
	}
}

func TestChannelsDue(t *testing.T) {
	const day = int64(24 * time.Hour / time.Millisecond)
	now := 100 * day
	for _, tc := range []struct {
		name             string
		suggested, tried int64
		want             bool
	}{
		{"never", 0, 0, true},
		{"6 days ago", now - 6*day, now - 6*day, false},
		{"7 days ago", now - 7*day, now - 7*day, true},
		{"8 days ago, failed an hour ago", now - 8*day, now - day/24, false},
		{"never, failed an hour ago", 0, now - day/24, false},
		{"8 days ago, failed a day ago", now - 8*day, now - day, true},
	} {
		st := state{ChannelsSuggestedAt: tc.suggested, ChannelsSuggestTriedAt: tc.tried}
		if got := st.channelsDue(now); got != tc.want {
			t.Errorf("%s: due %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestRejectedCap(t *testing.T) {
	var st state
	for i := range maxRejected + 5 {
		st.reject(fmt.Sprintf("https://www.youtube.com/@ch%03d/videos", i))
	}
	st.reject("https://www.youtube.com/@CH010/videos")
	if len(st.RejectedChannels) != maxRejected || handleOf(st.RejectedChannels[0]) != "@ch005" || handleOf(st.RejectedChannels[maxRejected-1]) != "@CH010" {
		t.Errorf("%d rejected from %s to %s, want %d from @ch005 to @CH010", len(st.RejectedChannels),
			st.RejectedChannels[0], st.RejectedChannels[len(st.RejectedChannels)-1], maxRejected)
	}
	if st.rejected("https://www.youtube.com/@ch004/videos") || !st.rejected("https://www.youtube.com/@Ch204/videos") || slices.Contains(st.RejectedChannels, "https://www.youtube.com/@ch010/videos") {
		t.Errorf("forgot the wrong ones: %v", st.RejectedChannels)
	}
}

func TestSuggestChannels(t *testing.T) {
	bin, ytLog := fakeYtDlp(t)
	var prompts []string
	answer := ""
	llm := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages []struct{ Content string }
		}
		json.NewDecoder(r.Body).Decode(&req)
		prompts = append(prompts, req.Messages[0].Content+"\n"+req.Messages[1].Content)
		if answer == "" {
			http.Error(w, "overloaded", http.StatusServiceUnavailable)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": answer}}}})
	}))
	defer llm.Close()
	ch := func(h string) channel {
		return channel{URL: "https://www.youtube.com/@" + h + "/videos", Title: h + " Channel", At: 1}
	}
	s := &server{statePath: filepath.Join(t.TempDir(), "state.json"),
		cfg: config{YtDlp: bin, LLMURL: llm.URL, ChannelSuggestionsPerWeek: 3},
		st: state{Channels: []channel{ch("alpha"), ch("beta")}, ChannelSuggestions: []channel{ch("pend")},
			RejectedChannels: []string{"https://www.youtube.com/@nope/videos"}}}
	suggested := func() string {
		var out []string
		for _, c := range s.st.ChannelSuggestions {
			out = append(out, handleOf(c.URL)+":"+c.By)
		}
		return strings.Join(out, ",")
	}
	ytCalls := func() string {
		b, _ := os.ReadFile(ytLog)
		return string(b)
	}

	answer = "```json\n" + `{"channels": ["@gone", "not a handle!", "@Alpha", "@pend", "@NOPE", "@new1", "@NEW1",
		"https://www.youtube.com/@new2", "@new3", "@new4"]}` + "\n```"
	before := nowMs()
	s.suggestChannels(t.Context())
	if len(prompts) != 1 {
		t.Fatalf("%d llm calls, want 1", len(prompts))
	}
	for _, want := range []string{"Suggest 6 more", "alpha Channel | @alpha\nbeta Channel | @beta\n", "Already suggested:\npend Channel | @pend\n", "Rejected before:\n@nope\n", `{"channels": ["@handle", ...]}`} {
		if !strings.Contains(prompts[0], want) {
			t.Errorf("prompt lacks %q:\n%s", want, prompts[0])
		}
	}
	if got := suggested(); got != "@pend:,@new1:llm,@new2:llm,@new3:llm" {
		t.Errorf("suggestions %s, want pend and new1-3 by llm", got)
	}
	if c := s.st.ChannelSuggestions[1]; c.Title != "new1 Channel" || c.At < before {
		t.Errorf("llm suggestion %+v, want yt-dlp's title and a time", c)
	}
	if calls := ytCalls(); !strings.Contains(calls, "@gone/") || strings.Contains(calls, "@new4/") || strings.Contains(calls, "@nope/") || strings.Contains(calls, "@alpha/") {
		t.Errorf("yt-dlp calls:\n%s", calls)
	}
	if s.st.ChannelsSuggestedAt < before {
		t.Errorf("run not marked: %d", s.st.ChannelsSuggestedAt)
	}
	if saved, err := loadState(s.statePath); err != nil || !slices.Equal(saved.ChannelSuggestions, s.st.ChannelSuggestions) || saved.ChannelsSuggestedAt != s.st.ChannelsSuggestedAt {
		t.Errorf("saved %+v, %v", saved, err)
	}

	// within the week nothing happens
	s.suggestChannels(t.Context())
	if len(prompts) != 1 {
		t.Errorf("asked again within the week")
	}

	// a week later the LLM fails: not marked as run, no retry the same day
	week := (7 * 24 * time.Hour).Milliseconds()
	s.st.ChannelsSuggestedAt -= week
	s.st.ChannelsSuggestTriedAt -= week
	lastRun := s.st.ChannelsSuggestedAt
	answer = ""
	s.suggestChannels(t.Context())
	s.suggestChannels(t.Context())
	if len(prompts) != 2 || s.st.ChannelsSuggestedAt != lastRun {
		t.Errorf("llm failure: %d llm calls, suggested at %d; want 2 and %d", len(prompts), s.st.ChannelsSuggestedAt, lastRun)
	}
	// an answer without JSON counts as a failure too, a day later
	s.st.ChannelsSuggestTriedAt -= (24 * time.Hour).Milliseconds()
	answer = "I cannot browse YouTube."
	s.suggestChannels(t.Context())
	if len(prompts) != 3 || s.st.ChannelsSuggestedAt != lastRun {
		t.Errorf("answer without JSON: %d llm calls, suggested at %d; want 3 and %d", len(prompts), s.st.ChannelsSuggestedAt, lastRun)
	}

	// the next day nothing valid comes back: marked as run anyway
	s.st.ChannelsSuggestTriedAt -= (24 * time.Hour).Milliseconds()
	answer = `{"channels": ["@gone", "@new1", "@beta"]}`
	s.suggestChannels(t.Context())
	if len(prompts) != 4 || s.st.ChannelsSuggestedAt == lastRun || suggested() != "@pend:,@new1:llm,@new2:llm,@new3:llm" {
		t.Errorf("nothing valid: %d llm calls, suggested at %d, suggestions %s", len(prompts), s.st.ChannelsSuggestedAt, suggested())
	}

	// the suggestion cap holds and stops the run
	for i := len(s.st.ChannelSuggestions); i < maxSuggestions-1; i++ {
		s.st.ChannelSuggestions = append(s.st.ChannelSuggestions, ch(fmt.Sprintf("fill%02d", i)))
	}
	s.st.ChannelsSuggestedAt -= week
	s.st.ChannelsSuggestTriedAt -= week
	answer = `{"channels": ["@cap1", "@cap2", "@cap3"]}`
	s.suggestChannels(t.Context())
	if n := len(s.st.ChannelSuggestions); n != maxSuggestions || handleOf(s.st.ChannelSuggestions[n-1].URL) != "@cap1" {
		t.Errorf("%d suggestions ending in %s, want %d ending in @cap1", n, s.st.ChannelSuggestions[n-1].URL, maxSuggestions)
	}
	if strings.Contains(ytCalls(), "@cap2/") {
		t.Errorf("checked @cap2 with the suggestions full")
	}
}

func TestAudioStream(t *testing.T) {
	var p probe
	if err := json.Unmarshal([]byte(`{"streams": [
		{"index": 0, "codec_type": "video"},
		{"index": 3, "codec_type": "audio", "tags": {"language": "ita"}},
		{"index": 5, "codec_type": "audio", "tags": {"language": "eng"}},
		{"index": 6, "codec_type": "subtitle", "tags": {"language": "ger"}}]}`), &p); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		langs []string
		want  string
	}{{[]string{"en", "de"}, "0:5"}, {[]string{"de", "en"}, "0:5"}, {[]string{"de"}, "0:3"}, {nil, "0:3"}} {
		if got := p.audioStream(c.langs); got != c.want {
			t.Errorf("audioStream(%v) = %q, want %q", c.langs, got, c.want)
		}
	}
	if got := (probe{}).audioStream([]string{"en"}); got != "" {
		t.Errorf("no audio: %q", got)
	}
}

func TestCovered(t *testing.T) {
	h := time.Hour.Milliseconds()
	movie := entry{Start: 0, Duration: 4 * h}
	if covered([]entry{movie}, h, 3*time.Hour) {
		t.Error("a lone item past the look-ahead must still get a successor")
	}
	if !covered([]entry{movie, {Start: 4 * h, Duration: h}}, h, 3*time.Hour) {
		t.Error("two items past the look-ahead are enough")
	}
	if covered([]entry{{Start: 0, Duration: h}, {Start: h, Duration: h}}, 0, 3*time.Hour) {
		t.Error("two hours do not fill three")
	}
}

func TestUnderstandable(t *testing.T) {
	en := []string{"en"}
	for _, c := range []struct {
		name    string
		streams []mediaStream
		langs   []string
		want    bool
	}{
		{"english audio", []mediaStream{{Type: "Audio", Language: "eng"}}, en, true},
		{"untagged audio", []mediaStream{{Type: "Audio"}}, en, true},
		{"english text sub", []mediaStream{{Type: "Audio", Language: "kor"}, {Type: "Subtitle", Language: "eng", IsTextSubtitleStream: true}}, en, true},
		{"english image sub only", []mediaStream{{Type: "Audio", Language: "kor"}, {Type: "Subtitle", Language: "eng"}, {Type: "Subtitle", Language: "ger", IsTextSubtitleStream: true}}, en, false},
		{"no stream info", nil, en, true},
		{"no filter", []mediaStream{{Type: "Audio", Language: "kor"}}, nil, true},
	} {
		if got := understandable(c.streams, c.langs); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}
