# Plays a video link on Kodi (./tv.nix). Home Assistant (./tv-hass.nix)
# POSTs {"url": "..."} to /play; yt-dlp resolves the link (YouTube and every
# other site it supports) and Kodi gets the stream through JSON-RPC
# Player.Open. Kodi's own YouTube add-on gets 403s from YouTube a few seconds
# into a video, yt-dlp keeps up with YouTube's changes. Prefers an HLS master
# playlist (all qualities and the audio in one URL), played through
# inputstream.adaptive: Kodi's ffmpeg demuxer opens every variant while
# probing and gives up after 30 s. Else the best single file with both audio
# and video. Kodi opens a one-entry .m3u written here: JSON-RPC can't set a
# title or an inputstream, #EXTINF and #KODIPROP lines can. Answers 200 with
# the video's title, or 4xx/5xx with the reason as text. Usage:
# tv-play PORT KODI_URL KODI_PASSWORD_FILE M3U_FILE
import base64
import json
import os
import subprocess
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
kodi_url = sys.argv[2]
with open(sys.argv[3]) as f:
    kodi_auth = "Basic " + base64.b64encode(b"kodi:" + f.read().strip().encode()).decode()
playlist = sys.argv[4]


def resolve(link):
    """(title, stream URL, whether it needs inputstream.adaptive)"""
    out = subprocess.run(
        ["yt-dlp", "--no-warnings", "--no-playlist", "--dump-single-json", "--", link],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if out.returncode != 0:
        raise ValueError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "yt-dlp failed")
    info = json.loads(out.stdout)
    title = " ".join((info.get("title") or link).split())
    formats = info.get("formats") or []
    for f in formats:
        if f.get("protocol") in ("m3u8", "m3u8_native") and f.get("manifest_url"):
            return title, f["manifest_url"], True
    muxed = [
        f
        for f in formats
        if f.get("url") and f.get("acodec") not in (None, "none") and f.get("vcodec") not in (None, "none")
    ]
    if muxed:
        return title, max(muxed, key=lambda f: (f.get("height") or 0, f.get("tbr") or 0))["url"], False
    if info.get("url"):
        return title, info["url"], False
    raise ValueError("no format with audio and video")


def write_playlist(title, stream, adaptive):
    lines = ["#EXTM3U", f"#EXTINF:-1,{title}"]
    if adaptive:
        lines.append("#KODIPROP:inputstream=inputstream.adaptive")
    lines.append(stream)
    tmp = playlist + ".tmp"
    with open(tmp, "w") as out:
        out.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, playlist)


def kodi_play(stream):
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "Player.Open", "params": {"item": {"file": stream}}}
    ).encode()
    req = urllib.request.Request(
        kodi_url,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": kodi_auth},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        reply = json.load(resp)
    if "error" in reply:
        raise RuntimeError(f"Kodi: {reply['error'].get('message')}")


class Handler(BaseHTTPRequestHandler):
    def answer(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/play":
            return self.answer(404, "not found")
        try:
            length = int(self.headers.get("Content-Length", 0))
            link = json.loads(self.rfile.read(length))["url"].strip()
        except (ValueError, KeyError, TypeError, AttributeError):
            return self.answer(400, 'expected JSON {"url": "..."}')
        if not link.startswith(("http://", "https://")):
            return self.answer(400, "not a link")
        try:
            title, stream, adaptive = resolve(link)
            write_playlist(title, stream, adaptive)
            kodi_play(playlist)
        except (ValueError, RuntimeError, subprocess.TimeoutExpired, OSError) as e:
            print(f"{link}: {e}", flush=True)
            return self.answer(502, str(e))
        print(f"{link}: playing {title}", flush=True)
        self.answer(200, title)


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
