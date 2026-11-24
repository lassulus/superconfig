package main

// The API for clients without a browser (agents): with a bearer token from
// the API tokens file they create sessions, list them with their links,
// rename and kill them, at /api/sessions. A token sees only the sessions it
// created. These belong to the API owner (an OIDC sub) as well, whose page
// shows them marked with the token's name, so he can watch, move and kill
// them; the token can do nothing with his other sessions. A token is no
// login: the page and its forms still want the OIDC login.
//
// With `Authorization: Bearer <token>`, JSON in and out:
//
//	GET    /api/sessions       the token's sessions: id, name, host, state
//	                           (running/stopped), created, control, view and
//	                           mcp links
//	POST   /api/sessions       {"name": ..., "host": ...}, both optional;
//	                           without a host the page's default, the first
//	                           host by name. 201 with the session as GET
//	                           lists it, 503 when the host is full
//	PATCH  /api/sessions/<id>  {"name": ...}, "" removes it
//	DELETE /api/sessions/<id>  204; 404 for a session the token did not create
//
// Errors are {"error": ...}; 401 without a valid token.

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
)

// apiToken is a line `<name> <sha256 of the token in hex>` of the API
// tokens file, the format of agentd's auth.tokensFile.
type apiToken struct {
	name string
	hash []byte
}

func readAPITokens(path string) ([]apiToken, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var tokens []apiToken
	names := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(b))
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		var hash []byte
		if len(fields) == 2 {
			hash, err = hex.DecodeString(fields[1])
		}
		if len(fields) != 2 || err != nil || len(hash) != sha256.Size {
			return nil, fmt.Errorf("%s:%d: want <name> <sha256 in hex>", path, n)
		}
		if names[fields[0]] {
			return nil, fmt.Errorf("%s:%d: token name %q twice", path, n, fields[0])
		}
		names[fields[0]] = true
		tokens = append(tokens, apiToken{name: fields[0], hash: hash})
	}
	return tokens, sc.Err()
}

// apiClient returns the name of the API token in the request's
// Authorization header, or "". It compares the token's hash against every
// configured one in constant time.
func (s *server) apiClient(r *http.Request) string {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return ""
	}
	h := hashToken(token)
	name := ""
	for _, t := range s.apiTokens {
		if subtle.ConstantTimeCompare(h, t.hash) == 1 {
			name = t.name
		}
	}
	return name
}

func apiJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func apiError(w http.ResponseWriter, status int, msg string) {
	apiJSON(w, status, map[string]string{"error": msg})
}

// api wraps a handler that needs a valid API token, and gets its name.
func (s *server) api(h func(w http.ResponseWriter, r *http.Request, client string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		client := s.apiClient(r)
		if client == "" {
			w.Header().Set("WWW-Authenticate", "Bearer")
			apiError(w, http.StatusUnauthorized, "needs a valid API token")
			return
		}
		h(w, r, client)
	}
}

// apiSessions are the sessions client created, as the owner's page shows
// them.
func (s *server) apiSessions(client string) []sessionInfo {
	out := []sessionInfo{}
	for _, se := range s.list(s.cfg.APIOwner) {
		if se.CreatedBy == client {
			out = append(out, se)
		}
	}
	return out
}

// apiOwned tells whether client created the session id.
func (s *server) apiOwned(id, client string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	se, ok := s.owned(id, s.cfg.APIOwner)
	return ok && se.CreatedBy == client
}

// apiRequest is the body of a create (name and host, both optional) or a
// rename (name; "" removes it).
type apiRequest struct {
	Name string `json:"name"`
	Host string `json:"host"`
}

func readAPIRequest(r *http.Request) (apiRequest, error) {
	var req apiRequest
	err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&req)
	if errors.Is(err, io.EOF) {
		err = nil
	}
	return req, err
}

func (s *server) apiInfo(client, id string) (sessionInfo, bool) {
	for _, se := range s.apiSessions(client) {
		if se.ID == id {
			return se, true
		}
	}
	return sessionInfo{}, false
}

func (s *server) handleAPIList(w http.ResponseWriter, r *http.Request, client string) {
	apiJSON(w, http.StatusOK, s.apiSessions(client))
}

// handleAPICreate creates a session on the requested host, or on the
// page's default one, and answers with it and its links.
func (s *server) handleAPICreate(w http.ResponseWriter, r *http.Request, client string) {
	req, err := readAPIRequest(r)
	if err != nil {
		apiError(w, http.StatusBadRequest, "body: "+err.Error())
		return
	}
	if req.Host == "" {
		// the first option of the page's host dropdown
		req.Host = s.hosts()[0]
	}
	se, _, _, err := s.create(s.cfg.APIOwner, req.Name, req.Host, "", client)
	if err != nil {
		status := http.StatusInternalServerError
		switch {
		case errors.Is(err, errFull):
			status = http.StatusServiceUnavailable
		case errors.Is(err, errName), errors.Is(err, errHost):
			status = http.StatusBadRequest
		default:
			log.Printf("api %s: create: %v", client, err)
		}
		apiError(w, status, err.Error())
		return
	}
	log.Printf("session %s: created by API token %s", se.ID, client)
	info, ok := s.apiInfo(client, se.ID)
	if !ok {
		// killed in the meantime
		apiError(w, http.StatusNotFound, "the session is gone")
		return
	}
	apiJSON(w, http.StatusCreated, info)
}

func (s *server) handleAPIRename(w http.ResponseWriter, r *http.Request, client string) {
	id := r.PathValue("id")
	if !s.apiOwned(id, client) {
		apiError(w, http.StatusNotFound, "no such session")
		return
	}
	req, err := readAPIRequest(r)
	if err != nil {
		apiError(w, http.StatusBadRequest, "body: "+err.Error())
		return
	}
	err = s.rename(id, s.cfg.APIOwner, req.Name)
	switch {
	case errors.Is(err, os.ErrNotExist):
		apiError(w, http.StatusNotFound, "no such session")
	case errors.Is(err, errName):
		apiError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		log.Printf("api %s: rename: %v", client, err)
		apiError(w, http.StatusInternalServerError, err.Error())
	default:
		info, _ := s.apiInfo(client, id)
		apiJSON(w, http.StatusOK, info)
	}
}

func (s *server) handleAPIKill(w http.ResponseWriter, r *http.Request, client string) {
	id := r.PathValue("id")
	if !s.apiOwned(id, client) {
		apiError(w, http.StatusNotFound, "no such session")
		return
	}
	err := s.kill(id, s.cfg.APIOwner)
	switch {
	case errors.Is(err, os.ErrNotExist):
		apiError(w, http.StatusNotFound, "no such session")
	case err != nil:
		log.Printf("api %s: kill: %v", client, err)
		apiError(w, http.StatusInternalServerError, err.Error())
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
