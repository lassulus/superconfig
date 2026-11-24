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
	mux.HandleFunc("POST /sessions/{id}/rename", s.handleRename)
	mux.HandleFunc("POST /sessions/{id}/kill", s.handleKill)
	mux.HandleFunc("/s/{token}", s.handleSession)
	mux.HandleFunc("/s/{token}/{rest...}", s.handleSession)
	return mux
}

// links are the links of a session; an empty one is a token from before
// the tokens were kept, until it is regenerated.
type links struct {
	ID      string `json:"id"`
	Control string `json:"control,omitempty"`
	MCP     string `json:"mcp,omitempty"`
	View    string `json:"view,omitempty"`
}

type sessionInfo struct {
	links
	Host      string    `json:"host"`
	Name      string    `json:"name,omitempty"`
	Created   time.Time `json:"created"`
	Connected bool      `json:"connected"`
}

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Browser sessions</title>
<style>body{font-family:sans-serif;max-width:50em;margin:2em auto;padding:0 1em}form{display:inline}section{border-top:1px solid #ccc;margin-top:1em}code{word-break:break-all}small{color:#666}</style>
</head><body>
<h1>Browser sessions</h1>
{{if not .Owner}}<p><a href="/login">Log in</a> to create sessions.</p>{{else}}
{{if .Error}}<p><strong>{{.Error}}</strong></p>{{end}}
<form method="post" action="/sessions"><input name="name" maxlength="{{.MaxName}}" placeholder="Name (optional)">
{{if gt (len .Hosts) 1}}<select name="host">{{range .Hosts}}<option>{{.}}</option>{{end}}</select>{{end}} <button>New session</button></form>
<form method="post" action="/logout"><button>Log out</button></form>
{{range .Sessions}}<section>
<h2>{{if .Name}}{{.Name}} <small>{{.ID}}</small>{{else}}{{.ID}}{{end}}</h2>
<p>On {{.Host}}, created {{.Created.Format "2006-01-02 15:04"}}{{if .Connected}}, connected{{end}}</p>
<ul>
<li>View only: {{if .View}}<a href="{{.View}}"><code>{{.View}}</code></a>{{else}}link not stored, regenerate to show{{end}}
<form method="post" action="/sessions/{{.ID}}/regenerate/view"><button>New view link</button></form></li>
<li>Control: {{if .Control}}<a href="{{.Control}}"><code>{{.Control}}</code></a>{{else}}link not stored, regenerate to show{{end}}
<form method="post" action="/sessions/{{.ID}}/regenerate/control"><button>New control link</button></form></li>
{{if .MCP}}<li>MCP (streamable HTTP): <code>{{.MCP}}</code></li>{{end}}
</ul>
<form method="post" action="/sessions/{{.ID}}/rename"><input name="name" value="{{.Name}}" maxlength="{{$.MaxName}}" placeholder="Name"> <button>Rename</button></form>
<form method="post" action="/sessions/{{.ID}}/kill"><button>Kill</button></form>
</section>{{end}}
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
		if se.Owner == sub && !se.starting {
			out = append(out, sessionInfo{
				links:     *s.links(se.ID, se.ControlToken, se.ViewToken),
				Host:      se.Host,
				Name:      se.Name,
				Created:   se.Created,
				Connected: se.active > 0,
			})
		}
	}
	slices.SortFunc(out, func(a, b sessionInfo) int { return a.Created.Compare(b.Created) })
	return out
}

// render answers with JSON v, or the page with the owner's sessions.
func (s *server) render(w http.ResponseWriter, r *http.Request, status int, sub string, errMsg string, v any) {
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
	err := page.Execute(w, map[string]any{"Owner": sub, "Error": errMsg, "Sessions": s.list(sub), "Hosts": s.hosts(), "MaxName": maxName})
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
	s.render(w, r, http.StatusOK, sub, "", s.list(sub))
}

// done answers a successful change with JSON v (no content if nil), or
// sends the browser back to the page.
func done(w http.ResponseWriter, r *http.Request, status int, v any) {
	if !wantsJSON(r) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if v == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
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
	se, control, view, err := s.create(sub, r.FormValue("name"), r.FormValue("host"))
	if err != nil {
		status := http.StatusInternalServerError
		switch {
		case errors.Is(err, errFull):
			status = http.StatusServiceUnavailable
		case errors.Is(err, errName), errors.Is(err, errHost):
			status = http.StatusBadRequest
		default:
			log.Printf("create: %v", err)
		}
		s.render(w, r, status, sub, err.Error(), nil)
		return
	}
	done(w, r, http.StatusCreated, s.links(se.ID, control, view))
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
		s.render(w, r, http.StatusInternalServerError, sub, err.Error(), nil)
		return
	}
	l := s.links(id, "", token)
	if ro == controller {
		l = s.links(id, token, "")
	}
	done(w, r, http.StatusOK, l)
}

func (s *server) handleRename(w http.ResponseWriter, r *http.Request) {
	sub := s.owner(r)
	if sub == "" {
		http.Error(w, "log in first", http.StatusUnauthorized)
		return
	}
	err := s.rename(r.PathValue("id"), sub, r.FormValue("name"))
	if errors.Is(err, os.ErrNotExist) {
		http.NotFound(w, r)
		return
	}
	if errors.Is(err, errName) {
		s.render(w, r, http.StatusBadRequest, sub, err.Error(), nil)
		return
	}
	if err != nil {
		log.Printf("rename: %v", err)
		s.render(w, r, http.StatusInternalServerError, sub, err.Error(), nil)
		return
	}
	done(w, r, http.StatusOK, nil)
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
		s.render(w, r, http.StatusInternalServerError, sub, err.Error(), nil)
		return
	}
	done(w, r, http.StatusOK, nil)
}
