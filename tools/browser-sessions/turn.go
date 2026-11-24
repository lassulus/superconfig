package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"regexp"
	"strconv"
	"time"
)

// TURN for the viewers' browsers that cannot reach a host's WebRTC ports
// (UDP or TCP) directly. neko hands its frontend ICE servers to every
// browser that connects and cannot be given new ones while it runs, so the
// gateway puts the TURN server with fresh credentials into a session's
// secrets each time it starts the session's unit, and they stay valid for
// ttl_hours from then. The credentials are those of coturn's REST API
// (use-auth-secret): the username is the expiry and the session id, the
// password the HMAC-SHA1 of the username with the secret coturn has.

type turnConfig struct {
	// turn: and turns: URLs of the server; no TURN if empty
	URLs []string `json:"urls"`
	// coturn's static-auth-secret
	SecretFile string `json:"secret_file"`
	TTLHours   int    `json:"ttl_hours"`
}

// iceServer is one of neko's ICE servers (webrtc.iceservers.frontend).
type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

// turnCredentials are the TURN REST API credentials of user until expires.
func turnCredentials(secret []byte, user string, expires time.Time) (username, credential string) {
	username = strconv.FormatInt(expires.Unix(), 10) + ":" + user
	mac := hmac.New(sha1.New, secret)
	mac.Write([]byte(username))
	return username, base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

// the ICE servers go into an env file as single-quoted JSON: no quotes,
// backslashes or spaces in their fields
var iceChars = regexp.MustCompile(`^[A-Za-z0-9.:?=/+\[\]-]+$`)

func (i iceServer) valid() bool {
	if len(i.URLs) == 0 {
		return false
	}
	for _, u := range i.URLs {
		if !iceChars.MatchString(u) {
			return false
		}
	}
	return (i.Username == "" || iceChars.MatchString(i.Username)) && (i.Credential == "" || iceChars.MatchString(i.Credential))
}
