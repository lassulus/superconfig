// browser-sessions: shared sandboxed browser sessions. A logged-in owner
// creates sessions on the management page; each session runs in a systemd
// unit (neko + Firefox + browser-mcp) on a fixed slot of ports, and two
// random tokens give access to it: /s/<control>/ (watch and control, MCP at
// /s/<control>/mcp) and /s/<view>/ (watch only). The page shows the owner
// both links of every session. A session lasts until its owner kills it.
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
	"unicode/utf8"
)

type config struct {
	Listen string `json:"listen"`
	// public base URL of the gateway, without a trailing slash
	URL              string `json:"url"`
	StateDir         string `json:"state_dir"`
	OIDCIssuer       string `json:"oidc_issuer"`
	OIDCClientIDFile string `json:"oidc_client_id_file"`
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

// session is one running browser. sessions.json is 0600 and holds the
// tokens, so the owner's page can always show the links, next to the neko
// passwords and the MCP token, which are internal and never leave the host.
type session struct {
	ID              string    `json:"id"`
	Name            string    `json:"name,omitempty"`
	Owner           string    `json:"owner"`
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

// units starts the systemd unit of a slot, and stops it and deletes its
// state.
type units interface {
	Start(slot int) error
	Remove(slot int) error
}

type systemctl struct{ bin, unit string }

func (s systemctl) run(slot int, args ...string) error {
	out, err := exec.Command(s.bin, append(args, fmt.Sprintf(s.unit, slot))...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (s systemctl) Start(slot int) error { return s.run(slot, "start") }

func (s systemctl) Remove(slot int) error {
	if err := s.run(slot, "stop"); err != nil {
		return err
	}
	return s.run(slot, "clean", "--what=state")
}

type server struct {
	cfg          config
	units        units
	now          func() time.Time
	oidcClientID string
	cookieKey    []byte
	secure       bool

	mu       sync.Mutex
	sessions map[string]*session
}

func newServer(cfg config, u units) (*server, error) {
	if cfg.Unit == "" || len(cfg.Slots) == 0 {
		return nil, errors.New("config needs unit and slots")
	}
	s := &server{
		cfg:      cfg,
		units:    u,
		now:      time.Now,
		secure:   strings.HasPrefix(cfg.URL, "https://"),
		sessions: map[string]*session{},
	}
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "slots"), 0o700); err != nil {
		return nil, err
	}
	var err error
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
	errFull = errors.New("all session slots are in use")
	errName = fmt.Errorf("names have at most %d characters", maxName)
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

// create starts a session for owner and returns it with its two tokens.
func (s *server) create(owner, name string) (*session, string, string, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, "", "", err
	}
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
		Name:            name,
		Owner:           owner,
		Slot:            free,
		ControlToken:    control,
		ViewToken:       view,
		ControlPassword: rand.Text(),
		ViewPassword:    rand.Text(),
		MCPToken:        rand.Text(),
		Created:         now,
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
// session stays, so its slot never starts with an old profile.
func (s *server) kill(id, owner string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	se, ok := s.owned(id, owner)
	if !ok {
		return os.ErrNotExist
	}
	if err := s.units.Remove(se.Slot); err != nil {
		return err
	}
	se.revoke[controller]()
	se.revoke[viewer]()
	os.Remove(s.envPath(se.Slot))
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

	// after a reboot the units of the saved sessions are not running; they
	// come back with their state
	s.mu.Lock()
	for _, se := range s.sessions {
		if err := s.units.Start(se.Slot); err != nil {
			log.Printf("session %s: %v", se.ID, err)
		}
	}
	s.mu.Unlock()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
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
}
