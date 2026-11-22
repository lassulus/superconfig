package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strconv"
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
	s.mu.Lock()
	sl := s.cfg.Slots[se.Slot]
	roleCtx := se.ctx[role]
	controlPassword, viewPassword, mcpToken := se.ControlPassword, se.ViewPassword, se.MCPToken
	s.mu.Unlock()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	defer context.AfterFunc(roleCtx, cancel)()
	defer s.touch(se)()
	r = r.WithContext(ctx)

	if rest == "/mcp" {
		if role != controller {
			http.Error(w, "the view token has no MCP access", http.StatusForbidden)
			return
		}
		// browser-mcp only accepts its own address as Origin; the token in
		// the path is the authorization
		proxy(sl.MCP, rest, func(out *http.Request) {
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
	proxy(sl.Neko, rest, nil).ServeHTTP(w, r)
}

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

// proxy forwards to path on a localhost port, without the gateway's
// cookies; edit may change the outgoing request further.
func proxy(port int, path string, edit func(*http.Request)) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(&url.URL{Scheme: "http", Host: "127.0.0.1:" + strconv.Itoa(port)})
			pr.Out.URL.Path, pr.Out.URL.RawPath = path, ""
			pr.Out.Header.Del("Cookie")
			pr.SetXForwarded()
			if edit != nil {
				edit(pr.Out)
			}
		},
		// MCP answers as server-sent events
		FlushInterval: -1,
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Printf("proxy %s %s: %s", r.Method, mask(r.URL.Path), mask(err.Error()))
			w.WriteHeader(http.StatusBadGateway)
		},
	}
}
