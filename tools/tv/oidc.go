package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	sessionCookie = "tv_session"
	loginCookie   = "tv_login"
	sessionTTL    = 30 * 24 * time.Hour
	loginTTL      = 10 * time.Minute
)

// session is a logged-in user, in the signed session cookie.
type session struct {
	Sub  string `json:"sub"`
	Name string `json:"name"`
	Exp  int64  `json:"exp"`
}

// login is a login on its way through the issuer, in the signed login
// cookie until the callback.
type login struct {
	State    string `json:"state"`
	Verifier string `json:"verifier"`
	Exp      int64  `json:"exp"`
}

// cookieKey reads the key that signs cookies, creating a random one first.
func cookieKey(path string) ([]byte, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		b = []byte(rand.Text() + rand.Text())
		err = os.WriteFile(path, b, 0o600)
	}
	return b, err
}

// sign encodes v as base64 JSON with an HMAC of it.
func (s *server) sign(v any) string {
	b, _ := json.Marshal(v)
	payload := base64.RawURLEncoding.EncodeToString(b)
	mac := hmac.New(sha256.New, s.cookieKey)
	mac.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// verify decodes a value made by sign into v; false if it was tampered with.
func (s *server) verify(value string, v any) bool {
	payload, sig, ok := strings.Cut(value, ".")
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if !ok || err != nil || len(s.cookieKey) == 0 {
		return false
	}
	mac := hmac.New(sha256.New, s.cookieKey)
	mac.Write([]byte(payload))
	if !hmac.Equal(got, mac.Sum(nil)) {
		return false
	}
	b, err := base64.RawURLEncoding.DecodeString(payload)
	return err == nil && json.Unmarshal(b, v) == nil
}

func setCookie(w http.ResponseWriter, name, value, path string, ttl time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: path, MaxAge: int(ttl / time.Second),
		HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode})
}

// editor returns who may edit the schedule: "admin" for the admin key, the
// name of a logged-in user, or "" for nobody.
func (s *server) editor(r *http.Request) string {
	if s.isAdmin(r) {
		return "admin"
	}
	var se session
	if c, err := r.Cookie(sessionCookie); err == nil && s.verify(c.Value, &se) && se.Exp > nowMs() {
		return se.Name
	}
	return ""
}

type oidcProvider struct {
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	UserinfoEndpoint      string `json:"userinfo_endpoint"`
}

// fetchJSON sends req and decodes its JSON answer into v.
func fetchJSON(req *http.Request, v any) error {
	ctx, cancel := context.WithTimeout(req.Context(), 30*time.Second)
	defer cancel()
	resp, err := http.DefaultClient.Do(req.WithContext(ctx))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: %s", req.URL.Path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func (s *server) discover(ctx context.Context) (oidcProvider, error) {
	var p oidcProvider
	req, err := http.NewRequestWithContext(ctx, "GET", strings.TrimSuffix(s.cfg.OIDCIssuer, "/")+"/.well-known/openid-configuration", nil)
	if err == nil {
		err = fetchJSON(req, &p)
	}
	if err == nil && (p.AuthorizationEndpoint == "" || p.TokenEndpoint == "" || p.UserinfoEndpoint == "") {
		err = errors.New("the issuer's discovery lacks an endpoint")
	}
	return p, err
}

// handleLogin serves <secret>/login: off to the issuer with PKCE (S256)
// and a state, both kept in the login cookie for the callback.
func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	p, err := s.discover(r.Context())
	if err != nil {
		http.Error(w, "login: "+err.Error(), http.StatusBadGateway)
		return
	}
	l := login{State: rand.Text(), Verifier: rand.Text() + rand.Text(), Exp: nowMs() + loginTTL.Milliseconds()}
	setCookie(w, loginCookie, s.sign(l), s.callbackPath, loginTTL)
	challenge := sha256.Sum256([]byte(l.Verifier))
	q := url.Values{
		"response_type":         {"code"},
		"client_id":             {s.oidcClientID},
		"redirect_uri":          {s.cfg.OIDCRedirectURL},
		"scope":                 {"openid profile"},
		"state":                 {l.State},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(challenge[:])},
		"code_challenge_method": {"S256"},
	}
	http.Redirect(w, r, p.AuthorizationEndpoint+"?"+q.Encode(), http.StatusFound)
}

// handleCallback serves the redirect URI: it checks the state against the
// login cookie, trades the code for an access token, asks the userinfo
// endpoint who it is and sets the session cookie.
func (s *server) handleCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var l login
	c, err := r.Cookie(loginCookie)
	if err != nil || !s.verify(c.Value, &l) || l.Exp < nowMs() || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(l.State)) != 1 {
		http.Error(w, "login: expired or not started here, try again", http.StatusBadRequest)
		return
	}
	setCookie(w, loginCookie, "", s.callbackPath, -1)
	if e := q.Get("error"); e != "" {
		http.Error(w, "login refused: "+e+" "+q.Get("error_description"), http.StatusForbidden)
		return
	}
	se, err := s.identify(r.Context(), q.Get("code"), l.Verifier)
	if err != nil {
		log.Printf("login: %v", err)
		http.Error(w, "login: "+err.Error(), http.StatusBadGateway)
		return
	}
	setCookie(w, sessionCookie, s.sign(se), "/"+s.secret+"/", sessionTTL)
	log.Printf("login: %s (%s)", se.Name, se.Sub)
	http.Redirect(w, r, "/"+s.secret+"/schedule", http.StatusSeeOther)
}

// identify trades an authorization code for the user's session.
func (s *server) identify(ctx context.Context, code, verifier string) (session, error) {
	p, err := s.discover(ctx)
	if err != nil {
		return session{}, err
	}
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {s.cfg.OIDCRedirectURL},
		"client_id":     {s.oidcClientID},
		"code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, "POST", p.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return session{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var token struct {
		AccessToken string `json:"access_token"`
	}
	if err := fetchJSON(req, &token); err != nil {
		return session{}, err
	}
	if req, err = http.NewRequestWithContext(ctx, "GET", p.UserinfoEndpoint, nil); err != nil {
		return session{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
	var user struct {
		Sub               string `json:"sub"`
		Name              string `json:"name"`
		PreferredUsername string `json:"preferred_username"`
	}
	if err := fetchJSON(req, &user); err != nil {
		return session{}, err
	}
	if user.Sub == "" {
		return session{}, errors.New("userinfo without a sub")
	}
	name := user.Name
	for _, n := range []string{user.PreferredUsername, user.Sub} {
		if name == "" {
			name = n
		}
	}
	return session{Sub: user.Sub, Name: name, Exp: nowMs() + sessionTTL.Milliseconds()}, nil
}
