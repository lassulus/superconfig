// browser-sessions: shared sandboxed browser sessions. A logged-in owner
// creates sessions on the management page and picks the host each runs on;
// each session runs in a systemd unit (neko + Firefox + browser-mcp) on a
// fixed slot of ports there, and two random tokens give access to it:
// /s/<control>/ (watch and control, MCP at /s/<control>/mcp) and /s/<view>/
// (watch only). The page shows the owner both links of every session. A
// session lasts until its owner kills it.
//
// The gateway (this file, page.go, auth.go, proxy.go) holds the page, the
// login and the sessions with their tokens, and knows which host and slot
// each runs in. The hosts run the backend (backend.go), which starts and
// removes the units and passes the gateway's requests on to them.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

type config struct {
	Listen string `json:"listen"`
	// public base URL of the gateway, without a trailing slash
	URL              string `json:"url"`
	StateDir         string `json:"state_dir"`
	OIDCIssuer       string `json:"oidc_issuer"`
	OIDCClientIDFile string `json:"oidc_client_id_file"`
	// token shared with the backends
	TokenFile string `json:"token_file"`
	// the hosts the sessions run on, by name
	Backends map[string]backendRef `json:"backends"`
}

// backendRef is a host's backend: its base URL (http://<address>:<port>)
// and its number of slots.
type backendRef struct {
	URL   string `json:"url"`
	Slots int    `json:"slots"`
}

type role int

const (
	viewer role = iota
	controller
)

func (r role) String() string {
	if r == controller {
		return "control"
	}
	return "view"
}

// session is one running browser. sessions.json is 0600 and holds the
// tokens, so the owner's page can always show the links, next to the neko
// passwords and the MCP token, which are internal and never leave the
// gateway and the session's host.
type session struct {
	ID              string    `json:"id"`
	Name            string    `json:"name,omitempty"`
	Owner           string    `json:"owner"`
	Host            string    `json:"host"`
	Slot            int       `json:"slot"`
	ControlToken    string    `json:"control_token,omitempty"`
	ViewToken       string    `json:"view_token,omitempty"`
	ControlPassword string    `json:"control_password"`
	ViewPassword    string    `json:"view_password"`
	MCPToken        string    `json:"mcp_token"`
	Created         time.Time `json:"created"`
	// SHA-256 of the tokens of sessions from before the tokens were kept;
	// regenerating the role's token replaces it with the token
	ControlHash []byte `json:"control_hash,omitempty"`
	ViewHash    []byte `json:"view_hash,omitempty"`

	// its unit is being started: it holds the slot, but is not saved yet
	starting bool
	// proxied requests in flight (websockets and MCP streams included)
	active int
	// cancelled when the role's token is regenerated or the session ends,
	// which cuts the connections made with the old token
	revoke [2]context.CancelFunc
	ctx    [2]context.Context
}

func (se *session) newRoleContext(r role) {
	if se.revoke[r] != nil {
		se.revoke[r]()
	}
	se.ctx[r], se.revoke[r] = context.WithCancel(context.Background())
}

// hash is the SHA-256 of the role's token: of the stored token, or the
// stored hash of a session from before the tokens were kept.
func (se *session) hash(r role) []byte {
	token, h := se.ViewToken, se.ViewHash
	if r == controller {
		token, h = se.ControlToken, se.ControlHash
	}
	if token != "" {
		return hashToken(token)
	}
	return h
}

type server struct {
	cfg          config
	backends     map[string]*url.URL
	token        string
	now          func() time.Time
	oidcClientID string
	cookieKey    []byte
	secure       bool

	mu       sync.Mutex
	sessions map[string]*session
}

