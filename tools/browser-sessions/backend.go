package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The backend runs the session units of one host for the gateway: it
// starts a slot's unit with the session's secrets, stops it (keeping its
// state) or deletes its state, hands the state of a stopped slot out and
// takes one in as tars for moves between hosts, and passes the gateway's
// requests on to the slot's neko and browser-mcp, which listen on
// localhost only. Every request needs the token shared with the gateway.

// tokenHeader carries the token the gateway and the backends share.
const tokenHeader = "Browser-Sessions-Token"

type backendConfig struct {
	Listen    string `json:"listen"`
	StateDir  string `json:"state_dir"`
	TokenFile string `json:"token_file"`
	// units of slot i: fmt.Sprintf(Unit, i) runs the session; ExportUnit
	// writes its state as a tar to <state_dir>/transfer/<i>.tar, ImportUnit
	// extracts that file into it
	Unit       string `json:"unit"`
	ExportUnit string `json:"export_unit"`
	ImportUnit string `json:"import_unit"`
	Systemctl  string `json:"systemctl"`
	Slots      []slot `json:"slots"`
}

// slot is where one session runs: the localhost ports of its neko and its
// browser-mcp.
type slot struct {
	Neko int `json:"neko"`
	MCP  int `json:"mcp"`
}

// secrets are what a slot's unit gets from the gateway when it starts: the
// neko passwords of both roles, browser-mcp's token, the ICE servers (TURN
// with its credentials) neko gives the browsers and the URL of the proxy
// its Firefox goes out through ("" for none).
type secrets struct {
	ControlPassword string      `json:"control_password"`
	ViewPassword    string      `json:"view_password"`
	MCPToken        string      `json:"mcp_token"`
	ICEServers      []iceServer `json:"ice_servers,omitempty"`
	Proxy           string      `json:"proxy,omitempty"`
}

// they go into an env file, so nothing but letters and digits
var secretChars = regexp.MustCompile(`^[A-Za-z0-9]{16,}$`)

func (s secrets) valid() bool {
	for _, i := range s.ICEServers {
		if !i.valid() {
			return false
		}
	}
	return secretChars.MatchString(s.ControlPassword) && secretChars.MatchString(s.ViewPassword) && secretChars.MatchString(s.MCPToken)
}

// proxy is where a session's Firefox goes out: the kind of proxy (http,
// socks4 or socks5), its host and port.
type proxy struct {
	kind, host string
	port       int
}

// the host goes into an env file: a name or an IPv4 or IPv6 address
var proxyHostChars = regexp.MustCompile(`^[A-Za-z0-9.:-]+$`)

// parseProxy takes a proxy URL: http://, socks4://, socks5:// or socks5h://
// with a host and a port and nothing else. Firefox resolves names through
// SOCKS proxies either way. Proxy logins (user:password@) are refused:
// Firefox's prefs hold no credentials.
func parseProxy(raw string) (proxy, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return proxy{}, errors.New("not a URL")
	}
	if u.User != nil {
		return proxy{}, errors.New("proxy logins are not supported")
	}
	kind := map[string]string{"http": "http", "socks4": "socks4", "socks5": "socks5", "socks5h": "socks5"}[u.Scheme]
	port, perr := strconv.Atoi(u.Port())
	if kind == "" || !proxyHostChars.MatchString(u.Hostname()) || perr != nil || port < 1 || port > 65535 ||
		u.Opaque != "" || (u.Path != "" && u.Path != "/") || u.RawQuery != "" || u.Fragment != "" {
		return proxy{}, errors.New("want http://, socks4://, socks5:// or socks5h://<host>:<port>, nothing more")
	}
	return proxy{kind, u.Hostname(), port}, nil
}

// env are the lines of the slot's env file that hand the proxy to the
// session's Firefox (module.nix); none for no proxy.
func (p proxy) env() string {
	if p.kind == "" {
		return ""
	}
	return fmt.Sprintf("BROWSER_SESSION_PROXY_TYPE=%s\nBROWSER_SESSION_PROXY_HOST=%s\nBROWSER_SESSION_PROXY_PORT=%d\n", p.kind, p.host, p.port)
}

// units runs the systemd units of the slots.
type units interface {
	Start(slot int) error
	// Stop stops the session and keeps its state.
	Stop(slot int) error
	// Clean deletes the state of a stopped slot.
	Clean(slot int) error
	Active(slot int) (bool, error)
	// Export writes a tar of a stopped slot's state to w; Import replaces
	// the state of a stopped slot with the tar from r.
	Export(slot int, w io.Writer) error
	Import(slot int, r io.Reader) error
}

type systemctl struct {
	bin, unit, exportUnit, importUnit string
	// where the export and import units find the tar of slot i: i.tar
	transferDir string
}

