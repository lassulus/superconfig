// browser-sessions: shared sandboxed browser sessions. A logged-in owner
// creates sessions on the management page and picks the host each runs on;
// each session runs in a systemd unit (neko + Firefox + browser-mcp) on a
// fixed slot of ports there, and two random tokens give access to it:
// /s/<control>/ (watch and control, MCP at /s/<control>/mcp) and /s/<view>/
// (watch only). The page shows the owner both links of every session. A
// session lasts until its owner kills it; one without requests for a while
// is stopped, keeping its profile, and started again by the next request.
// The owner can move a session to another host; its links stay. A session
// goes out directly or through a proxy whose URL the owner gives; changing
// it restarts a running session. Agents with an API token create, list and
// kill their own sessions over JSON (api.go); those belong to the
// configured API owner as well.
//
// The gateway (this file, page.go, auth.go, api.go, proxy.go) holds the
// page, the login and the sessions with their tokens, and knows which host
// and slot each runs in. The hosts run the backend (backend.go), which
// starts, stops and removes the units, hands their state out and in for
// moves, and passes the gateway's requests on to them.
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
	// a session without any request for this long is stopped, keeping its
	// profile, until the next request; 0 never stops one
	StopAfterMinutes int `json:"stop_after_minutes"`
	// TURN server for the viewers' browsers (turn.go)
	TURN turnConfig `json:"turn"`
	// `<name> <sha256>` lines of the API tokens (api.go), and the OIDC sub
	// of the owner their sessions belong to as well
	APITokensFile string `json:"api_tokens_file"`
	APIOwner      string `json:"api_owner"`
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
	// the name of the API token that created it; "" for the owner's own
	CreatedBy string `json:"created_by,omitempty"`
	// SHA-256 of the tokens of sessions from before the tokens were kept;
	// regenerating the role's token replaces it with the token
	ControlHash []byte `json:"control_hash,omitempty"`
	ViewHash    []byte `json:"view_hash,omitempty"`
	// stopped while idle, started by the next request
	Stopped bool `json:"stopped,omitempty"`
	// the URL of the proxy its Firefox goes out through (parseProxy);
	// "" goes out directly
	Proxy string `json:"proxy,omitempty"`

	// its unit is being started: it holds the slot, but is not saved yet
	starting bool
	// its neko and browser-mcp answer; false until a request found them
	// answering after the gateway started, and while it is stopped or moved
	ready bool
	// a request is starting it for the waking-up page
	waking bool
	// the slot it is being moved to, held for it meanwhile
	moving *place
	// proxied requests in flight (websockets and MCP streams included)
	active int
	// when the last proxied request started or ended; zero until the
	// first idle check after the gateway started
	lastActive time.Time
	// held while the session is started, stopped, moved or killed
	power sync.Mutex
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
	// coturn's secret, when there is a TURN server
	turnSecret []byte
	// the API tokens (api.go)
	apiTokens []apiToken

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
	if cfg.APITokensFile != "" {
		if cfg.APIOwner == "" {
			return nil, errors.New("API tokens need an api_owner")
		}
		tokens, err := readAPITokens(cfg.APITokensFile)
		if err != nil {
			return nil, err
		}
		s.apiTokens = tokens
	}
	token, err := readSecret(cfg.TokenFile)
	if err != nil {
		return nil, err
	}
	s.token = string(token)
	if len(cfg.TURN.URLs) > 0 {
		if cfg.TURN.TTLHours < 1 {
			return nil, errors.New("turn needs ttl_hours")
		}
		if s.turnSecret, err = readSecret(cfg.TURN.SecretFile); err != nil {
			return nil, err
		}
	}
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
	errFull  = errors.New("all session slots of the host are in use")
	errName  = fmt.Errorf("names have at most %d characters", maxName)
	errHost  = errors.New("no such host")
	errProxy = errors.New("bad proxy URL")
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

// cleanProxy trims a proxy URL and checks it the way the backend does;
// "" means none.
func cleanProxy(proxy string) (string, error) {
	proxy = strings.TrimSpace(proxy)
	if proxy == "" {
		return "", nil
	}
	if _, err := parseProxy(proxy); err != nil {
		return "", fmt.Errorf("%w: %v", errProxy, err)
	}
	return proxy, nil
}

