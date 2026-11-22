package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeUnits struct {
	mu      sync.Mutex
	running map[int]bool
}

func (f *fakeUnits) Start(slot int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.running[slot] = true
	return nil
}

func (f *fakeUnits) Stop(slot int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.running, slot)
	return nil
}

// backend records what reached a session's neko or MCP server.
type backend struct {
	srv  *httptest.Server
	mu   sync.Mutex
	reqs []*http.Request
	body []string
}

func newBackend(t *testing.T) *backend {
	b := &backend{}
	b.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		b.mu.Lock()
		b.reqs = append(b.reqs, r)
		b.body = append(b.body, string(body))
		b.mu.Unlock()
		io.WriteString(w, "backend "+r.URL.Path)
	}))
	t.Cleanup(b.srv.Close)
	return b
}

func (b *backend) port(t *testing.T) int {
	u, _ := url.Parse(b.srv.URL)
	p, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func (b *backend) last() (*http.Request, string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.reqs[len(b.reqs)-1], b.body[len(b.body)-1]
}

type fixture struct {
	s     *server
	units *fakeUnits
	web   *httptest.Server
	neko  *backend
	mcp   *backend
	now   time.Time
}

func setup(t *testing.T) *fixture {
	f := &fixture{units: &fakeUnits{running: map[int]bool{}}, neko: newBackend(t), mcp: newBackend(t), now: time.Unix(1_800_000_000, 0)}
	cfg := config{
		URL:      "https://browser.example",
		StateDir: t.TempDir(),
		Unit:     "browser-session@%d.service",
		Slots:    []slot{{Neko: f.neko.port(t), MCP: f.mcp.port(t)}},
	}
	s, err := newServer(cfg, f.units)
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return f.now }
	f.s = s
	f.web = httptest.NewServer(s.routes())
	t.Cleanup(f.web.Close)
	return f
}

// do sends a request as owner sub ("" for nobody) and returns status and body.
func (f *fixture) do(t *testing.T, method, path, sub string, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, f.web.URL+path, strings.NewReader(body))
	req.Header.Set("Accept", "application/json")
	if sub != "" {
		req.AddCookie(&http.Cookie{Name: ownerCookie, Value: f.s.sign(owner{Sub: sub, Exp: f.now.Add(time.Hour).Unix()})})
	}
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// tokens creates a session for sub and returns it with its two tokens.
func (f *fixture) create(t *testing.T, sub string) (links, string, string) {
	t.Helper()
	status, body := f.do(t, "POST", "/sessions", sub, "")
	if status != http.StatusCreated {
		t.Fatalf("create: %d %s", status, body)
	}
	var l links
	json.Unmarshal([]byte(body), &l)
	return l, tokenOf(t, l.Control), tokenOf(t, l.View)
}

func tokenOf(t *testing.T, link string) string {
	t.Helper()
	rest, ok := strings.CutPrefix(link, "https://browser.example/s/")
	if !ok {
		t.Fatalf("link %q", link)
	}
	return strings.TrimSuffix(rest, "/")
}

func TestTokens(t *testing.T) {
	f := setup(t)
	l, control, view := f.create(t, "alice")
	if !f.units.running[0] {
		t.Fatal("unit of slot 0 not started")
	}
	if l.MCP != "https://browser.example/s/"+control+"/mcp" {
		t.Fatalf("mcp link %q", l.MCP)
	}

	if status, body := f.do(t, "GET", "/s/"+control+"/assets/app.js", "", ""); status != 200 || body != "backend /assets/app.js" {
		t.Fatalf("control: %d %s", status, body)
	}
	if status, body := f.do(t, "GET", "/s/"+view+"/assets/app.js", "", ""); status != 200 || body != "backend /assets/app.js" {
		t.Fatalf("view: %d %s", status, body)
	}
	if status, _ := f.do(t, "GET", "/s/"+strings.ToUpper(control[:len(control)-1])+"x/", "", ""); status != 404 {
		t.Fatalf("unknown token: %d", status)
	}

	// MCP: control only, with the internal token and without the gateway's cookie
	if status, _ := f.do(t, "POST", "/s/"+view+"/mcp", "", "{}"); status != 403 {
		t.Fatalf("view token on /mcp: %d", status)
	}
	if status, body := f.do(t, "POST", "/s/"+control+"/mcp", "alice", "{}"); status != 200 || body != "backend /mcp" {
		t.Fatalf("control token on /mcp: %d %s", status, body)
	}
	req, _ := f.mcp.last()
	if req.Header.Get("Authorization") != "Bearer "+f.s.sessions[l.ID].MCPToken {
		t.Fatalf("mcp authorization %q", req.Header.Get("Authorization"))
	}
	if req.Header.Get("Cookie") != "" {
		t.Fatal("gateway cookie reached the backend")
	}

	// the neko login gets the role's internal password, whatever was sent
	for tok, want := range map[string]string{control: f.s.sessions[l.ID].ControlPassword, view: f.s.sessions[l.ID].ViewPassword} {
		f.do(t, "POST", "/s/"+tok+"/api/login", "", `{"username":"me","password":"guess"}`)
		_, body := f.neko.last()
		var got map[string]string
		json.Unmarshal([]byte(body), &got)
		if got["password"] != want || got["username"] != "me" {
			t.Fatalf("login body %s", body)
		}
	}
	if status, body := f.do(t, "GET", "/s/"+view+"/", "", ""); status != http.StatusFound || !strings.Contains(body, "usr=view") {
		t.Fatalf("auto-login redirect: %d %s", status, body)
	}
}

