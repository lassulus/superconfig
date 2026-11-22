package main

import (
	"encoding/json"
	"errors"
	"html/template"
	"log"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
)

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", s.handleIndex)
	mux.HandleFunc("GET /login", s.handleLogin)
	mux.HandleFunc("GET /callback", s.handleCallback)
	mux.HandleFunc("POST /logout", s.handleLogout)
	mux.HandleFunc("POST /sessions", s.handleCreate)
	mux.HandleFunc("POST /sessions/{id}/regenerate/{role}", s.handleRegenerate)
	mux.HandleFunc("POST /sessions/{id}/kill", s.handleKill)
	mux.HandleFunc("/s/{token}", s.handleSession)
	mux.HandleFunc("/s/{token}/{rest...}", s.handleSession)
	return mux
}

// links are the new links of a session after creating it or regenerating a
// token; only these responses show tokens.
type links struct {
	ID      string `json:"id"`
	Control string `json:"control,omitempty"`
	MCP     string `json:"mcp,omitempty"`
	View    string `json:"view,omitempty"`
}

type sessionInfo struct {
	ID        string    `json:"id"`
	Created   time.Time `json:"created"`
	Connected bool      `json:"connected"`
}

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Browser sessions</title>
<style>body{font-family:sans-serif;max-width:50em;margin:2em auto;padding:0 1em}form{display:inline}td,th{padding:.2em .6em;text-align:left}code{word-break:break-all}</style>
</head><body>
<h1>Browser sessions</h1>
{{if not .Owner}}<p><a href="/login">Log in</a> to create sessions.</p>{{else}}
{{with .Links}}<p>Links of session {{.ID}}; they are shown only now:</p><ul>
{{if .Control}}<li>Control: <a href="{{.Control}}"><code>{{.Control}}</code></a></li>
<li>MCP (streamable HTTP): <code>{{.MCP}}</code></li>{{end}}
{{if .View}}<li>View only: <a href="{{.View}}"><code>{{.View}}</code></a></li>{{end}}
</ul>{{end}}
{{if .Error}}<p><strong>{{.Error}}</strong></p>{{end}}
<form method="post" action="/sessions"><button>New session</button></form>
<form method="post" action="/logout"><button>Log out</button></form>
{{if .Sessions}}<table><tr><th>Session</th><th>Created</th><th></th><th></th></tr>
{{range .Sessions}}<tr><td>{{.ID}}</td><td>{{.Created.Format "2006-01-02 15:04"}}</td>
<td>{{if .Connected}}connected{{end}}</td><td>
<form method="post" action="/sessions/{{.ID}}/regenerate/control"><button>New control link</button></form>
<form method="post" action="/sessions/{{.ID}}/regenerate/view"><button>New view link</button></form>
<form method="post" action="/sessions/{{.ID}}/kill"><button>Kill</button></form>
</td></tr>{{end}}</table>{{end}}
{{end}}
</body></html>
`))

func wantsJSON(r *http.Request) bool {
	return strings.Contains(r.Header.Get("Accept"), "application/json")
}

func (s *server) list(sub string) []sessionInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []sessionInfo
	for _, se := range s.sessions {
		if se.Owner == sub {
			out = append(out, sessionInfo{ID: se.ID, Created: se.Created, Connected: se.active > 0})
		}
	}
	slices.SortFunc(out, func(a, b sessionInfo) int { return a.Created.Compare(b.Created) })
	return out
}

// render answers with JSON v, or the page with the owner's sessions.
func (s *server) render(w http.ResponseWriter, r *http.Request, status int, sub string, l *links, errMsg string, v any) {
	if wantsJSON(r) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if errMsg != "" {
			v = map[string]string{"error": errMsg}
		}
		json.NewEncoder(w).Encode(v)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	err := page.Execute(w, map[string]any{"Owner": sub, "Links": l, "Error": errMsg, "Sessions": s.list(sub)})
	if err != nil {
		log.Printf("page: %v", err)
	}
}

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	sub := s.owner(r)
	if sub == "" && wantsJSON(r) {
		http.Error(w, "log in first", http.StatusUnauthorized)
		return
	}
	s.render(w, r, http.StatusOK, sub, nil, "", s.list(sub))
}

func (s *server) links(id, control, view string) *links {
	l := &links{ID: id}
	if control != "" {
		l.Control = s.cfg.URL + "/s/" + control + "/"
		l.MCP = s.cfg.URL + "/s/" + control + "/mcp"
	}
	if view != "" {
		l.View = s.cfg.URL + "/s/" + view + "/"
	}
	return l
}

func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	sub := s.owner(r)
	if sub == "" {
		http.Error(w, "log in first", http.StatusUnauthorized)
		return
	}
	se, control, view, err := s.create(sub)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, errFull) {
			status = http.StatusServiceUnavailable
		} else {
			log.Printf("create: %v", err)
		}
		s.render(w, r, status, sub, nil, err.Error(), nil)
		return
	}
	l := s.links(se.ID, control, view)
	s.render(w, r, http.StatusCreated, sub, l, "", l)
}

func (s *server) handleRegenerate(w http.ResponseWriter, r *http.Request) {
	sub := s.owner(r)
	if sub == "" {
		http.Error(w, "log in first", http.StatusUnauthorized)
		return
	}
	id := r.PathValue("id")
	var ro role
	switch r.PathValue("role") {
	case "control":
		ro = controller
	case "view":
		ro = viewer
	default:
		http.NotFound(w, r)
		return
	}
	token, err := s.regenerate(id, sub, ro)
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("regenerate: %v", err)
		s.render(w, r, http.StatusInternalServerError, sub, nil, err.Error(), nil)
		return
	}
	l := s.links(id, "", token)
	if ro == controller {
		l = s.links(id, token, "")
	}
	s.render(w, r, http.StatusOK, sub, l, "", l)
}

func (s *server) handleKill(w http.ResponseWriter, r *http.Request) {
	sub := s.owner(r)
	if sub == "" {
		http.Error(w, "log in first", http.StatusUnauthorized)
		return
	}
	err := s.kill(r.PathValue("id"), sub)
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		log.Printf("kill: %v", err)
		s.render(w, r, http.StatusInternalServerError, sub, nil, err.Error(), nil)
		return
	}
	if wantsJSON(r) {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	http.Redirect(w, r, "/", http.StatusSeeOther)
}
