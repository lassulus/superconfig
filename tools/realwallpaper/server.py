"""Serve realwallpaper renders over HTTP, rendered on demand.

    GET /?location=52.52,13.40&variant=lens&overlay=sky&size=3840x2160

A render for a (location, variant, size) is fresh for --ttl seconds (10 min).
A request for a stale or missing render queues one and waits for it. A
render that was picked up (served at least once) is re-rendered in the
background as soon as it goes stale, so regular clients always get a fresh
image straight away; renders nobody picked up are left alone and deleted
after --keep. Renders run one at a time (a 4K frame needs a few GB of RAM)
and share one data cache.
"""

from __future__ import annotations

import argparse
import collections
import email.utils
import http.server
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path

VARIANTS = ("lens", "plain", "mercator")
OVERLAYS = {
    "none": "realwallpaper.png",
    "sky": "realwallpaper-marker.png",  # sun, moon, planets
    "krebs": "realwallpaper-krebs.png",  # sky plus krebs markers
    "stars": "realwallpaper-krebs-stars.png",  # plus constellation lines
}
DEFAULT_SIZE = (3840, 2160)
MIN_SIZE = (320, 180)
MAX_SIZE = (3840, 2160)

HELP = """realwallpaper, a live world map centred on a location

  /?location=LAT,LON&variant=VARIANT&overlay=OVERLAY&size=WxH

  location  degrees, south/west negative, rounded to 0.01 (default Berlin)
  variant   lens (zoomed in on location), plain (no distortion),
            mercator (classic north-up map)        (default lens)
  overlay   none, sky (sun, moon, planets), krebs (sky and krebs nodes),
            stars (all of that plus constellations) (default sky)
  size      up to 3840x2160                          (default 3840x2160)

Renders are cached for {ttl} minutes. Ones that get picked up are kept
fresh in the background, so after the first request they come instantly.
"""


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


class BadRequest(Exception):
    pass


class Busy(Exception):
    pass


@dataclass(frozen=True)
class Job:
    lat: float
    lon: float
    variant: str
    width: int
    height: int

    @property
    def key(self) -> str:
        return f"{self.lat:.2f}_{self.lon:.2f}_{self.variant}_{self.width}x{self.height}"

    @classmethod
    def from_key(cls, key: str) -> Job:
        lat, lon, variant, size = key.split("_")
        width, height = size.split("x")
        return cls(float(lat), float(lon), variant, int(width), int(height))


@dataclass
class Entry:
    job: Job
    dir: Path
    picked_up: bool = False
    last_request: float = field(default_factory=time.time)
    queued: bool = False
    rendering: bool = False
    error: str | None = None

    def rendered_at(self) -> float | None:
        try:
            return (self.dir / OVERLAYS["none"]).stat().st_mtime
        except OSError:
            return None


def parse_query(query: str, default_location: tuple[float, float]) -> tuple[Job, str]:
    params = urllib.parse.parse_qs(query)

    def one(name: str, default: str) -> str:
        values = params.get(name)
        return values[-1] if values else default

    try:
        lat, lon = (float(v) for v in one("location", "%s,%s" % default_location).split(","))
    except ValueError:
        raise BadRequest("location must be LAT,LON") from None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise BadRequest("location out of range")
    variant = one("variant", "lens")
    if variant not in VARIANTS:
        raise BadRequest(f"variant must be one of {', '.join(VARIANTS)}")
    overlay = one("overlay", "sky")
    if overlay not in OVERLAYS:
        raise BadRequest(f"overlay must be one of {', '.join(OVERLAYS)}")
    try:
        width, height = (int(v) for v in one("size", "%dx%d" % DEFAULT_SIZE).lower().split("x"))
    except ValueError:
        raise BadRequest("size must be WIDTHxHEIGHT") from None
    if not (MIN_SIZE[0] <= width <= MAX_SIZE[0] and MIN_SIZE[1] <= height <= MAX_SIZE[1]):
        raise BadRequest("size must be between %dx%d and %dx%d" % (*MIN_SIZE, *MAX_SIZE))
    return Job(round(lat, 2), round(lon, 2), variant, width, height), overlay


