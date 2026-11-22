// browser-sessions: shared sandboxed browser sessions. A logged-in owner
// creates sessions on the management page; each session runs in a systemd
// unit (neko + Firefox + browser-mcp) on a fixed slot of ports, and two
// random tokens give access to it: /s/<control>/ (watch and control, MCP at
// /s/<control>/mcp) and /s/<view>/ (watch only).
package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

type config struct {
	Listen string `json:"listen"`
	// public base URL of the gateway, without a trailing slash
	URL              string `json:"url"`
	StateDir         string `json:"state_dir"`
	OIDCIssuer       string `json:"oidc_issuer"`
	OIDCClientIDFile string `json:"oidc_client_id_file"`
	// a session nobody is connected to ends after this long
	IdleTimeout string `json:"idle_timeout"`
	// unit of slot i: fmt.Sprintf(Unit, i)
	Unit      string `json:"unit"`
	Systemctl string `json:"systemctl"`
	Slots     []slot `json:"slots"`
}

// slot is where one session runs: the localhost ports of its neko and its
// browser-mcp.
type slot struct {
	Neko int `json:"neko"`
	MCP  int `json:"mcp"`
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

// session is one running browser. Tokens are only kept as SHA-256 hashes;
// the passwords and the MCP token are internal and never leave the host.
type session struct {
	ID              string    `json:"id"`
	Owner           string    `json:"owner"`
	Slot            int       `json:"slot"`
	ControlHash     []byte    `json:"control_hash"`
	ViewHash        []byte    `json:"view_hash"`
	ControlPassword string    `json:"control_password"`
	ViewPassword    string    `json:"view_password"`
	MCPToken        string    `json:"mcp_token"`
	Created         time.Time `json:"created"`
	LastActive      time.Time `json:"last_active"`

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

// units starts and stops the systemd unit of a slot.
type units interface {
	Start(slot int) error
	Stop(slot int) error
}

type systemctl struct{ bin, unit string }

func (s systemctl) run(verb string, slot int) error {
	out, err := exec.Command(s.bin, verb, fmt.Sprintf(s.unit, slot)).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s: %v: %s", verb, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (s systemctl) Start(slot int) error { return s.run("start", slot) }
func (s systemctl) Stop(slot int) error  { return s.run("stop", slot) }

type server struct {
	cfg          config
	idle         time.Duration
	units        units
	now          func() time.Time
	oidcClientID string
	cookieKey    []byte
	secure       bool

	mu       sync.Mutex
	sessions map[string]*session
	dirty    bool
}

func newServer(cfg config, u units) (*server, error) {
	idle, err := time.ParseDuration(cfg.IdleTimeout)
	if err != nil {
		return nil, fmt.Errorf("idle_timeout: %w", err)
	}
	if cfg.Unit == "" || len(cfg.Slots) == 0 {
		return nil, errors.New("config needs unit and slots")
	}
	s := &server{
		cfg:      cfg,
		idle:     idle,
		units:    u,
		now:      time.Now,
		secure:   strings.HasPrefix(cfg.URL, "https://"),
		sessions: map[string]*session{},
	}
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "slots"), 0o700); err != nil {
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
			se.newRoleContext(controller)
			se.newRoleContext(viewer)
			s.sessions[se.ID] = se
		}
	}
	return s, nil
}

func (s *server) statePath() string { return filepath.Join(s.cfg.StateDir, "sessions.json") }

func (s *server) envPath(slot int) string {
	return filepath.Join(s.cfg.StateDir, "slots", fmt.Sprintf("%d.env", slot))
}

// save writes the sessions; s.mu must be held.
func (s *server) save() error {
	list := make([]*session, 0, len(s.sessions))
	for _, se := range s.sessions {
		list = append(list, se)
	}
	b, err := json.MarshalIndent(list, "", " ")
	if err != nil {
		return err
	}
	tmp := s.statePath() + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	s.dirty = false
	return os.Rename(tmp, s.statePath())
}

