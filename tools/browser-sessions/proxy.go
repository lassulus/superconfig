package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var tokenPath = regexp.MustCompile(`/s/[^/?\s]+`)

// mask hides session tokens in paths and log lines.
func mask(s string) string { return tokenPath.ReplaceAllString(s, "/s/***") }

// maskWriter masks tokens in everything net/http logs.
type maskWriter struct{ w io.Writer }

func (m maskWriter) Write(p []byte) (int, error) {
	if _, err := m.w.Write([]byte(mask(string(p)))); err != nil {
		return 0, err
	}
	return len(p), nil
}

// handleSession serves /s/<token>/...: the session's neko for both roles,
// and its MCP endpoint at /s/<token>/mcp for the control token only.
func (s *server) handleSession(w http.ResponseWriter, r *http.Request) {
	token := r.PathValue("token")
	rest := "/" + r.PathValue("rest")
	se, role, ok := s.lookup(token)
	if !ok {
		http.NotFound(w, r)
		return
	}
	// every request counts as activity, the redirects too
	defer s.touch(se)()
	if r.PathValue("rest") == "" && r.URL.Path == "/s/"+token {
		http.Redirect(w, r, "/s/"+token+"/", http.StatusFound)
		return
	}
	// the neko client logs in straight away with ?usr=&pwd=; the gateway
	// replaces the password with the role's (proxyNeko)
	if rest == "/" && r.Method == http.MethodGet && !r.URL.Query().Has("usr") {
		http.Redirect(w, r, "/s/"+token+"/?"+url.Values{"usr": {role.String()}, "pwd": {"-"}}.Encode(), http.StatusFound)
		return
	}
	if rest == "/mcp" && role != controller {
		http.Error(w, "the view token has no MCP access", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	ready := se.ready
	s.mu.Unlock()
	if !ready {
		// a browser opening the session gets a page that reloads itself
		// until it answers; everything else waits for it
		if r.Method == http.MethodGet && strings.Contains(r.Header.Get("Accept"), "text/html") {
			s.wakeInBackground(se)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Retry-After", "2")
			w.WriteHeader(http.StatusServiceUnavailable)
			io.WriteString(w, wakingPage)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), wakeTimeout)
		err := s.ensureUp(ctx, se)
		cancel()
		if err != nil {
			log.Printf("session %s: start: %v", se.ID, err)
			http.Error(w, "the session is starting and did not answer in time; try again", http.StatusServiceUnavailable)
			return
		}
	}
	s.mu.Lock()
	at := se.at()
	roleCtx := se.ctx[role]
	controlPassword, viewPassword, mcpToken := se.ControlPassword, se.ViewPassword, se.MCPToken
	s.mu.Unlock()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer context.AfterFunc(roleCtx, cancel)()
	r = r.WithContext(ctx)

	if rest == "/mcp" {
		// browser-mcp only accepts its own address as Origin; the token in
		// the path is the authorization
		s.proxy(at, "/mcp", func(out *http.Request) {
			out.Header.Set("Authorization", "Bearer "+mcpToken)
			out.Header.Del("Origin")
		}).ServeHTTP(w, r)
		return
	}
	if rest == "/api/login" && r.Method == http.MethodPost {
		password := viewPassword
		if role == controller {
			password = controlPassword
		}
		if err := setLoginPassword(r, password); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	s.proxy(at, "/neko"+rest, nil).ServeHTTP(w, r)
}

// wakingPage stands in for a session that is being started.
const wakingPage = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<meta http-equiv="refresh" content="2"><title>Waking up</title>
<style>body{font-family:sans-serif;max-width:50em;margin:2em auto;padding:0 1em}</style>
</head><body><p>Waking up the browser session, one moment…</p></body></html>
`

// setLoginPassword replaces the password of a neko login request.
func setLoginPassword(r *http.Request, password string) error {
	var body map[string]any
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&body); err != nil {
		return fmt.Errorf("login: %w", err)
	}
	body["password"] = password
	b, _ := json.Marshal(body)
	r.Body = io.NopCloser(bytes.NewReader(b))
	r.ContentLength = int64(len(b))
	r.Header.Set("Content-Length", strconv.Itoa(len(b)))
	return nil
}

// proxy forwards to rest in p's slot on its host's backend, with the
// backend token and without the gateway's cookies; edit may change the
// outgoing request further.
func (s *server) proxy(p place, rest string, edit func(*http.Request)) http.Handler {
	return forward(s.backends[p.host], p.path(rest), func(out *http.Request) {
		out.Header.Del("Cookie")
		out.Header.Set(tokenHeader, s.token)
		if edit != nil {
			edit(out)
		}
	})
}