const (
	// starting a unit returns once it runs
	startTimeout = 30 * time.Second
	// stopping waits for the session to end, up to systemd's stop timeout
	stopTimeout = 3 * time.Minute
	// a move copies the whole profile
	moveTimeout = 30 * time.Minute
)

var (
	// a stopped session takes this long at most to answer again; MCP
	// calls and other requests that are no page wait for it
	wakeTimeout = 90 * time.Second
	// how often the wait asks whether it answers yet
	wakePoll = 500 * time.Millisecond
)

// place is a slot on a host.
type place struct {
	host string
	slot int
}

// path is the backend path of rest in p's slot.
func (p place) path(rest string) string { return "/slots/" + strconv.Itoa(p.slot) + rest }

// url is the backend URL of rest (a path and query) in p's slot.
func (s *server) url(p place, rest string) string {
	return strings.TrimSuffix(s.backends[p.host].String(), "/") + p.path(rest)
}

// at is where a session runs; s.mu must be held.
func (se *session) at() place { return place{se.Host, se.Slot} }

// secrets are what the session's unit gets when it starts, with TURN
// credentials from now and its proxy; s.mu must be held.
func (s *server) secrets(se *session) []byte {
	sec := secrets{ControlPassword: se.ControlPassword, ViewPassword: se.ViewPassword, MCPToken: se.MCPToken, Proxy: se.Proxy}
	if s.turnSecret != nil {
		ice := iceServer{URLs: s.cfg.TURN.URLs}
		ice.Username, ice.Credential = turnCredentials(s.turnSecret, se.ID, s.now().Add(time.Duration(s.cfg.TURN.TTLHours)*time.Hour))
		sec.ICEServers = []iceServer{ice}
	}
	b, _ := json.Marshal(sec)
	return b
}

// freeSlot returns a slot of host no session has or is moving to, or -1;
// s.mu must be held.
func (s *server) freeSlot(host string) int {
	used := map[int]bool{}
	for _, se := range s.sessions {
		if se.Host == host {
			used[se.Slot] = true
		}
		if se.moving != nil && se.moving.host == host {
			used[se.moving.slot] = true
		}
	}
	for i := range s.cfg.Backends[host].Slots {
		if !used[i] {
			return i
		}
	}
	return -1
}

// backendRequest sends a request to the backend of p's host.
func (s *server) backendRequest(ctx context.Context, p place, method, rest string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, s.url(p, rest), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set(tokenHeader, s.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", p.host, err)
	}
	return resp, nil
}