func (s systemctl) run(unit string, slot int, args ...string) (string, error) {
	out, err := exec.Command(s.bin, append(args, fmt.Sprintf(unit, slot))...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("systemctl %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func (s systemctl) Start(slot int) error {
	_, err := s.run(s.unit, slot, "start")
	return err
}

func (s systemctl) Stop(slot int) error {
	_, err := s.run(s.unit, slot, "stop")
	return err
}

func (s systemctl) Clean(slot int) error {
	_, err := s.run(s.unit, slot, "clean", "--what=state")
	return err
}

func (s systemctl) Active(slot int) (bool, error) {
	state, err := s.run(s.unit, slot, "show", "--property=ActiveState", "--value")
	return state != "inactive" && state != "failed", err
}

func (s systemctl) transferPath(slot int) string {
	return filepath.Join(s.transferDir, fmt.Sprintf("%d.tar", slot))
}

// Export runs the export unit, which writes the tar into the file this
// creates (systemd opens it for the unit, as root, so it stays this
// user's), and copies it to w.
func (s systemctl) Export(slot int, w io.Writer) error {
	path := s.transferPath(slot)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	defer f.Close()
	if _, err := s.run(s.exportUnit, slot, "start"); err != nil {
		return err
	}
	_, err = io.Copy(w, f)
	return err
}

// Import writes the tar from r to the file the import unit reads, deletes
// the slot's old state and runs the import unit.
func (s systemctl) Import(slot int, r io.Reader) error {
	path := s.transferPath(slot)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	_, err = io.Copy(f, r)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if err := s.Clean(slot); err != nil {
		return err
	}
	_, err = s.run(s.importUnit, slot, "start")
	return err
}

type backendServer struct {
	cfg   backendConfig
	units units
	token []byte
	// answers tells whether a slot's neko and browser-mcp take connections
	answers func(slot int) bool
}

func newBackend(cfg backendConfig, u units) (*backendServer, error) {
	if cfg.Unit == "" || cfg.ExportUnit == "" || cfg.ImportUnit == "" || len(cfg.Slots) == 0 {
		return nil, errors.New("backend config needs unit, export_unit, import_unit and slots")
	}
	token, err := readSecret(cfg.TokenFile)
	if err != nil {
		return nil, err
	}
	for _, dir := range []string{"slots", "transfer"} {
		if err := os.MkdirAll(filepath.Join(cfg.StateDir, dir), 0o700); err != nil {
			return nil, err
		}
	}
	b := &backendServer{cfg: cfg, units: u, token: token}
	b.answers = b.listening
	return b, nil
}

// listening tells whether the slot's neko and browser-mcp take connections.
func (b *backendServer) listening(slot int) bool {
	for _, port := range []int{b.cfg.Slots[slot].Neko, b.cfg.Slots[slot].MCP} {
		c, err := net.DialTimeout("tcp", localhost(port).Host, time.Second)
		if err != nil {
			return false
		}
		c.Close()
	}
	return true
}

// readSecret reads a key or token of at least 32 bytes.
func readSecret(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	b = []byte(strings.TrimSpace(string(b)))
	if err == nil && len(b) < 32 {
		err = fmt.Errorf("%s: shorter than 32 bytes", path)
	}
	return b, err
}

func (b *backendServer) envPath(slot int) string {
	return filepath.Join(b.cfg.StateDir, "slots", fmt.Sprintf("%d.env", slot))
}

// startAll starts the units of the slots that have a running session, as
// after a reboot; they come back with their state. A stopped session has no
// env file.
func (b *backendServer) startAll() {
	for i := range b.cfg.Slots {
		if _, err := os.Stat(b.envPath(i)); err != nil {
			continue
		}
		if err := b.units.Start(i); err != nil {
			log.Printf("slot %d: %v", i, err)
		}
	}
}

func (b *backendServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /slots/{slot}", b.handleReady)
	mux.HandleFunc("PUT /slots/{slot}", b.handleStart)
	mux.HandleFunc("POST /slots/{slot}/stop", b.handleStop)
	mux.HandleFunc("DELETE /slots/{slot}", b.handleRemove)
	mux.HandleFunc("GET /slots/{slot}/state", b.handleExport)
	mux.HandleFunc("PUT /slots/{slot}/state", b.handleImport)
	mux.HandleFunc("/slots/{slot}/mcp", b.handleMCP)
	mux.HandleFunc("/slots/{slot}/neko/{rest...}", b.handleNeko)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get(tokenHeader)), b.token) != 1 {
			http.Error(w, "wrong token", http.StatusUnauthorized)
			return
		}
		r.Header.Del(tokenHeader)
		mux.ServeHTTP(w, r)
	})
}

// slot returns the slot number of the request, or answers 404.
func (b *backendServer) slot(w http.ResponseWriter, r *http.Request) (int, bool) {
	i, err := strconv.Atoi(r.PathValue("slot"))
	if err != nil || i < 0 || i >= len(b.cfg.Slots) {
		http.NotFound(w, r)
		return 0, false
	}
	return i, true
}

// fail logs and answers an error of slot i.
func fail(w http.ResponseWriter, i int, status int, err error) {
	log.Printf("slot %d: %v", i, err)
	http.Error(w, err.Error(), status)
}

// stopped answers 409 unless slot i's unit is stopped.
func (b *backendServer) stopped(w http.ResponseWriter, i int) bool {
	active, err := b.units.Active(i)
	if err == nil && active {
		err = errors.New("the session runs")
	}
	if err != nil {
		fail(w, i, http.StatusConflict, err)
		return false
	}
	return true
}