func newServer(cfg config) (*server, error) {
	if len(cfg.Backends) == 0 {
		return nil, errors.New("config needs backends")
	}
	s := &server{
		cfg:      cfg,
		backends: map[string]*url.URL{},
		now:      time.Now,
		secure:   strings.HasPrefix(cfg.URL, "https://"),
		sessions: map[string]*session{},
	}
	for host, b := range cfg.Backends {
		u, err := url.Parse(b.URL)
		if err != nil || u.Scheme == "" || u.Host == "" || b.Slots < 1 {
			return nil, fmt.Errorf("backend %s: needs a URL and slots", host)
		}
		s.backends[host] = u
	}
	token, err := readSecret(cfg.TokenFile)
	if err != nil {
		return nil, err
	}
	s.token = string(token)
	if err := os.MkdirAll(cfg.StateDir, 0o700); err != nil {
		return nil, err
	}
	if s.cookieKey, err = cookieKey(filepath.Join(cfg.StateDir, "cookie-key")); err != nil {
		return nil, err
	}
	b, err := os.ReadFile(s.statePath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		var list []*session
		if err := json.Unmarshal(b, &list); err != nil {
			return nil, fmt.Errorf("%s: %w", s.statePath(), err)
		}
		for _, se := range list {
			if b, ok := cfg.Backends[se.Host]; !ok || se.Slot < 0 || se.Slot >= b.Slots {
				return nil, fmt.Errorf("%s: session %s: no slot %d on host %q", s.statePath(), se.ID, se.Slot, se.Host)
			}
			se.newRoleContext(controller)
			se.newRoleContext(viewer)
			s.sessions[se.ID] = se
		}
	}
	return s, nil
}

func (s *server) statePath() string { return filepath.Join(s.cfg.StateDir, "sessions.json") }

// hosts are the names of the backends, sorted.
func (s *server) hosts() []string { return slices.Sorted(maps.Keys(s.cfg.Backends)) }

// save writes the sessions; s.mu must be held.
func (s *server) save() error {
	list := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		if !se.starting {
			list = append(list, se)
		}
	}
	b, err := json.MarshalIndent(list, "", " ")
	if err != nil {
		return err
	}
	tmp := s.statePath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.statePath())
}

func hashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// lookup finds the session and role of a token, comparing its hash against
// every session's in constant time.
func (s *server) lookup(token string) (*session, role, bool) {
	h := hashToken(token)
	var found *session
	var r role
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, se := range s.sessions {
		if subtle.ConstantTimeCompare(h, se.hash(controller)) == 1 {
			found, r = se, controller
		}
		if subtle.ConstantTimeCompare(h, se.hash(viewer)) == 1 {
			found, r = se, viewer
		}
	}
	return found, r, found != nil
}

var (
	errFull = errors.New("all session slots of the host are in use")
	errName = fmt.Errorf("names have at most %d characters", maxName)
	errHost = errors.New("no such host")
)

const maxName = 100

// cleanName trims a session name and checks its length; "" means no name.
func cleanName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if utf8.RuneCountInString(name) > maxName {
		return "", errName
	}
	return name, nil
}

const (
	// starting a unit returns once it runs
	startTimeout = 30 * time.Second
	// stopping waits for the session to end, up to systemd's stop timeout
	removeTimeout = 3 * time.Minute
)

// callBackend sends a request to the backend of host.
func (s *server) callBackend(host string, timeout time.Duration, method, path string, body []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, s.backends[host].JoinPath(path).String(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set(tokenHeader, s.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("%s: %w", host, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("%s: %s: %s", host, resp.Status, strings.TrimSpace(string(msg)))
	}
	return nil
}

// create starts a session for owner on host and returns it with its two
// tokens. The backend call runs without the lock, so a slow host holds up
// no other session.
func (s *server) create(owner, name, host string) (*session, string, string, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, "", "", err
	}
	if host == "" && len(s.cfg.Backends) == 1 {
		host = s.hosts()[0]
	}
	b, ok := s.cfg.Backends[host]
	if !ok {
		return nil, "", "", errHost
	}
	s.mu.Lock()
	used := map[int]bool{}
	for _, se := range s.sessions {
		if se.Host == host {
			used[se.Slot] = true
		}
	}
	free := -1
	for i := range b.Slots {
		if !used[i] {
			free = i
			break
		}
	}
	if free < 0 {
		s.mu.Unlock()
		return nil, "", "", errFull
	}
	control, view := rand.Text(), rand.Text()
	se := &session{
		ID:              rand.Text()[:10],
		Name:            name,
		Owner:           owner,
		Host:            host,
		Slot:            free,
		ControlToken:    control,
		ViewToken:       view,
		ControlPassword: rand.Text(),
		ViewPassword:    rand.Text(),
		MCPToken:        rand.Text(),
		Created:         s.now(),
		starting:        true,
	}
	se.newRoleContext(controller)
	se.newRoleContext(viewer)
	s.sessions[se.ID] = se
	s.mu.Unlock()

	body, _ := json.Marshal(secrets{ControlPassword: se.ControlPassword, ViewPassword: se.ViewPassword, MCPToken: se.MCPToken})
	err = s.callBackend(host, startTimeout, http.MethodPut, "/slots/"+strconv.Itoa(free), body)

	s.mu.Lock()
	defer s.mu.Unlock()
	if err != nil {
		delete(s.sessions, se.ID)
		return nil, "", "", err
	}
	se.starting = false
	if err := s.save(); err != nil {
		return nil, "", "", err
	}
	log.Printf("session %s: created in slot %d on %s", se.ID, free, host)
	return se, control, view, nil
}

// owned returns the session id if owner owns it; s.mu must be held.
func (s *server) owned(id, owner string) (*session, bool) {
	se, ok := s.sessions[id]
	return se, ok && !se.starting && se.Owner == owner
}

// regenerate replaces a token; the old one stops working at once.
func (s *server) regenerate(id, owner string, r role) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	se, ok := s.owned(id, owner)
	if !ok {
		return "", os.ErrNotExist
	}
	token := rand.Text()
	if r == controller {
		se.ControlToken, se.ControlHash = token, nil
	} else {
		se.ViewToken, se.ViewHash = token, nil
	}
	se.newRoleContext(r)
	log.Printf("session %s: new %s token", id, r)
	return token, s.save()
}