// callBackend sends a request to the backend of p's host that answers 204.
func (s *server) callBackend(ctx context.Context, timeout time.Duration, p place, method, rest string, body io.Reader) error {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	resp, err := s.backendRequest(ctx, p, method, rest, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return backendStatus(p, resp, http.StatusNoContent)
}

// backendStatus is an error unless resp has the status want.
func backendStatus(p place, resp *http.Response, want int) error {
	if resp.StatusCode == want {
		return nil
	}
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
	return fmt.Errorf("%s: %s: %s", p.host, resp.Status, strings.TrimSpace(string(msg)))
}

// create starts a session for owner on host, going out through the proxy
// URL proxy ("" for directly), and returns it with its two tokens;
// createdBy is the API token that asks for it, if any. The backend call
// runs without the lock, so a slow host holds up no other session.
func (s *server) create(owner, name, host, proxy, createdBy string) (*session, string, string, error) {
	name, err := cleanName(name)
	if err != nil {
		return nil, "", "", err
	}
	if proxy, err = cleanProxy(proxy); err != nil {
		return nil, "", "", err
	}
	if host == "" && len(s.cfg.Backends) == 1 {
		host = s.hosts()[0]
	}
	_, ok := s.cfg.Backends[host]
	if !ok {
		return nil, "", "", errHost
	}
	s.mu.Lock()
	free := s.freeSlot(host)
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
		Proxy:           proxy,
		CreatedBy:       createdBy,
		starting:        true,
	}
	se.newRoleContext(controller)
	se.newRoleContext(viewer)
	s.sessions[se.ID] = se
	body := s.secrets(se)
	s.mu.Unlock()

	// fresh: whatever an earlier session left in the slot goes
	err = s.callBackend(context.Background(), startTimeout, place{host, free}, http.MethodPut, "?fresh", bytes.NewReader(body))

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

// setProxy sets the proxy URL ("" for none) of a session. A running
// session restarts with it the way an idle one comes back: it stops now
// and starts again in the background, viewers get the waking-up page
// meanwhile. A stopped one gets it at its next start. If the stop fails
// nothing changes.
func (s *server) setProxy(id, owner, proxy string) error {
	proxy, err := cleanProxy(proxy)
	if err != nil {
		return err
	}
	s.mu.Lock()
	se, ok := s.owned(id, owner)
	s.mu.Unlock()
	if !ok {
		return os.ErrNotExist
	}
	se.power.Lock()
	defer se.power.Unlock()
	s.mu.Lock()
	if s.sessions[id] != se {
		s.mu.Unlock()
		return os.ErrNotExist
	}
	running := !se.Stopped
	at := se.at()
	if running {
		// requests from now on wait for the restart
		se.ready = false
	}
	s.mu.Unlock()
	if running {
		if err := s.callBackend(context.Background(), stopTimeout, at, http.MethodPost, "/stop", nil); err != nil {
			return err
		}
	}
	s.mu.Lock()
	se.Proxy = proxy
	se.Stopped = true
	err = s.save()
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if running {
		log.Printf("session %s: restarting with a new proxy", id)
		// its goroutine waits until this returns and unlocks power
		s.wakeInBackground(se)
	}
	return nil
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
	se.power.Lock()
	defer se.power.Unlock()
	s.mu.Lock()
	at := se.at()
	s.mu.Unlock()
	if err := s.callBackend(context.Background(), stopTimeout, at, http.MethodDelete, "", nil); err != nil {
		// it may be stopped now; the next request starts it again
		s.mu.Lock()
		se.ready = false
		s.mu.Unlock()
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

// touch counts a proxied request as activity and as connected until the
// returned func runs.
func (s *server) touch(se *session) func() {
	s.mu.Lock()
	se.active++
	se.lastActive = s.now()
	s.mu.Unlock()
	return func() {
		s.mu.Lock()
		se.active--
		se.lastActive = s.now()
		s.mu.Unlock()
	}
}

// idle tells whether a running session has had no request for the stop
// time; s.mu must be held.
func (s *server) idle(se *session) bool {
	if se.lastActive.IsZero() {
		se.lastActive = s.now()
	}
	after := time.Duration(s.cfg.StopAfterMinutes) * time.Minute
	return after > 0 && !se.starting && !se.Stopped && se.active == 0 && s.now().Sub(se.lastActive) >= after
}

// stopIdle stops the sessions that are idle, skipping those being started,
// moved or killed. A request that comes meanwhile counts as activity
// first, so either the check below sees it, or it waits for the stop and
// starts the session again.
func (s *server) stopIdle() {
	s.mu.Lock()
	var idle []*session
	for _, se := range s.sessions {
		if s.idle(se) {
			idle = append(idle, se)
		}
	}
	s.mu.Unlock()
	for _, se := range idle {
		if !se.power.TryLock() {
			continue
		}
		s.mu.Lock()
		still := s.sessions[se.ID] == se && s.idle(se)
		at := se.at()
		if still {
			// requests from now on wait for the stop, then start it again
			se.ready = false
		}
		s.mu.Unlock()
		if still {
			err := s.callBackend(context.Background(), stopTimeout, at, http.MethodPost, "/stop", nil)
			s.mu.Lock()
			if err != nil {
				log.Printf("session %s: stop: %v", se.ID, err)
			} else {
				se.Stopped = true
				log.Printf("session %s: stopped while idle", se.ID)
				if err := s.save(); err != nil {
					log.Printf("save: %v", err)
				}
			}
			s.mu.Unlock()
		}
		se.power.Unlock()
	}
}

var errGone = errors.New("the session is gone")

// ensureUp starts the session unless it answers, and waits until it does.
// Starting a running one does nothing, so after a gateway restart this
// only checks it once.
func (s *server) ensureUp(ctx context.Context, se *session) error {
	se.power.Lock()
	defer se.power.Unlock()
	s.mu.Lock()
	ready, at, body := se.ready, se.at(), s.secrets(se)
	gone := s.sessions[se.ID] != se
	s.mu.Unlock()
	if gone {
		return errGone
	}
	if ready {
		return nil
	}
	if err := s.callBackend(ctx, startTimeout, at, http.MethodPut, "", bytes.NewReader(body)); err != nil {
		return err
	}
	s.mu.Lock()
	if se.Stopped {
		se.Stopped = false
		log.Printf("session %s: started again", se.ID)
		if err := s.save(); err != nil {
			log.Printf("save: %v", err)
		}
	}
	s.mu.Unlock()
	for {
		if s.callBackend(ctx, 5*time.Second, at, http.MethodGet, "", nil) == nil {
			s.mu.Lock()
			se.ready = true
			s.mu.Unlock()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wakePoll):
		}
	}
}

// wakeInBackground starts the session for a page that shows the waking-up
// page meanwhile, once at a time.
func (s *server) wakeInBackground(se *session) {
	s.mu.Lock()
	if se.waking {
		s.mu.Unlock()
		return
	}
	se.waking = true
	s.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), wakeTimeout)
		defer cancel()
		if err := s.ensureUp(ctx, se); err != nil {
			log.Printf("session %s: start: %v", se.ID, err)
		}
		s.mu.Lock()
		se.waking = false
		s.mu.Unlock()
	}()
}

