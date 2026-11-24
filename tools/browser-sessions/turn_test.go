package main

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

func TestTURNCredentials(t *testing.T) {
	// printf %s 1800604800:SESSIONID1 | openssl dgst -sha1 -hmac <secret> -binary | base64
	user, cred := turnCredentials([]byte("coturn-secret-coturn-secret-coturn-secret"), "SESSIONID1", time.Unix(1_800_604_800, 0))
	if user != "1800604800:SESSIONID1" || cred != "mGI83760ewqHuIYdzUhAVpvTP3s=" {
		t.Fatalf("credentials %q %q", user, cred)
	}
}

func TestTURN(t *testing.T) {
	f := setup(t)
	secretFile := t.TempDir() + "/turn-secret"
	if err := os.WriteFile(secretFile, []byte("coturn-secret-coturn-secret-coturn-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := f.s.cfg
	cfg.TURN = turnConfig{
		URLs:       []string{"turns:turn.example:443?transport=tcp", "turn:turn.example:3478?transport=udp"},
		SecretFile: secretFile,
		TTLHours:   168,
	}
	f.start(t, cfg)
	l, _, _ := f.create(t, "alice", "")

	// neko reads its frontend ICE servers from the slot's env file
	env, err := os.ReadFile(f.hosts["atlas"].b.envPath(0))
	if err != nil {
		t.Fatal(err)
	}
	var value string
	for line := range strings.Lines(string(env)) {
		if v, ok := strings.CutPrefix(line, "NEKO_WEBRTC_ICESERVERS_FRONTEND='"); ok {
			value, _ = strings.CutSuffix(v, "'\n")
		}
	}
	var servers []iceServer
	if err := json.Unmarshal([]byte(value), &servers); err != nil || len(servers) != 1 {
		t.Fatalf("ICE servers in %q: %v", env, err)
	}
	user, cred := turnCredentials([]byte("coturn-secret-coturn-secret-coturn-secret"), l.ID, f.now.Add(168*time.Hour))
	if s := servers[0]; strings.Join(s.URLs, " ") != strings.Join(cfg.TURN.URLs, " ") || s.Username != user || s.Credential != cred {
		t.Fatalf("ICE server %+v, want %s %s", s, user, cred)
	}

	// nothing in them may end the quoted value or the line
	for _, ice := range []string{`{"urls":["turn:x'"]}`, `{"urls":["turn:x\nLD_PRELOAD=y"]}`, `{"urls":["turn:x"],"credential":"a b"}`, `{"urls":[]}`} {
		req, _ := http.NewRequest("PUT", f.hosts["atlas"].web.URL+"/slots/0", strings.NewReader(`{"control_password":"AAAAAAAAAAAAAAAA","view_password":"AAAAAAAAAAAAAAAA","mcp_token":"AAAAAAAAAAAAAAAA","ice_servers":[`+ice+`]}`))
		req.Header.Set(tokenHeader, testToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("ICE server %s: %d", ice, resp.StatusCode)
		}
	}
}