// rename sets the name of a session; "" removes it.
func (s *server) rename(id, owner, name string) error {
	name, err := cleanName(name)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	se, ok := s.owned(id, owner)
	if !ok {
		return os.ErrNotExist
	}
	se.Name = name
	return s.save()
}

// kill stops a session and deletes its state for good. If that fails the
// session stays, so its slot never starts with an old profile. The backend
// call runs without the lock; the session holds its slot until it is gone.
func (s *server) kill(id, owner string) error {
	s.mu.Lock()
	se, ok := s.owned(id, owner)
	s.mu.Unlock()
	if !ok {
		return os.ErrNotExist
	}
	if err := s.callBackend(se.Host, removeTimeout, http.MethodDelete, "/slots/"+strconv.Itoa(se.Slot), nil); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sessions[id] != se {
		return nil
	}
	se.revoke[controller]()
	se.revoke[viewer]()
	delete(s.sessions, se.ID)
	log.Printf("session %s: killed", id)
	return s.save()
}

// touch counts a proxied request as connected until the returned func runs.
func (s *server) touch(se *session) func() {
	s.mu.Lock()
	se.active++
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		se.active--
		s.mu.Unlock()
	}
}

func main() {
	gatewayConfig := flag.String("gateway", "", "run the gateway with this JSON config file")
	backendConfigPath := flag.String("backend", "", "run a host's backend with this JSON config file")
	flag.Parse()

	var listen string
	var handler http.Handler
	switch {
	case *gatewayConfig != "" && *backendConfigPath == "":
		var cfg config
		readConfig(*gatewayConfig, &cfg)
		s, err := newServer(cfg)
		if err != nil {
			log.Fatal(err)
		}
		id, err := os.ReadFile(cfg.OIDCClientIDFile)
		if err != nil {
			log.Fatal(err)
		}
		s.oidcClientID = strings.TrimSpace(string(id))
		listen, handler = cfg.Listen, s.routes()
	case *backendConfigPath != "" && *gatewayConfig == "":
		var cfg backendConfig
		readConfig(*backendConfigPath, &cfg)
		b, err := newBackend(cfg, systemctl{bin: cfg.Systemctl, unit: cfg.Unit})
		if err != nil {
			log.Fatal(err)
		}
		b.startAll()
		listen, handler = cfg.Listen, b.routes()
	default:
		log.Fatal("give either -gateway or -backend")
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	srv := &http.Server{Addr: listen, Handler: handler, ErrorLog: log.New(maskWriter{os.Stderr}, "", log.LstdFlags)}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	log.Printf("listening on %s", listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func readConfig(path string, v any) {
	b, err := os.ReadFile(path)
	if err != nil {
		log.Fatal(err)
	}
	if err := json.Unmarshal(b, v); err != nil {
		log.Fatalf("%s: %v", path, err)
	}
}
