package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
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

// recorder records what reached a session's neko or MCP server.
type recorder struct {
	srv  *httptest.Server
	mu   sync.Mutex
	reqs []*http.Request
	body []string
}

func newRecorder(t *testing.T) *recorder {
	b := &recorder{}
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

func (b *recorder) port(t *testing.T) int {
	u, _ := url.Parse(b.srv.URL)
	p, err := strconv.Atoi(u.Port())
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func (b *recorder) last() (*http.Request, string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.reqs[len(b.reqs)-1], b.body[len(b.body)-1]
}

// host is a session host: its backend with one slot.
type host struct {
	b     *backendServer
	web   *httptest.Server
	units *fakeUnits
	neko  *recorder
	mcp   *recorder
}

type fixture struct {
	s     *server
	web   *httptest.Server
	hosts map[string]*host
	now   time.Time
	// of the first host
	units *fakeUnits
	neko  *recorder
	mcp   *recorder
}

const testToken = "0123456789abcdef0123456789abcdef"

func setup(t *testing.T) *fixture { return setupHosts(t, "atlas") }

// setupHosts runs a gateway with a backend of one slot per host.
func setupHosts(t *testing.T, names ...string) *fixture {
	tokenFile := t.TempDir() + "/token"
	if err := os.WriteFile(tokenFile, []byte(testToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := &fixture{hosts: map[string]*host{}, now: time.Unix(1_800_000_000, 0)}
	cfg := config{
		URL:       "https://browser.example",
		StateDir:  t.TempDir(),
		TokenFile: tokenFile,
		Backends:  map[string]backendRef{},
	}
	for _, name := range names {
		h := &host{units: &fakeUnits{running: map[int]bool{}, cleaned: map[int]bool{}}, neko: newRecorder(t), mcp: newRecorder(t)}
		h.start(t, backendConfig{
			StateDir:  t.TempDir(),
			TokenFile: tokenFile,
			Unit:      "browser-session@%d.service",
			Slots:     []slot{{Neko: h.neko.port(t), MCP: h.mcp.port(t)}},
		})
		f.hosts[name] = h
		cfg.Backends[name] = backendRef{URL: h.web.URL, Slots: 1}
	}
	first := f.hosts[names[0]]
	f.units, f.neko, f.mcp = first.units, first.neko, first.mcp
	f.start(t, cfg)
	return f
}

// start runs the backend on cfg, as after a reboot of the host.
func (h *host) start(t *testing.T, cfg backendConfig) {
	t.Helper()
	b, err := newBackend(cfg, h.units)
	if err != nil {
		t.Fatal(err)
	}
	b.startAll()
	h.b = b
	if h.web == nil {
		h.web = httptest.NewServer(b.routes())
		t.Cleanup(h.web.Close)
	} else {
		h.web.Config.Handler = b.routes()
	}
}

// start runs a gateway on cfg, as after a restart when cfg.StateDir has
// sessions.
func (f *fixture) start(t *testing.T, cfg config) {
	t.Helper()
	s, err := newServer(cfg)
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

// create creates a session for sub on host ("" for the only one) and
// returns it with its two tokens.
func (f *fixture) create(t *testing.T, sub, host string) (links, string, string) {
	t.Helper()
	status, body := f.post(t, "/sessions", sub, url.Values{"host": {host}})
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
	l, control, view := f.create(t, "alice", "")
	if !f.units.running[0] {
		t.Fatal("unit of slot 0 not started")
	}
	env, err := os.ReadFile(f.hosts["atlas"].b.envPath(0))
	if se := f.s.sessions[l.ID]; err != nil || !strings.Contains(string(env), "BROWSER_MCP_TOKEN="+se.MCPToken+"\n") || !strings.Contains(string(env), "ADMIN_PASSWORD="+se.ControlPassword+"\n") {
		t.Fatalf("env file of the slot: %v %q", err, env)
	}
	if l.MCP != "https://browser.example/s/"+control+"/mcp" {
		t.Fatalf("mcp link %q", l.MCP)
	}

	if status, body := f.do(t, "GET", "/s/"+control+"/assets/app.js?v=1", "", ""); status != 200 || body != "backend /assets/app.js" {
		t.Fatalf("control: %d %s", status, body)
	}
	if req, _ := f.neko.last(); req.URL.RawQuery != "v=1" || req.Header.Get(tokenHeader) != "" {
		t.Fatalf("neko got query %q, backend token %q", req.URL.RawQuery, req.Header.Get(tokenHeader))
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

// The backend does nothing without the gateway's token.
func TestBackendToken(t *testing.T) {
	f := setup(t)
	h := f.hosts["atlas"]
	for _, token := range []string{"", testToken[1:], strings.ToUpper(testToken)} {
		req, _ := http.NewRequest("PUT", h.web.URL+"/slots/0", strings.NewReader(`{"control_password":"AAAAAAAAAAAAAAAA","view_password":"AAAAAAAAAAAAAAAA","mcp_token":"AAAAAAAAAAAAAAAA"}`))
		if token != "" {
			req.Header.Set(tokenHeader, token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("token %q: %d", token, resp.StatusCode)
		}
	}
	for _, path := range []string{"/slots/0/neko/", "/slots/0/mcp"} {
		resp, err := http.Get(h.web.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s without token: %d", path, resp.StatusCode)
		}
	}
	if len(h.units.running) != 0 || len(h.neko.reqs) != 0 || len(h.mcp.reqs) != 0 {
		t.Fatal("a request without the token got through")
	}

	// secrets go into an env file: nothing that could add a line
	req, _ := http.NewRequest("PUT", h.web.URL+"/slots/0", strings.NewReader(`{"control_password":"AAAAAAAAAAAAAAAA\nLD_PRELOAD=x","view_password":"AAAAAAAAAAAAAAAA","mcp_token":"AAAAAAAAAAAAAAAA"}`))
	req.Header.Set(tokenHeader, testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest || h.units.running[0] {
		t.Fatalf("secret with a newline: %d", resp.StatusCode)
	}
}

func TestRegenerate(t *testing.T) {
	f := setup(t)
	l, control, view := f.create(t, "alice", "")
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
	if len(list) != 1 || list[0].links != l || list[0].Name != "Shop <b>" || list[0].Host != "atlas" {
		t.Fatalf("list %+v, created %+v", list, l)
	}
	page := f.page(t, "alice")
	for _, want := range []string{`href="` + l.Control + `"`, `href="` + l.View + `"`, "<code>" + l.MCP + "</code>", "Shop &lt;b&gt; <small>" + l.ID + "</small>", "On atlas, created"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %s", want)
		}
	}
	if strings.Contains(page, "not stored") {
		t.Error("page says a link of a new session is not stored")
	}
	if strings.Contains(page, "<select") {
		t.Error("page offers a choice of one host")
	}

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
		"id": "OLDSESSION", "owner": "alice", "host": "atlas", "slot": 0,
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

// atlas' sessions.json from when the gateway ran there, with "host" added
// by the migration: its links keep working through the gateway, and after a
// reboot atlas starts the slots it still has env files for.
func TestMigratedSessions(t *testing.T) {
	f := setupHosts(t, "atlas", "styx")
	atlas := f.hosts["atlas"]
	old := []map[string]any{{
		"id": "J5KQ2ZXW4M", "name": "shop", "owner": "alice", "slot": 0,
		"control_token": "OLDCONTROLTOKEN", "view_token": "OLDVIEWTOKEN",
		"control_password": "CPCPCPCPCPCPCPCPCP", "view_password": "VPVPVPVPVPVPVPVPVP", "mcp_token": "MTMTMTMTMTMTMTMTMT", "created": f.now,
	}}
	b, _ := json.Marshal(old)
	if err := os.WriteFile(f.s.statePath(), b, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := newServer(f.s.cfg); err == nil || !strings.Contains(err.Error(), "J5KQ2ZXW4M") {
		t.Fatalf("session without a host loaded: %v", err)
	}
	old[0]["host"] = "atlas"
	b, _ = json.Marshal(old)
	os.WriteFile(f.s.statePath(), b, 0o600)
	os.WriteFile(atlas.b.envPath(0), []byte("NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=CPCPCPCPCPCPCPCPCP\n"), 0o600)
	atlas.start(t, atlas.b.cfg)
	f.start(t, f.s.cfg)

	if !atlas.units.running[0] || f.hosts["styx"].units.running[0] {
		t.Fatal("reboot did not start exactly atlas' slot with an env file")
	}
	if status, body := f.do(t, "GET", "/s/OLDCONTROLTOKEN/assets/x", "", ""); status != 200 || body != "backend /assets/x" {
		t.Fatalf("old control link: %d %s", status, body)
	}
	if status, _ := f.do(t, "POST", "/s/OLDCONTROLTOKEN/mcp", "", "{}"); status != 200 {
		t.Fatalf("old MCP link: %d", status)
	}
	if req, _ := atlas.mcp.last(); req.Header.Get("Authorization") != "Bearer MTMTMTMTMTMTMTMTMT" {
		t.Fatalf("old MCP token %q", req.Header.Get("Authorization"))
	}
	if list := f.sessions(t, "alice"); len(list) != 1 || list[0].Host != "atlas" || list[0].Name != "shop" || list[0].View != "https://browser.example/s/OLDVIEWTOKEN/" {
		t.Fatalf("list %+v", list)
	}
}

// The owner picks the host; links do not show it, the gateway routes them.
func TestHosts(t *testing.T) {
	f := setupHosts(t, "atlas", "styx")
	atlas, styx := f.hosts["atlas"], f.hosts["styx"]

	if status, _ := f.post(t, "/sessions", "alice", nil); status != http.StatusBadRequest {
		t.Fatalf("create without a host of two: %d", status)
	}
	if status, _ := f.post(t, "/sessions", "alice", url.Values{"host": {"nowhere"}}); status != http.StatusBadRequest {
		t.Fatalf("create on an unknown host: %d", status)
	}
	f.now = f.now.Add(time.Minute)
	la, ca, _ := f.create(t, "alice", "atlas")
	f.now = f.now.Add(time.Minute)
	ls, cs, vs := f.create(t, "alice", "styx")
	if !atlas.units.running[0] || !styx.units.running[0] {
		t.Fatalf("units: atlas %v, styx %v", atlas.units.running, styx.units.running)
	}
	for _, tok := range []string{cs, vs} {
		if strings.Contains(tok, "styx") {
			t.Fatalf("link names its host: %s", tok)
		}
	}

	// each link reaches its host's slot
	f.do(t, "GET", "/s/"+ca+"/on-atlas", "", "")
	f.do(t, "GET", "/s/"+vs+"/on-styx", "", "")
	if req, _ := atlas.neko.last(); req.URL.Path != "/on-atlas" || len(atlas.neko.reqs) != 1 {
		t.Fatalf("atlas neko got %s", req.URL.Path)
	}
	if req, _ := styx.neko.last(); req.URL.Path != "/on-styx" || len(styx.neko.reqs) != 1 {
		t.Fatalf("styx neko got %s", req.URL.Path)
	}
	f.do(t, "POST", "/s/"+cs+"/mcp", "", "{}")
	if req, _ := styx.mcp.last(); req.Header.Get("Authorization") != "Bearer "+f.s.sessions[ls.ID].MCPToken || len(atlas.mcp.reqs) != 0 {
		t.Fatal("styx MCP request went wrong")
	}

	list := f.sessions(t, "alice")
	if len(list) != 2 || list[0].ID != la.ID || list[0].Host != "atlas" || list[1].ID != ls.ID || list[1].Host != "styx" {
		t.Fatalf("list %+v", list)
	}
	page := f.page(t, "alice")
	for _, want := range []string{`<select name="host"><option>atlas</option><option>styx</option></select>`, "On atlas, created", "On styx, created"} {
		if !strings.Contains(page, want) {
			t.Errorf("page lacks %s", want)
		}
	}

	// slots are per host
	if status, body := f.post(t, "/sessions", "bob", url.Values{"host": {"styx"}}); status != http.StatusServiceUnavailable {
		t.Fatalf("second session on full styx: %d %s", status, body)
	}

	// kill reaches the session's host only
	if status, _ := f.do(t, "POST", "/sessions/"+ls.ID+"/kill", "alice", ""); status != http.StatusNoContent {
		t.Fatalf("kill: %d", status)
	}
	if styx.units.running[0] || !styx.units.cleaned[0] || !atlas.units.running[0] {
		t.Fatalf("after kill: atlas %v, styx %v", atlas.units.running, styx.units.running)
	}
	if _, err := os.Stat(styx.b.envPath(0)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("env file of the killed session: %v", err)
	}

	// a host that is down fails the create and leaves the slot free
	styx.web.Close()
	if status, _ := f.post(t, "/sessions", "alice", url.Values{"host": {"styx"}}); status != http.StatusInternalServerError {
		t.Fatalf("create on a host that is down: %d", status)
	}
	if list := f.sessions(t, "alice"); len(list) != 1 {
		t.Fatalf("failed create left %+v", list)
	}
	f.start(t, f.s.cfg)
	if len(f.s.sessions) != 1 {
		t.Fatal("failed create was saved")
	}
}

func TestRename(t *testing.T) {
	f := setup(t)
	l, _, _ := f.create(t, "alice", "")
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
	l, control, _ := f.create(t, "alice", "")

	// sessions have no expiry: a gateway restart much later still has it
	f.now = f.now.Add(365 * 24 * time.Hour)
	s2, err := newServer(f.s.cfg)
	if err != nil {
		t.Fatal(err)
	}
	if se, r, ok := s2.lookup(control); !ok || r != controller || se.ID != l.ID {
		t.Fatal("session lost on restart")
	}

	// a failed stop/clean keeps the session, so the slot never reuses old state
	f.units.fail = errors.New("clean failed")
	if status, body := f.do(t, "POST", "/sessions/"+l.ID+"/kill", "alice", ""); status != http.StatusInternalServerError || !strings.Contains(body, "clean failed") {
		t.Fatalf("kill with failing clean: %d %s", status, body)
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
	if _, err := os.Stat(f.hosts["atlas"].b.envPath(0)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("env file of the killed session: %v", err)
	}
	if status, _ := f.do(t, "GET", "/s/"+control+"/", "", ""); status != 404 {
		t.Fatalf("token of a killed session: %d", status)
	}
	// the slot is free again
	f.create(t, "bob", "")
}

func TestSlotsAndOwners(t *testing.T) {
	f := setup(t)
	l, _, _ := f.create(t, "alice", "")
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

// neko's API runs over a websocket, through the gateway and the backend.
func TestWebsocket(t *testing.T) {
	f := setup(t)
	_, control, _ := f.create(t, "alice", "")
	f.neko.srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" || r.URL.Path != "/api/ws" {
			http.Error(w, "no upgrade", http.StatusBadRequest)
			return
		}
		conn, rw, err := http.NewResponseController(w).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
		rw.Flush()
		line, _ := rw.ReadString('\n')
		rw.WriteString("echo " + line)
		rw.Flush()
	})
	conn, err := net.Dial("tcp", f.web.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprintf(conn, "GET /s/%s/api/ws HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", control)
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil || resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade: %v %v", resp, err)
	}
	fmt.Fprint(conn, "hello\n")
	if line, err := br.ReadString('\n'); line != "echo hello\n" {
		t.Fatalf("through the websocket: %q %v", line, err)
	}
}

func TestMask(t *testing.T) {
	var buf bytes.Buffer
	maskWriter{&buf}.Write([]byte("GET /s/ABCDEF234/api/ws?x=1 and /s/QWERTY/mcp\n"))
	if got := buf.String(); got != "GET /s/***/api/ws?x=1 and /s/***/mcp\n" {
		t.Fatalf("mask: %q", got)
	}
}
