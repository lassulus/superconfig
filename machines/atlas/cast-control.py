# Switch for the livestream unit of ./cast.nix, for Home Assistant
# (configs/hass/atlas-cast.nix). Every request needs
# "Authorization: Bearer <token>" with the token of the shared
# atlas-cast-control var. GET /cast answers on (the unit runs, starts or
# waits to be restarted) or off, POST /cast/start and /cast/stop start and
# stop it (allowed to this user by the polkit rule in ./cast.nix) and answer
# with the new state.
# Usage: atlas-cast-control PORT TOKEN_FILE UNIT
import hmac
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
with open(sys.argv[2]) as f:
    expected = f"Bearer {f.read().strip()}".encode()
unit = sys.argv[3]


def state():
    active = subprocess.run(
        ["systemctl", "is-active", unit], capture_output=True, text=True
    ).stdout.strip()
    return "on" if active in ("active", "activating", "reloading") else "off"


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, text):
        body = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        given = self.headers.get("Authorization", "").encode()
        if hmac.compare_digest(given, expected):
            return True
        self.reply(401, "unauthorized")
        return False

    def do_GET(self):
        if not self.authorized():
            return
        if self.path != "/cast":
            return self.reply(404, "not found")
        self.reply(200, state())

    def do_POST(self):
        if not self.authorized():
            return
        verb = {"/cast/start": "start", "/cast/stop": "stop"}.get(self.path)
        if verb is None:
            return self.reply(404, "not found")
        run = subprocess.run(
            ["systemctl", "--no-ask-password", verb, unit],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if run.returncode != 0:
            return self.reply(500, f"systemctl {verb} {unit}: {run.stderr.strip()}")
        self.reply(200, state())

    # Home Assistant polls every few seconds
    def log_message(self, format, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