func hashToken(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// lookup finds the session and role of a token, comparing against every
// session's hashes in constant time.
func (s *server) lookup(token string) (*session, role, bool) {
	h := hashToken(token)
	var found *session
	var r role
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, se := range s.sessions {
		if subtle.ConstantTimeCompare(h, se.ControlHash) == 1 {
			found, r = se, controller
		}
		if subtle.ConstantTimeCompare(h, se.ViewHash) == 1 {
			found, r = se, viewer
		}
	}
	return found, r, found != nil
}

var errFull = errors.New("all session slots are in use")

// create starts a session for owner and returns it with its two tokens.
func (s *server) create(owner string) (*session, string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	used := map[int]bool{}
	for _, se := range s.sessions {
		used[se.Slot] = true
	}
	free := -1
	for i := range s.cfg.Slots {
		if !used[i] {
			free = i
			break
		}
	}
	if free < 0 {
		return nil, "", "", errFull
	}
	now := s.now()
	control, view := rand.Text(), rand.Text()
	se := &session{
		ID:              rand.Text()[:10],
		Owner:           owner,
		Slot:            free,
		ControlHash:     hashToken(control),
		ViewHash:        hashToken(view),
		ControlPassword: rand.Text(),
		ViewPassword:    rand.Text(),
		MCPToken:        rand.Text(),
		Created:         now,
		LastActive:      now,
	}
	se.newRoleContext(controller)
	se.newRoleContext(viewer)
	env := fmt.Sprintf("NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=%s\nNEKO_MEMBER_MULTIUSER_USER_PASSWORD=%s\nBROWSER_MCP_TOKEN=%s\n",
		se.ControlPassword, se.ViewPassword, se.MCPToken)
	if err := os.WriteFile(s.envPath(free), []byte(env), 0o600); err != nil {
		return nil, "", "", err
	}
	if err := s.units.Start(free); err != nil {
		os.Remove(s.envPath(free))
		return nil, "", "", err
	}
	s.sessions[se.ID] = se
	if err := s.save(); err != nil {
		return nil, "", "", err
	}
	log.Printf("session %s: created in slot %d", se.ID, free)
	return se, control, view, nil
}

// owned returns the session id if owner owns it; s.mu must be held.
func (s *server) owned(id, owner string) (*session, bool) {
	se, ok := s.sessions[id]
	return se, ok && se.Owner == owner
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
		se.ControlHash = hashToken(token)
	} else {
		se.ViewHash = hashToken(token)
	}
	se.newRoleContext(r)
	log.Printf("session %s: new %s token", id, r)
	return token, s.save()
}

func (s *server) kill(id, owner string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	se, ok := s.owned(id, owner)
	if !ok {
		return os.ErrNotExist
	}
	log.Printf("session %s: killed", id)
	return s.end(se)
}

// end stops a session and forgets it; s.mu must be held.
func (s *server) end(se *session) error {
	se.revoke[controller]()
	se.revoke[viewer]()
	err := s.units.Stop(se.Slot)
	os.Remove(s.envPath(se.Slot))
	delete(s.sessions, se.ID)
	return errors.Join(err, s.save())
}

// expire ends the sessions nobody has been connected to for the idle
// timeout, and saves the activity times.
func (s *server) expire() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for _, se := range s.sessions {
		if se.active == 0 && now.Sub(se.LastActive) > s.idle {
			log.Printf("session %s: idle since %s, ending it", se.ID, se.LastActive.Format(time.RFC3339))
			if err := s.end(se); err != nil {
				log.Printf("session %s: %v", se.ID, err)
			}
		}
	}
	if s.dirty {
		if err := s.save(); err != nil {
			log.Printf("save: %v", err)
		}
	}
}

// touch counts a proxied request as active until the returned func runs.
func (s *server) touch(se *session) func() {
	s.mu.Lock()
	se.active++
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		se.active--
		se.LastActive = s.now()
		s.dirty = true
		s.mu.Unlock()
	}
}

func main() {
	configPath := flag.String("config", "", "JSON config file")
	flag.Parse()
	b, err := os.ReadFile(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	var cfg config
	if err := json.Unmarshal(b, &cfg); err != nil {
		log.Fatalf("%s: %v", *configPath, err)
	}
	s, err := newServer(cfg, systemctl{bin: cfg.Systemctl, unit: cfg.Unit})
	if err != nil {
		log.Fatal(err)
	}
	id, err := os.ReadFile(cfg.OIDCClientIDFile)
	if err != nil {
		log.Fatal(err)
	}
	s.oidcClientID = strings.TrimSpace(string(id))

	// after a reboot the units of the saved sessions are not running
	s.mu.Lock()
	for _, se := range s.sessions {
		if err := s.units.Start(se.Slot); err != nil {
			log.Printf("session %s: %v", se.ID, err)
		}
	}
	s.mu.Unlock()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.expire()
			}
		}
	}()
	srv := &http.Server{Addr: cfg.Listen, Handler: s.routes(), ErrorLog: log.New(maskWriter{os.Stderr}, "", log.LstdFlags)}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	log.Printf("listening on %s", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.save(); err != nil {
		log.Print(err)
	}
}
