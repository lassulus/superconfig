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
	ownerCookie = "browser_sessions"
	loginCookie = "browser_sessions_login"
	ownerTTL    = 7 * 24 * time.Hour
	loginTTL    = 10 * time.Minute
)

// owner is a logged-in user in the signed owner cookie, by OIDC sub.
type owner struct {
	Sub string `json:"sub"`
	Exp int64  `json:"exp"`
}

// login is a login on its way through the issuer.
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

func (s *server) sign(v any) string {
	b, _ := json.Marshal(v)
	payload := base64.RawURLEncoding.EncodeToString(b)
	mac := hmac.New(sha256.New, s.cookieKey)
	mac.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *server) verify(value string, v any) bool {
	payload, sig, ok := strings.Cut(value, ".")
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if !ok || err != nil {
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

func (s *server) setCookie(w http.ResponseWriter, name, value string, ttl time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", MaxAge: int(ttl / time.Second),
		HttpOnly: true, Secure: s.secure, SameSite: http.SameSiteLaxMode})
}

// owner returns the OIDC sub of the logged-in user, or "".
func (s *server) owner(r *http.Request) string {
	var o owner
	if c, err := r.Cookie(ownerCookie); err == nil && s.verify(c.Value, &o) && o.Exp > s.now().Unix() {
		return o.Sub
	}
	return ""
}

type oidcProvider struct {
	AuthorizationEndpoint string `json:"authorization_endpoint"`
	TokenEndpoint         string `json:"token_endpoint"`
	UserinfoEndpoint      string `json:"userinfo_endpoint"`
}

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

func (s *server) redirectURL() string { return s.cfg.URL + "/callback" }

// handleLogin sends the browser to the issuer with PKCE (S256) and a state,
// both kept in the login cookie for the callback.
func (s *server) handleLogin(w http.ResponseWriter, r *http.Request) {
	p, err := s.discover(r.Context())
	if err != nil {
		http.Error(w, "login: "+err.Error(), http.StatusBadGateway)
		return
	}
	l := login{State: rand.Text(), Verifier: rand.Text() + rand.Text(), Exp: s.now().Add(loginTTL).Unix()}
	s.setCookie(w, loginCookie, s.sign(l), loginTTL)
	challenge := sha256.Sum256([]byte(l.Verifier))
	q := url.Values{
		"response_type":         {"code"},
		"client_id":             {s.oidcClientID},
		"redirect_uri":          {s.redirectURL()},
		"scope":                 {"openid"},
		"state":                 {l.State},
		"code_challenge":        {base64.RawURLEncoding.EncodeToString(challenge[:])},
		"code_challenge_method": {"S256"},
	}
	http.Redirect(w, r, p.AuthorizationEndpoint+"?"+q.Encode(), http.StatusFound)
}

// handleCallback checks the state, trades the code for an access token and
// asks the userinfo endpoint for the sub.
func (s *server) handleCallback(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var l login
	c, err := r.Cookie(loginCookie)
	if err != nil || !s.verify(c.Value, &l) || l.Exp < s.now().Unix() || subtle.ConstantTimeCompare([]byte(q.Get("state")), []byte(l.State)) != 1 {
		http.Error(w, "login: expired or not started here, try again", http.StatusBadRequest)
		return
	}
	s.setCookie(w, loginCookie, "", -1)
	if e := q.Get("error"); e != "" {
		http.Error(w, "login refused: "+e+" "+q.Get("error_description"), http.StatusForbidden)
		return
	}
	sub, err := s.identify(r.Context(), q.Get("code"), l.Verifier)
	if err != nil {
		log.Printf("login: %v", err)
		http.Error(w, "login: "+err.Error(), http.StatusBadGateway)
		return
	}
	s.setCookie(w, ownerCookie, s.sign(owner{Sub: sub, Exp: s.now().Add(ownerTTL).Unix()}), ownerTTL)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

func (s *server) identify(ctx context.Context, code, verifier string) (string, error) {
	p, err := s.discover(ctx)
	if err != nil {
		return "", err
	}
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"redirect_uri":  {s.redirectURL()},
		"client_id":     {s.oidcClientID},
		"code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, "POST", p.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	var token struct {
		AccessToken string `json:"access_token"`
	}
	if err := fetchJSON(req, &token); err != nil {
		return "", err
	}
	if req, err = http.NewRequestWithContext(ctx, "GET", p.UserinfoEndpoint, nil); err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+token.AccessToken)
	var user struct {
		Sub string `json:"sub"`
	}
	if err := fetchJSON(req, &user); err != nil {
		return "", err
	}
	if user.Sub == "" {
		return "", errors.New("userinfo without a sub")
	}
	return user.Sub, nil
}

func (s *server) handleLogout(w http.ResponseWriter, r *http.Request) {
	s.setCookie(w, ownerCookie, "", -1)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}