var errSameHost = errors.New("the session runs on that host already")

// move moves a session to host: it stops the session, copies its state
// there and starts it in a free slot, and only then deletes the old copy.
// If anything before the start fails, the session stays where it was,
// stopped until the next request.
func (s *server) move(id, owner, host string) error {
	s.mu.Lock()
	se, ok := s.owned(id, owner)
	s.mu.Unlock()
	if !ok {
		return os.ErrNotExist
	}
	if _, ok := s.cfg.Backends[host]; !ok {
		return errHost
	}
	se.power.Lock()
	defer se.power.Unlock()
	s.mu.Lock()
	if s.sessions[id] != se {
		s.mu.Unlock()
		return os.ErrNotExist
	}
	from := se.at()
	if from.host == host {
		s.mu.Unlock()
		return errSameHost
	}
	slot := s.freeSlot(host)
	if slot < 0 {
		s.mu.Unlock()
		return errFull
	}
	to := place{host, slot}
	se.moving = &to
	// requests from now on wait for the move
	se.ready = false
	body := s.secrets(se)
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		se.moving = nil
		s.mu.Unlock()
	}()

	ctx, cancel := context.WithTimeout(context.Background(), moveTimeout)
	defer cancel()
	if err := s.callBackend(ctx, stopTimeout, from, http.MethodPost, "/stop", nil); err != nil {
		return err
	}
	s.mu.Lock()
	se.Stopped = true
	err := s.save()
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err := s.copyState(ctx, from, to); err != nil {
		return err
	}
	if err := s.callBackend(ctx, startTimeout, to, http.MethodPut, "", bytes.NewReader(body)); err != nil {
		if rerr := s.callBackend(ctx, stopTimeout, to, http.MethodDelete, "", nil); rerr != nil {
			log.Printf("session %s: removing the copy on %s: %v", id, host, rerr)
		}
		return err
	}
	s.mu.Lock()
	se.Host, se.Slot, se.Stopped = to.host, to.slot, false
	err = s.save()
	s.mu.Unlock()
	if err != nil {
		return err
	}
	log.Printf("session %s: moved from slot %d on %s to slot %d on %s", id, from.slot, from.host, to.slot, to.host)
	// a copy left behind goes when a new session starts fresh in its slot
	if err := s.callBackend(ctx, stopTimeout, from, http.MethodDelete, "", nil); err != nil {
		log.Printf("session %s: removing the old copy on %s: %v", id, from.host, err)
	}
	return nil
}

// copyState streams the state of the stopped slot from to the slot to.
func (s *server) copyState(ctx context.Context, from, to place) error {
	resp, err := s.backendRequest(ctx, from, http.MethodGet, "/state", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := backendStatus(from, resp, http.StatusOK); err != nil {
		return err
	}
	put, err := s.backendRequest(ctx, to, http.MethodPut, "/state", resp.Body)
	if err != nil {
		return err
	}
	defer put.Body.Close()
	return backendStatus(to, put, http.StatusNoContent)
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
		go func() {
			for range time.Tick(time.Minute) {
				s.stopIdle()
			}
		}()
	case *backendConfigPath != "" && *gatewayConfig == "":
		var cfg backendConfig
		readConfig(*backendConfigPath, &cfg)
		b, err := newBackend(cfg, systemctl{
			bin:         cfg.Systemctl,
			unit:        cfg.Unit,
			exportUnit:  cfg.ExportUnit,
			importUnit:  cfg.ImportUnit,
			transferDir: filepath.Join(cfg.StateDir, "transfer"),
		})
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
