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
	// slots whose state was deleted
	cleaned map[int]bool
	fail    error
}

func (f *fakeUnits) Start(slot int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.running[slot] = true
	delete(f.cleaned, slot)
	return nil
}

func (f *fakeUnits) Remove(slot int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.fail != nil {
		return f.fail
	}
	delete(f.running, slot)
	f.cleaned[slot] = true
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
	f := &fixture{units: &fakeUnits{running: map[int]bool{}, cleaned: map[int]bool{}}, neko: newBackend(t), mcp: newBackend(t), now: time.Unix(1_800_000_000, 0)}
	cfg := config{
		URL:      "https://browser.example",
		StateDir: t.TempDir(),
		Unit:     "browser-session@%d.service",
		Slots:    []slot{{Neko: f.neko.port(t), MCP: f.mcp.port(t)}},
	}
	f.start(t, cfg)
	return f
}

// start runs a gateway on cfg, as after a restart when cfg.StateDir has
// sessions.
func (f *fixture) start(t *testing.T, cfg config) {
	t.Helper()
	s, err := newServer(cfg, f.units)
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return f.now }
	f.s = s
	f.web = httptest.NewServer(s.routes())
	t.Cleanup(f.web.Close)
}

// do sends a request as owner sub ("" for nobody) and returns status and body.
func (f *fixture) do(t *testing.T, method, path, sub string, body string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, f.web.URL+path, strings.NewReader(body))
	req.Header.Set("Accept", "application/json")
	return f.send(t, req, sub)
}

// post sends a form as owner sub and returns status and body.
func (f *fixture) post(t *testing.T, path, sub string, form url.Values) (int, string) {
	t.Helper()
	req, _ := http.NewRequest("POST", f.web.URL+path, strings.NewReader(form.Encode()))
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return f.send(t, req, sub)
}

// page returns the HTML page as owner sub sees it.
func (f *fixture) page(t *testing.T, sub string) string {
	t.Helper()
	req, _ := http.NewRequest("GET", f.web.URL+"/", nil)
	status, body := f.send(t, req, sub)
	if status != 200 {
		t.Fatalf("page: %d %s", status, body)
	}
	return body
}

// sessions returns the session list of owner sub.
func (f *fixture) sessions(t *testing.T, sub string) []sessionInfo {
	t.Helper()
	status, body := f.do(t, "GET", "/", sub, "")
	if status != 200 {
		t.Fatalf("list: %d %s", status, body)
	}
	var list []sessionInfo
	if err := json.Unmarshal([]byte(body), &list); err != nil {
		t.Fatal(err)
	}
	return list
}

func (f *fixture) send(t *testing.T, req *http.Request, sub string) (int, string) {
	t.Helper()
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

	// the list shows the new control link next to the unchanged view link,
	// also after a restart of the gateway
	f.start(t, f.s.cfg)
	if list := f.sessions(t, "alice"); len(list) != 1 || list[0].Control != nl.Control || list[0].MCP != nl.MCP || list[0].View != l.View {
		t.Fatalf("list after regenerate: %+v", list)
	}
	if _, r, ok := f.s.lookup(tokenOf(t, nl.Control)); !ok || r != controller {
		t.Fatal("new control token lost on restart")
	}
	if _, _, ok := f.s.lookup(control); ok {
		t.Fatal("old control token back after restart")
	}
}

