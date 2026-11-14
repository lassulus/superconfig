package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

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