func TestRegenerate(t *testing.T) {
	f := setup(t)
	l, control, view := f.create(t, "alice")
	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/regenerate/control", "mallory", ""); status != 404 {
		t.Fatalf("someone else regenerated: %d", status)
	}
	status, body := f.do(t, "POST", "/sessions/"+l.ID+"/regenerate/control", "alice", "")
	if status != 200 {
		t.Fatalf("regenerate: %d %s", status, body)
	}
	var nl links
	json.Unmarshal([]byte(body), &nl)
	if nl.View != "" {
		t.Fatal("regenerating control showed a view link")
	}
	if status, _ := f.do(t, "GET", "/s/"+control+"/x", "", ""); status != 404 {
		t.Fatalf("old control token: %d", status)
	}
	if status, _ := f.do(t, "GET", "/s/"+tokenOf(t, nl.Control)+"/x", "", ""); status != 200 {
		t.Fatalf("new control token: %d", status)
	}
	if status, _ := f.do(t, "GET", "/s/"+view+"/x", "", ""); status != 200 {
		t.Fatalf("view token after control regenerate: %d", status)
	}

	// survives a restart of the gateway
	s2, err := newServer(f.s.cfg, f.units)
	if err != nil {
		t.Fatal(err)
	}
	if _, r, ok := s2.lookup(tokenOf(t, nl.Control)); !ok || r != controller {
		t.Fatal("new control token lost on restart")
	}
	if _, _, ok := s2.lookup(control); ok {
		t.Fatal("old control token back after restart")
	}
}

func TestKill(t *testing.T) {
	f := setup(t)
	l, control, _ := f.create(t, "alice")

	// sessions have no expiry: a gateway restart much later still has it
	f.now = f.now.Add(365 * 24 * time.Hour)
	s2, err := newServer(f.s.cfg, f.units)
	if err != nil {
		t.Fatal(err)
	}
	if se, r, ok := s2.lookup(control); !ok || r != controller || se.ID != l.ID {
		t.Fatal("session lost on restart")
	}

	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "alice", ""); status != http.StatusNoContent {
		t.Fatalf("kill: %d", status)
	}
	if f.units.running[0] {
		t.Fatal("unit of the killed session still running")
	}
	if _, err := os.Stat(f.s.envPath(0)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("env file of the killed session: %v", err)
	}
	if status, _ := f.do(t, "GET", "/s/"+control+"/", "", ""); status != 404 {
		t.Fatalf("token of a killed session: %d", status)
	}
	// the slot is free again
	f.create(t, "bob")
}

func TestSlotsAndOwners(t *testing.T) {
	f := setup(t)
	l, _, _ := f.create(t, "alice")
	if status, _ := f.do(t, "POST", "/sessions", "bob", ""); status != http.StatusServiceUnavailable {
		t.Fatalf("second session in one slot: %d", status)
	}
	if status, _ := f.do(t, "POST", "/sessions", "", ""); status != http.StatusUnauthorized {
		t.Fatalf("create without login: %d", status)
	}
	if _, body := f.do(t, "GET", "/", "bob", ""); strings.Contains(body, l.ID) {
		t.Fatal("bob sees alice's session")
	}
	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "bob", ""); status != 404 {
		t.Fatalf("bob killed alice's session: %d", status)
	}
	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "alice", ""); status != http.StatusNoContent {
		t.Fatalf("kill: %d", status)
	}
}

func TestMask(t *testing.T) {
	var buf bytes.Buffer
	maskWriter{&buf}.Write([]byte("GET /s/ABCDEF234/api/ws?x=1 and /s/QWERTY/mcp\n"))
	if got := buf.String(); got != "GET /s/***/api/ws?x=1 and /s/***/mcp\n" {
		t.Fatalf("mask: %q", got)
	}
}
