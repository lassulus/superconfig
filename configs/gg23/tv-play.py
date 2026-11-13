# Plays a video link on Kodi (./tv.nix). Home Assistant (./tv-hass.nix)
# POSTs {"url": "..."} to /play; yt-dlp resolves the link (YouTube and every
# other site it supports) and Kodi gets the stream through JSON-RPC
# Player.Open. Kodi's own YouTube add-on gets 403s from YouTube a few seconds
# into a video, yt-dlp keeps up with YouTube's changes. Prefers an HLS master
# playlist (all qualities and the audio in one URL), played through
# inputstream.adaptive: Kodi's ffmpeg demuxer opens every variant while
# probing and gives up after 30 s. YouTube's master lists two audio groups,
# AAC-LC and HE-AAC, both marked default; Kodi often picks the HE-AAC one and
# plays no sound, so tv-play serves Kodi a copy of the master without the
# HE-AAC variants at GET /master.m3u8. YouTube's audio renditions are raw
# ADTS segments named seg.ts; inputstream.adaptive takes the container from
# the extension, so it tries its TS reader first, and on some videos it then
# never delivers an audio sample after falling back to ADTS. So for YouTube
# the master's audio renditions point at GET /audio/N.m3u8, a copy of each
# playlist with the segments named seg.aac (googlevideo serves either name).
# Else the best single file with both audio and video. Kodi opens a one-entry
# .m3u written here: JSON-RPC can't set a title or an inputstream, #EXTINF and
# #KODIPROP lines can. Livestreams are the exception: YouTube serves their
# audio as a separate HLS track, which
# inputstream.adaptive stalls on after a few seconds ("stream stalled"), so
# for those ffmpeg copies the best video and audio track into one MPEG-TS
# stream that Kodi reads from GET /live.ts here. Answers 200 with the
# video's title, or 4xx/5xx with the reason as text. Usage:
# tv-play PORT KODI_URL KODI_PASSWORD_FILE M3U_FILE
import base64
import json
import os
import re
import subprocess
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
kodi_url = sys.argv[2]
with open(sys.argv[3]) as f:
    kodi_auth = "Basic " + base64.b64encode(b"kodi:" + f.read().strip().encode()).decode()
playlist = sys.argv[4]
live_ts = f"http://127.0.0.1:{port}/live.ts"
# input URLs of the current livestream, for GET /live.ts
live_inputs = []
master_url = f"http://127.0.0.1:{port}/master.m3u8"
# the current HLS master playlist, for GET /master.m3u8
master = ""
# upstream URLs of the current master's audio renditions, for GET /audio/N.m3u8
audio_playlists = []


def without_he_aac(text):
    """the HLS master without the variants with HE-AAC audio (mp4a.40.5) and the audio groups only they used"""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        if lines[i].startswith("#EXT-X-STREAM-INF:") and "mp4a.40.5" in lines[i]:
            i += 2  # the tag and its URI line
            continue
        out.append(lines[i])
        i += 1
    variants = [line for line in out if line.startswith("#EXT-X-STREAM-INF:")]
    if not variants:
        return text
    used = set(re.findall(r'AUDIO="([^"]*)"', "\n".join(variants)))

    def unused_audio(line):
        group = re.search(r'GROUP-ID="([^"]*)"', line)
        return line.startswith("#EXT-X-MEDIA:") and "TYPE=AUDIO" in line and group and group[1] not in used

    return "\n".join(line for line in out if not unused_audio(line)) + "\n"


def local_audio(text):
    """the HLS master with its audio renditions pointing at GET /audio/N.m3u8, and their upstream URLs"""
    upstream = []

    def local(m):
        upstream.append(m[1])
        return f'URI="http://127.0.0.1:{port}/audio/{len(upstream) - 1}.m3u8"'

    lines = [
        re.sub(r'URI="([^"]*)"', local, line)
        if line.startswith("#EXT-X-MEDIA:") and "TYPE=AUDIO" in line
        else line
        for line in text.splitlines()
    ]
    return "\n".join(lines) + "\n", upstream


def as_adts(text):
    """a YouTube audio playlist with its segments named seg.aac, for inputstream.adaptive's ADTS reader"""
    return re.sub(r"/file/seg\.ts$", "/file/seg.aac", text, flags=re.M)


def live_tracks(formats):
    """stream URLs of the best video and, if that has none, the best audio track"""
    hls = [f for f in formats if f.get("protocol") in ("m3u8", "m3u8_native") and f.get("url")]
    video = [f for f in hls if f.get("vcodec") not in (None, "none")]
    if not video:
        raise ValueError("livestream without a video track")
    best = max(video, key=lambda f: (f.get("height") or 0, f.get("tbr") or 0))
    if best.get("acodec") not in (None, "none"):
        return [best["url"]]
    audio = [f for f in hls if f.get("vcodec") == "none"]
    if not audio:
        raise ValueError("livestream without an audio track")
    return [best["url"], max(audio, key=lambda f: f.get("tbr") or 0)["url"]]


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
    if info.get("is_live"):
        live_inputs[:] = live_tracks(formats)
        return title, live_ts, False
    global master, audio_playlists
    for f in formats:
        if f.get("protocol") in ("m3u8", "m3u8_native") and f.get("manifest_url"):
            with urllib.request.urlopen(f["manifest_url"], timeout=30) as resp:
                text = without_he_aac(resp.read().decode())
            upstream = []
            if info.get("extractor_key") == "Youtube":
                text, upstream = local_audio(text)
            master, audio_playlists = text, upstream
            return title, master_url, True
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
    def answer(self, status, text, content_type="text/plain; charset=utf-8"):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/master.m3u8" and master:
            return self.answer(200, master, "application/vnd.apple.mpegurl")
        audio = re.fullmatch(r"/audio/(\d+)\.m3u8", self.path)
        if audio:
            n = int(audio[1])
            if n >= len(audio_playlists):
                return self.answer(404, "not found")
            try:
                with urllib.request.urlopen(audio_playlists[n], timeout=30) as resp:
                    text = as_adts(resp.read().decode())
            except OSError as e:
                return self.answer(502, str(e))
            return self.answer(200, text, "application/vnd.apple.mpegurl")
        if self.path != "/live.ts" or not live_inputs:
            return self.answer(404, "not found")
        args = ["ffmpeg", "-nostdin", "-loglevel", "error"]
        for url in live_inputs:
            args += ["-i", url]
        args += ["-map", "0:v:0", "-map", f"{len(live_inputs) - 1}:a:0", "-c", "copy", "-f", "mpegts", "pipe:1"]
        ffmpeg = subprocess.Popen(args, stdout=subprocess.PIPE)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.end_headers()
            while chunk := ffmpeg.stdout.read1(65536):
                self.wfile.write(chunk)
        except OSError:
            pass  # Kodi stopped or switched streams
        finally:
            ffmpeg.kill()
            ffmpeg.wait()

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