class Renderer:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.renders = args.state_dir / "renders"
        self.cache = args.state_dir / "cache"
        self.renders.mkdir(parents=True, exist_ok=True)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.cond = threading.Condition()
        self.entries: dict[str, Entry] = {}
        self.queue: collections.deque[str] = collections.deque()
        for d in self.renders.iterdir():
            try:
                job = Job.from_key(d.name)
            except ValueError:
                continue
            entry = Entry(job, d)
            entry.last_request = entry.rendered_at() or 0.0
            self.entries[job.key] = entry
        threading.Thread(target=self._worker, daemon=True, name="render").start()
        threading.Thread(target=self._scheduler, daemon=True, name="schedule").start()

    def fresh(self, entry: Entry) -> bool:
        at = entry.rendered_at()
        return at is not None and time.time() - at < self.args.ttl

    def _enqueue(self, entry: Entry, front: bool) -> None:
        if entry.queued or entry.rendering:
            return
        if front:
            if len(self.queue) >= self.args.max_queue:
                raise Busy()
            self.queue.appendleft(entry.job.key)
        else:
            self.queue.append(entry.job.key)
        entry.queued = True
        self.cond.notify_all()

    def get(self, job: Job, overlay: str) -> tuple[Path, Entry]:
        """Path of a fresh render, waiting for one if needed."""
        with self.cond:
            entry = self.entries.get(job.key)
            if entry is None:
                entry = self.entries[job.key] = Entry(job, self.renders / job.key)
            entry.last_request = time.time()
            if not self.fresh(entry):
                self._enqueue(entry, front=True)
                deadline = time.time() + self.args.wait
                while (entry.queued or entry.rendering) and time.time() < deadline:
                    self.cond.wait(deadline - time.time())
            path = entry.dir / OVERLAYS[overlay]
            if path.exists():
                # served: keep it fresh from now on
                entry.picked_up = True
            return path, entry

    def _scheduler(self) -> None:
        while True:
            time.sleep(30)
            now = time.time()
            with self.cond:
                for key, entry in list(self.entries.items()):
                    if entry.queued or entry.rendering:
                        continue
                    if entry.picked_up and not self.fresh(entry):
                        self._enqueue(entry, front=False)
                    elif now - entry.last_request > self.args.keep:
                        log(f"dropping {key}, not requested for {self.args.keep / 3600:.0f}h")
                        shutil.rmtree(entry.dir, ignore_errors=True)
                        del self.entries[key]

    def _worker(self) -> None:
        while True:
            with self.cond:
                while not self.queue:
                    self.cond.wait()
                entry = self.entries[self.queue.popleft()]
                entry.queued = False
                entry.rendering = True
                # needs to be picked up again to be kept fresh after this
                entry.picked_up = False
            error = self._render(entry.job, entry.dir)
            with self.cond:
                entry.rendering = False
                entry.error = error
                self.cond.notify_all()

    def _render(self, job: Job, out: Path) -> str | None:
        out.mkdir(parents=True, exist_ok=True)
        cmd = [
            self.args.realwallpaper,
            "--dir", str(out),
            "--cache-dir", str(self.cache),
            "--lat", str(job.lat),
            "--lon", str(job.lon),
            "--projection", job.variant,
            "--width", str(job.width),
            "--height", str(job.height),
            "--no-archive",
        ]
        if self.args.marker_url:
            cmd += ["--marker-url", self.args.marker_url]
        t0 = time.monotonic()
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=self.args.render_timeout)
        except subprocess.TimeoutExpired:
            log(f"render {job.key}: timed out")
            return "render timed out"
        if proc.returncode != 0:
            tail = proc.stderr.strip().splitlines()[-5:]
            log(f"render {job.key} failed ({proc.returncode}): " + " | ".join(tail))
            return "render failed: " + (tail[-1] if tail else f"exit {proc.returncode}")
        log(f"rendered {job.key} in {time.monotonic() - t0:.0f}s")
        return None


def make_handler(renderer: Renderer, args: argparse.Namespace):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "realwallpaper"

        def log_message(self, fmt: str, *a) -> None:
            log("%s %s" % (self.address_string(), fmt % a))

        def _text(self, code: int, body: str, extra: dict[str, str] | None = None) -> None:
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_HEAD(self) -> None:
            self.do_GET()

        def do_GET(self) -> None:
            url = urllib.parse.urlsplit(self.path)
            if url.path != "/":
                return self._text(404, "not found\n")
            if not url.query:
                return self._text(200, HELP.format(ttl=round(args.ttl / 60)))
            try:
                job, overlay = parse_query(url.query, (args.lat, args.lon))
                path, entry = renderer.get(job, overlay)
            except BadRequest as e:
                return self._text(400, f"{e}\n")
            except Busy:
                return self._text(503, "too many renders queued, try again later\n",
                                  {"Retry-After": "60"})
            try:
                data = path.read_bytes()
                rendered = path.stat().st_mtime
            except OSError:
                return self._text(502, f"{entry.error or 'render still running, try again'}\n",
                                  {"Retry-After": "30"})
            age = time.time() - rendered
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Last-Modified", email.utils.formatdate(rendered, usegmt=True))
            self.send_header("Cache-Control", f"public, max-age={max(0, int(args.ttl - age))}")
            if age >= args.ttl:
                # the refresh failed or is still running; this is the last good one
                self.send_header("Warning", '110 - "stale render"')
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

    return Handler


def main() -> None:
    p = argparse.ArgumentParser(prog="realwallpaper-server", description=__doc__.splitlines()[0])
    p.add_argument("--listen", default="127.0.0.1:8477", help="HOST:PORT (default 127.0.0.1:8477)")
    p.add_argument("--state-dir", type=Path, required=True, help="renders and the shared data cache")
    p.add_argument("--realwallpaper", required=True, help="path of the realwallpaper binary")
    p.add_argument("--ttl", type=float, default=600, help="seconds a render stays fresh (default 600)")
    p.add_argument("--keep", type=float, default=7 * 86400,
                   help="drop renders not requested for this many seconds (default 7 days)")
    p.add_argument("--wait", type=float, default=900,
                   help="how long a request waits for its render (default 900 s)")
    p.add_argument("--render-timeout", type=float, default=1800, help="seconds (default 1800)")
    p.add_argument("--max-queue", type=int, default=8,
                   help="queued renders before new locations get 503 (default 8)")
    p.add_argument("--marker-url", default=None, help="JSON {name: {latitude, longitude}} for krebs markers")
    p.add_argument("--lat", type=float, default=52.52, help="default location (Berlin)")
    p.add_argument("--lon", type=float, default=13.40)
    args = p.parse_args()

    host, _, port = args.listen.rpartition(":")
    renderer = Renderer(args)
    server = http.server.ThreadingHTTPServer((host.strip("[]") or "127.0.0.1", int(port)),
                                             make_handler(renderer, args))
    server.daemon_threads = True
    log(f"listening on {args.listen}")
    server.serve_forever()


if __name__ == "__main__":
    main()
