package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The backend runs the session units of one host for the gateway: it
// starts a slot's unit with the session's secrets, stops it and deletes its
// state, and passes the gateway's requests on to the slot's neko and
// browser-mcp, which listen on localhost only. Every request needs the
// token shared with the gateway.

// tokenHeader carries the token the gateway and the backends share.
const tokenHeader = "Browser-Sessions-Token"

type backendConfig struct {
	Listen    string `json:"listen"`
	StateDir  string `json:"state_dir"`
	TokenFile string `json:"token_file"`
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

// secrets are what a slot's unit gets from the gateway: the neko passwords
// of both roles and browser-mcp's token.
type secrets struct {
	ControlPassword string `json:"control_password"`
	ViewPassword    string `json:"view_password"`
	MCPToken        string `json:"mcp_token"`
}

// they go into an env file, so nothing but letters and digits
var secretChars = regexp.MustCompile(`^[A-Za-z0-9]{16,}$`)

func (s secrets) valid() bool {
	return secretChars.MatchString(s.ControlPassword) && secretChars.MatchString(s.ViewPassword) && secretChars.MatchString(s.MCPToken)
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

type backendServer struct {
	cfg   backendConfig
	units units
	token []byte
}

func newBackend(cfg backendConfig, u units) (*backendServer, error) {
	if cfg.Unit == "" || len(cfg.Slots) == 0 {
		return nil, errors.New("backend config needs unit and slots")
	}
	token, err := readSecret(cfg.TokenFile)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "slots"), 0o700); err != nil {
		return nil, err
	}
	return &backendServer{cfg: cfg, units: u, token: token}, nil
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

// startAll starts the units of the slots that have a session, as after a
// reboot; they come back with their state.
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
	mux.HandleFunc("PUT /slots/{slot}", b.handleStart)
	mux.HandleFunc("DELETE /slots/{slot}", b.handleRemove)
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

// handleStart writes the slot's env file and starts its unit.
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
	env := fmt.Sprintf("NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD=%s\nNEKO_MEMBER_MULTIUSER_USER_PASSWORD=%s\nBROWSER_MCP_TOKEN=%s\n",
		sec.ControlPassword, sec.ViewPassword, sec.MCPToken)
	if err := os.WriteFile(b.envPath(i), []byte(env), 0o600); err != nil {
		log.Printf("slot %d: %v", i, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := b.units.Start(i); err != nil {
		os.Remove(b.envPath(i))
		log.Printf("slot %d: %v", i, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("slot %d: started", i)
	w.WriteHeader(http.StatusNoContent)
}

// handleRemove stops the slot's unit and deletes its state for good.
func (b *backendServer) handleRemove(w http.ResponseWriter, r *http.Request) {
	i, ok := b.slot(w, r)
	if !ok {
		return
	}
	if err := b.units.Remove(i); err != nil {
		log.Printf("slot %d: %v", i, err)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	os.Remove(b.envPath(i))
	log.Printf("slot %d: removed", i)
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