// handleReady answers 204 once the slot's neko and browser-mcp take
// connections, else 503.
func (b *backendServer) handleReady(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok {
		return
	}
	if !b.answers(i) {
		http.Error(w, "starting", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleStart writes the slot's env file and starts its unit, with the
// state it has; ?fresh deletes that first, for a new session.
func (b *backendServer) handleStart(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok {
		return
	}
	var sec secrets
	if err := json.NewDecoder(io.LimitReader(r.Body, 64<<10)).Decode(&sec); err != nil || !sec.valid() {
		http.Error(w, "bad secrets", http.StatusBadRequest)
		return
	}
	var px proxy
	if sec.Proxy != "" {
		var err error
		if px, err = parseProxy(sec.Proxy); err != nil {
			http.Error(w, "bad proxy: "+err.Error(), http.StatusBadRequest)
			return
		}
	}
	if r.URL.Query().Has("fresh") {
		if !b.stopped(w, i) {
			return
		}
		if err := b.units.Clean(i); err != nil {
			fail(w, i, http.StatusInternalServerError, err)
			return
		}
	}
	env := fmt.Sprintf("NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=%s\nNEKO_MEMBER_MULTIUSER_USER_PASSWORD=%s\nBROWSER_MCP_TOKEN=%s\n%s",
		sec.ControlPassword, sec.ViewPassword, sec.MCPToken, px.env())
	if len(sec.ICEServers) > 0 {
		ice, _ := json.Marshal(sec.ICEServers)
		env += "NEKO_WEBRTC_ICESERVERS_FRONTEND='" + string(ice) + "'\n"
	}
	if err := os.WriteFile(b.envPath(i), []byte(env), 0o600); err != nil {
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	if err := b.units.Start(i); err != nil {
		os.Remove(b.envPath(i))
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	log.Printf("slot %d: started", i)
	w.WriteHeader(http.StatusNoContent)
}

// handleStop stops the slot's unit and keeps its state; without its env
// file it stays stopped across reboots.
func (b *backendServer) handleStop(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok {
		return
	}
	if err := b.units.Stop(i); err != nil {
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	os.Remove(b.envPath(i))
	log.Printf("slot %d: stopped", i)
	w.WriteHeader(http.StatusNoContent)
}

// handleRemove stops the slot's unit and deletes its state for good.
func (b *backendServer) handleRemove(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok {
		return
	}
	err := b.units.Stop(i)
	if err == nil {
		err = b.units.Clean(i)
	}
	if err != nil {
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	os.Remove(b.envPath(i))
	log.Printf("slot %d: removed", i)
	w.WriteHeader(http.StatusNoContent)
}

// writeTracker tells whether anything went out yet.
type writeTracker struct {
	http.ResponseWriter
	wrote bool
}

func (t *writeTracker) Write(p []byte) (int, error) {
	t.wrote = true
	return t.ResponseWriter.Write(p)
}

// handleExport sends the state of a stopped slot as a tar.
func (b *backendServer) handleExport(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok || !b.stopped(w, i) {
		return
	}
	w.Header().Set("Content-Type", "application/x-tar")
	t := &writeTracker{ResponseWriter: w}
	if err := b.units.Export(i, t); err != nil {
		if t.wrote {
			// a cut stream must not look complete
			log.Printf("slot %d: export: %v", i, err)
			panic(http.ErrAbortHandler)
		}
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	log.Printf("slot %d: exported", i)
}

// handleImport replaces the state of a stopped slot with the tar sent.
func (b *backendServer) handleImport(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok || !b.stopped(w, i) {
		return
	}
	if err := b.units.Import(i, r.Body); err != nil {
		fail(w, i, http.StatusInternalServerError, err)
		return
	}
	log.Printf("slot %d: imported", i)
	w.WriteHeader(http.StatusNoContent)
}

func (b *backendServer) handleMCP(w http.ResponseWriter, r *http.Request) {
	if i, ok := b.slot(w, r); ok {
		forward(localhost(b.cfg.Slots[i].MCP), "/mcp", nil).ServeHTTP(w, r)
	}
}

func (b *backendServer) handleNeko(w http.ResponseWriter, r *http.Request) {
	if i, ok := b.slot(w, r); ok {
		forward(localhost(b.cfg.Slots[i].Neko), "/"+r.PathValue("rest"), nil).ServeHTTP(w, r)
	}
}

func localhost(port int) *url.URL {
	return &url.URL{Scheme: "http", Host: "127.0.0.1:" + strconv.Itoa(port)}
}

// forward proxies to path on target, keeping the gateway's X-Forwarded
// headers; edit may change the outgoing request further.
func forward(target *url.URL, path string, edit func(*http.Request)) *httputil.ReverseProxy {
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.URL.Path, pr.Out.URL.RawPath = path, ""
			for _, h := range []string{"X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto"} {
				if v := pr.In.Header.Values(h); len(v) > 0 {
					pr.Out.Header[h] = v
				}
			}
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