func TestLinksShown(t *testing.T) {
	f := setup(t)
	status, body := f.post(t, "/sessions", "alice", url.Values{"name": {"  Shop <b>  "}})
	if status != http.StatusCreated {
		t.Fatalf("create: %d %s", status, body)
	}
	var l links
	json.Unmarshal([]byte(body), &l)
	list := f.sessions(t, "alice")
	if len(list) != 1 || list[0].links != l || list[0].Name != "Shop <b>" {
		t.Fatalf("list %+v, created %+v", list, l)
	}
	page := f.page(t, "alice")
	for _, want := range []string{`href="` + l.Control + `"`, `href="` + l.View + `"`, "<code>" + l.MCP + "</code>", "Shop &lt;b&gt; <small>" + l.ID + "</small>"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %s", want)
		}
	}
	if strings.Contains(page, "not stored") {
		t.Error("page says a link of a new session is not stored")
	}
	t.Log(page)

	// the browser's form goes back to the page
	req, _ := http.NewRequest("POST", f.web.URL+"/sessions/"+l.ID+"/rename", strings.NewReader("name=x"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if status, _ := f.send(t, req, "alice"); status != http.StatusSeeOther {
		t.Fatalf("rename from the page: %d", status)
	}
}

// Sessions from before the tokens were kept have only their hashes.
func TestLegacySession(t *testing.T) {
	f := setup(t)
	legacy := []map[string]any{{
		"id": "OLDSESSION", "owner": "alice", "slot": 0,
		"control_hash": hashToken("OLDCONTROL"), "view_hash": hashToken("OLDVIEW"),
		"control_password": "cp", "view_password": "vp", "mcp_token": "mt", "created": f.now,
	}}
	b, _ := json.Marshal(legacy)
	if err := os.WriteFile(f.s.statePath(), b, 0o600); err != nil {
		t.Fatal(err)
	}
	f.start(t, f.s.cfg)

	for _, tok := range []string{"OLDCONTROL", "OLDVIEW"} {
		if status, _ := f.do(t, "GET", "/s/"+tok+"/x", "", ""); status != 200 {
			t.Fatalf("legacy token %s: %d", tok, status)
		}
	}
	if status, body := f.do(t, "POST", "/s/OLDCONTROL/mcp", "", "{}"); status != 200 || body != "backend /mcp" {
		t.Fatalf("legacy control token on /mcp: %d %s", status, body)
	}
	if n := strings.Count(f.page(t, "alice"), "link not stored, regenerate to show"); n != 2 {
		t.Fatalf("page shows %d regenerate hints, want 2", n)
	}

	status, body := f.do(t, "POST", "/sessions/OLDSESSION/regenerate/view", "alice", "")
	if status != 200 {
		t.Fatalf("regenerate: %d %s", status, body)
	}
	var nl links
	json.Unmarshal([]byte(body), &nl)
	page := f.page(t, "alice")
	if !strings.Contains(page, `href="`+nl.View+`"`) || strings.Count(page, "link not stored") != 1 {
		t.Fatalf("page after regenerating the view link:\n%s", page)
	}
	if status, _ := f.do(t, "GET", "/s/OLDVIEW/x", "", ""); status != 404 {
		t.Fatalf("old view token: %d", status)
	}

	// the new token is stored instead of the hash, the control hash stays
	f.start(t, f.s.cfg)
	se := f.s.sessions["OLDSESSION"]
	if se.ViewToken != tokenOf(t, nl.View) || se.ViewHash != nil || se.ControlToken != "" || se.ControlHash == nil {
		t.Fatalf("stored session %+v", se)
	}
	if status, _ := f.do(t, "GET", "/s/OLDCONTROL/x", "", ""); status != 200 {
		t.Fatalf("legacy control token after regenerating view: %d", status)
	}
}

func TestRename(t *testing.T) {
	f := setup(t)
	l, _, _ := f.create(t, "alice")
	if list := f.sessions(t, "alice"); list[0].Name != "" || !strings.Contains(f.page(t, "alice"), "<h2>"+l.ID+"</h2>") {
		t.Fatalf("unnamed session: %+v", list)
	}
	rename := func(sub, name string) int {
		status, _ := f.post(t, "/sessions/"+l.ID+"/rename", sub, url.Values{"name": {name}})
		return status
	}
	if status := rename("alice", " shopping\t"); status != http.StatusNoContent {
		t.Fatalf("rename: %d", status)
	}
	if status := rename("bob", "mine"); status != 404 {
		t.Fatalf("bob renamed alice's session: %d", status)
	}
	if status := rename("", "mine"); status != http.StatusUnauthorized {
		t.Fatalf("rename without login: %d", status)
	}
	if status := rename("alice", strings.Repeat("ä", maxName+1)); status != http.StatusBadRequest {
		t.Fatalf("too long name: %d", status)
	}
	if status := rename("alice", strings.Repeat("ä", maxName)); status != http.StatusNoContent {
		t.Fatalf("name of maxName characters: %d", status)
	}
	f.start(t, f.s.cfg)
	if list := f.sessions(t, "alice"); list[0].Name != strings.Repeat("ä", maxName) {
		t.Fatalf("name after restart %q", list[0].Name)
	}
	if status := rename("alice", "  "); status != http.StatusNoContent {
		t.Fatalf("clearing the name: %d", status)
	}
	if list := f.sessions(t, "alice"); list[0].Name != "" {
		t.Fatalf("cleared name %q", list[0].Name)
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

	// a failed stop/clean keeps the session, so the slot never reuses old state
	f.units.fail = errors.New("clean failed")
	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "alice", ""); status != http.StatusInternalServerError {
		t.Fatalf("kill with failing clean: %d", status)
	}
	if status, _ := f.do(t, "GET", "/s/"+control+"/x", "", ""); status != 200 {
		t.Fatalf("token after failed kill: %d", status)
	}

	f.units.fail = nil
	if status, _ := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "alice", ""); status != http.StatusNoContent {
		t.Fatalf("kill: %d", status)
	}
	if f.units.running[0] || !f.units.cleaned[0] {
		t.Fatal("unit of the killed session not stopped and cleaned")
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
