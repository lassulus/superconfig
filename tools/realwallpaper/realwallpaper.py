"""Render a live world map wallpaper: oblique Mercator with a lens on home.

The globe is rotated so home (default Berlin) is in the middle of the screen
on the projection's equator, then shown in Mercator filling the screen edge
to edge. Around home a smooth radial lens magnifies the map and blends back
into the plain map at its rim.

Imagery is fetched over WMS at the resolution each pixel needs: a few local
levels around home, one global level, and downsampled global mipmaps. The
night side is the day map darkened, plus city lights as a glow. Every fetch
is cached with a TTL; a failing source falls back to its last good copy or
is skipped, so one dead upstream no longer kills the whole wallpaper.
"""

from __future__ import annotations

import argparse
import dataclasses
import concurrent.futures
import datetime as dt
import hashlib
import io
import json
import math
import os
import sys
import time
import urllib.parse
import urllib.request
import warnings
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

R_EARTH = 6371.0088  # km
KM_PER_DEG = math.pi * R_EARTH / 180
GLOBAL_WIDTH = 8192  # px of the global equirectangular level
# px per WMS request side. The servers render on the fly at a roughly fixed
# px/s per request (EOX: ~0.35 Mpx/s) but serve requests in parallel, so
# many medium tiles fetched concurrently are much faster than few big ones
MAX_TILE = 2048
TILE_WORKERS = 4  # concurrent requests per level
MAX_LEVEL_SIDE = 8192  # px per local level side
USER_AGENT = "realwallpaper (+https://github.com/Lassulus/superconfig)"

GIBS = "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"
EUMETSAT = "https://view.eumetsat.int/geoserver/wms"
EOX = "https://tiles.maps.eox.at/wms"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# --------------------------------------------------------------------------
# projection


def solve_cylinder(half_height: float) -> float:
    """Parameter a of the cylindrical y(lat) = ln tan(pi/4 + a lat/2) / a
    whose poles sit exactly half_height (radians of longitude) from the
    equator. a -> 0 is plate carrée (pi/2), a = 1 is Mercator (infinite);
    Miller is a = 0.8. Wider screens than 2:1 fall back to plate carrée."""
    lo, hi = 1e-6, 1 - 1e-9
    if half_height <= math.pi / 2:
        return lo
    for _ in range(200):
        a = (lo + hi) / 2
        if math.log(math.tan(math.pi / 4 + a * math.pi / 4)) / a > half_height:
            hi = a
        else:
            lo = a
    return (lo + hi) / 2


def rotate_to_home(lat0: float, lat, dlon):
    """Geographic (lat, lon - lon0) -> frame where home is lat' = lon' = 0.

    Rotating about the east-west axis keeps local north pointing up at home.
    All angles in radians.
    """
    x = np.cos(lat) * np.cos(dlon)
    y = np.cos(lat) * np.sin(dlon)
    z = np.sin(lat)
    s0, c0 = math.sin(lat0), math.cos(lat0)
    xr = x * c0 + z * s0
    zr = -x * s0 + z * c0
    return np.arcsin(np.clip(zr, -1.0, 1.0)), np.arctan2(y, xr)


def rotate_from_home(lat0: float, lat_r, lon_r):
    """Inverse of rotate_to_home: returns (lat, lon - lon0) in radians."""
    xr = np.cos(lat_r) * np.cos(lon_r)
    y = np.cos(lat_r) * np.sin(lon_r)
    zr = np.sin(lat_r)
    s0, c0 = math.sin(lat0), math.cos(lat0)
    x = xr * c0 - zr * s0
    z = xr * s0 + zr * c0
    return np.arcsin(np.clip(z, -1.0, 1.0)), np.arctan2(y, x)


class LensMap:
    """Screen-filling oblique cylindrical map around home, with a lens.

    The globe is rotated so home sits on the projection's equator in the
    middle of the screen (local north up); its poles land top and bottom
    only when home is on the real equator. The cylinder is Mercator-like
    (conformal along that equator) but with finite poles, y = ln tan(pi/4 +
    a lat/2) / a, with a picked so the whole globe fits the screen exactly:
    nothing is cut off, only squeezed towards the top and bottom edges.

    Projections (--projection):
    - lens: the above plus the magnifying lens around home (default)
    - plain: the above without the lens, no distortion beyond the cylinder
    - world: the classic map, north up, plate carrée centred on the equator
      and the home longitude, the whole globe stretched to fill the screen
      (longitude scaled to the width, latitude to the height); no lens

    The lens is focus + glue + context (Yamamoto et al. 2009; the same idea
    as Snyder's 1987 "magnifying-glass" azimuthal projections): a lens
    "radius" n is measured as a circle, or following the screen's aspect
    as an ellipse (p = 2) or rounded rectangle (p = 4), the norm

        n = ((|dx| / ax)^p + (|dy| / ay)^p)^(1/p)

    (ax, ay = half the screen size times --lens). A screen point at n shows
    the map point at h(n) = n / z(n) along the same ray, where z is the
    local zoom: M in the focus (n < f, undistorted), 1 from n = 1 on (plain
    map), and in between, with t = (n - f) / (1 - f),

        ln z(t) = ln M * (1 - I(t) / I(1)),   I(t) = int_0^t u^(a-1) (1 - u) du

    How squashed shapes are is the ratio of radial to tangential scale,
    1 - t z'/z; its excess over 1 is proportional to t^a (1 - t): none at home, largest at
    t = a / (a + 1) =: --falloff, back to 1 at the lens edge. So --falloff
    says where the distortion sits: low keeps it near home, high pushes it
    out towards the border and leaves the middle closer to a plain zoom.
    z never increases outwards, so h' > 0 and the lens never folds.
    """

    def __init__(
        self,
        lat: float,
        lon: float,
        width: int,
        height: int,
        magnification: float,
        lens: float,
        shape: str,
        focus: float,
        falloff: float,
        projection: str = "lens",
    ) -> None:
        if magnification < 1:
            raise SystemExit("--magnification must be >= 1")
        if not 0 <= focus < 1:
            raise SystemExit("--focus must be in [0, 1)")
        if not 0 < falloff < 1:
            raise SystemExit("--falloff must be in (0, 1)")
        self.lat0 = math.radians(lat)
        self.lon0 = math.radians(lon)
        self.width = width
        self.height = height
        self.m = magnification if projection == "lens" else 1.0
        self.k = 2 * math.pi / width  # radians of longitude per px
        self.world = projection == "world"
        if self.world:
            self.rot_lat = 0.0  # no rotation: the real equator is the axis
            self.ky = math.pi / height  # radians of latitude per px
        else:
            self.rot_lat = self.lat0  # home on the projection's equator
            self.a = solve_cylinder(math.pi * height / width)
        self.px = width / 2
        self.py = height / 2
        self.shape = shape
        if shape == "circle":
            self.ax = self.ay = lens * height / 2
        else:
            self.ax = lens * width / 2
            self.ay = lens * height / 2
        # tabulate the profile; forward() inverts it by interpolation
        self._s = np.linspace(0.0, 1.0, 8001)
        t = np.clip((self._s - focus) / (1 - focus), 0.0, 1.0)
        a = falloff / (1 - falloff)
        with np.errstate(divide="ignore", invalid="ignore"):
            f_int = np.where(t > 0, t ** (a - 1) * (1 - t), 0.0)
        integral = np.concatenate([[0.0], np.cumsum((f_int[1:] + f_int[:-1]) / 2 * np.diff(t))])
        zoom = np.exp(math.log(self.m) * (1 - integral / max(integral[-1], 1e-12)))
        self._h = self._s / zoom
        self._dh = np.gradient(self._h, self._s)
        # sample the screen to plan which resolutions are needed where
        ys, xs = np.mgrid[0:height:6, 0:width:6] + 3.0
        lat_g, lon_g, q = self.inverse(xs.ravel(), ys.ravel())
        s = self.norm(xs.ravel() - self.px, ys.ravel() - self.py)
        self._plan_q = q[s < 1]
        self._plan_d = great_circle_km(lat, lon, lat_g[s < 1], lon_g[s < 1])
        self.q0 = float(q.min())
        self.q_max = float(q.max())

    def norm(self, dx, dy):
        if self.shape == "circle":
            return np.hypot(dx, dy) / self.ax
        if self.shape == "ellipse":
            return np.hypot(dx / self.ax, dy / self.ay)
        return ((np.abs(dx) / self.ax) ** 4 + (np.abs(dy) / self.ay) ** 4) ** 0.25

    def h(self, s):
        return np.interp(s, self._s, self._h)

    def dh(self, s):
        return np.interp(s, self._s, self._dh)

    def distance_for_demand(self, q: float) -> float:
        """Radius (km) around home inside which some pixel needs finer than q."""
        need = self._plan_d[self._plan_q < q]
        return float(min(need.max(), 3500.0)) if len(need) else 0.0

    def inverse(self, xs: np.ndarray, ys: np.ndarray):
        """Screen px -> lat, lon (degrees) and ground size of the px (km)."""
        dx, dy = xs - self.px, ys - self.py
        s = self.norm(dx, dy)
        inside = s < 1
        si = np.where(inside, s, 1.0)
        with np.errstate(divide="ignore", invalid="ignore"):
            tangential = np.where(si > 1e-9, self.h(si) / si, 1 / self.m)
        radial = self.dh(si)
        scale = np.where(inside, tangential, 1.0)
        wx = self.px + dx * scale
        wy = self.py + dy * scale
        lon_r = (wx - self.px) * self.k
        if self.world:
            lat_r = (self.py - wy) * self.ky
        else:
            u = (self.py - wy) * self.k
            lat_r = (2 / self.a) * (np.arctan(np.exp(self.a * u)) - math.pi / 4)
        lat_r = np.clip(lat_r, -math.pi / 2, math.pi / 2)
        lat, dlon = rotate_from_home(self.rot_lat, lat_r, lon_r)
        lon = (self.lon0 + dlon + math.pi) % (2 * math.pi) - math.pi
        # the lens squeezes radially more than tangentially in its ring; use
        # the finer scale for sharpness, but not below a quarter of the other
        fine = np.minimum(tangential, radial)
        coarse = np.maximum(tangential, radial)
        lens_f = np.where(inside, np.maximum(fine, coarse / 4), 1.0)
        # cylinder: east-west px size R k cos(lat), north-south R k cos(a lat)
        # (world: R ky)
        if self.world:
            base_q = np.maximum(self.k * np.cos(lat_r), self.ky / 4)
        else:
            base_q = self.k * np.maximum(np.cos(lat_r), np.cos(self.a * lat_r) / 4)
        q = R_EARTH * base_q * lens_f
        return np.degrees(lat), np.degrees(lon), np.maximum(q, 1e-3)

    def forward(self, lat_deg, lon_deg):
        lat = np.radians(np.asarray(lat_deg, dtype=np.float64))
        dlon = np.radians(np.asarray(lon_deg, dtype=np.float64)) - self.lon0
        lat_r, lon_r = rotate_to_home(self.rot_lat, lat, dlon)
        wx = self.px + lon_r / self.k
        if self.world:
            wy = self.py - lat_r / self.ky
        else:
            lat_r = np.clip(lat_r, -math.radians(89.5), math.radians(89.5))
            wy = self.py - np.log(np.tan(math.pi / 4 + self.a * lat_r / 2)) / (self.a * self.k)
        dx, dy = wx - self.px, wy - self.py
        r = self.norm(dx, dy)
        s = np.interp(np.minimum(r, 1.0), self._h, self._s)
        with np.errstate(divide="ignore", invalid="ignore"):
            scale = np.where(r < 1, np.where(r > 1e-12, s / r, self.m), 1.0)
        return self.px + dx * scale, self.py + dy * scale


def great_circle_km(lat0: float, lon0: float, lat, lon) -> np.ndarray:
    la0, lo0 = math.radians(lat0), math.radians(lon0)
    la, lo = np.radians(lat), np.radians(lon)
    c = math.sin(la0) * np.sin(la) + math.cos(la0) * np.cos(la) * np.cos(lo - lo0)
    return np.arccos(np.clip(c, -1.0, 1.0)) * R_EARTH


# --------------------------------------------------------------------------
# sources and levels


@dataclass(frozen=True)
class Wms:
    key: str
    base: str
    layer: str
    native_km: float
    ttl: float
    fmt: str = "image/png"
    time: str | None = None
    # TIME=<today - n days> for each n, newest first; gaps are filled from
    # older days (daily polar-orbiter products are full of swath gaps)
    days_back: tuple[int, ...] = ()
    # fetch this many times finer and box-filter down: some servers (EOX)
    # pick single pixels when asked for a coarse scale, which aliases
    oversample: int = 1
    # per-channel gain to match the colours of the other day source
    gain: tuple[float, float, float] | None = None

    def times(self, when: dt.datetime) -> list[str | None]:
        if self.days_back:
            return [(when - dt.timedelta(days=n)).strftime("%Y-%m-%d") for n in self.days_back]
        return [self.time]

    def url(self, bbox: tuple[float, float, float, float], w: int, h: int, t: str | None) -> str:
        s, west, n, e = bbox
        params = {
            "SERVICE": "WMS",
            "VERSION": "1.3.0",
            "REQUEST": "GetMap",
            "LAYERS": self.layer,
            "STYLES": "",
            "CRS": "EPSG:4326",
            "BBOX": f"{s:.6f},{west:.6f},{n:.6f},{e:.6f}",
            "WIDTH": str(w),
            "HEIGHT": str(h),
            "FORMAT": self.fmt,
            "TRANSPARENT": "TRUE",
        }
        if t:
            params["TIME"] = t
        return self.base + "?" + urllib.parse.urlencode(params)


@dataclass
class Level:
    res: float  # km per px
    south: float
    west: float
    north: float
    east: float
    width: int
    height: int
    wrap: bool
    data: np.ndarray | None = None

    @property
    def bbox(self) -> tuple[float, float, float, float]:
        return (self.south, self.west, self.north, self.east)


def local_level(proj: LensMap, res: float, radius_km: float) -> Level:
    lat = math.degrees(proj.lat0)
    lon = math.degrees(proj.lon0)
    dlat = math.degrees(radius_km / R_EARTH)
    south, north = max(-90.0, lat - dlat), min(90.0, lat + dlat)
    coslat = math.cos(proj.lat0)
    s = math.sin(radius_km / R_EARTH) / coslat if coslat > 1e-6 else 2.0
    if north >= 90.0 or south <= -90.0 or s >= 1.0:
        west, east = -180.0, 180.0
    else:
        dlon = math.degrees(math.asin(s))
        west, east = lon - dlon, lon + dlon
    mid = math.cos(math.radians((south + north) / 2))
    width_km = (east - west) * KM_PER_DEG * max(mid, 0.05)
    height_km = (north - south) * KM_PER_DEG
    res = max(res, width_km / MAX_LEVEL_SIDE, height_km / MAX_LEVEL_SIDE)
    return Level(
        res=res,
        south=south,
        west=west,
        north=north,
        east=east,
        width=max(2, math.ceil(width_km / res)),
        height=max(2, math.ceil(height_km / res)),
        wrap=False,
    )


def global_level(width: int) -> Level:
    return Level(
        res=360 / width * KM_PER_DEG,
        south=-90.0,
        west=-180.0,
        north=90.0,
        east=180.0,
        width=width,
        height=width // 2,
        wrap=True,
    )


def plan_local(proj: LensMap, native_km: float) -> list[Level]:
    """Local levels, finest first, each 4x coarser than the previous one."""
    g = global_level(GLOBAL_WIDTH).res
    resolutions = [max(proj.q0, native_km)]
    while resolutions[-1] * 4 < g / 1.5:
        resolutions.append(resolutions[-1] * 4)
    if resolutions[0] >= g / 1.5:
        return []
    levels = []
    for i, res in enumerate(resolutions):
        nxt = resolutions[i + 1] if i + 1 < len(resolutions) else g
        radius = proj.distance_for_demand(nxt) * 1.1
        if radius > 0:
            levels.append(local_level(proj, res, radius))
    return levels


def mipmaps(level: Level, q_max: float) -> list[Level]:
    out = []
    cur = level
    while cur.res < q_max and cur.height >= 64 and cur.data is not None:
        d = cur.data.astype(np.uint16)
        d = (d[0::2, 0::2] + d[1::2, 0::2] + d[0::2, 1::2] + d[1::2, 1::2] + 2) // 4
        cur = Level(
            res=cur.res * 2,
            south=-90.0,
            west=-180.0,
            north=90.0,
            east=180.0,
            width=cur.width // 2,
            height=cur.height // 2,
            wrap=True,
            data=d.astype(np.uint8),
        )
        out.append(cur)
    return out


# --------------------------------------------------------------------------
# raster preparation: RGBA -> channels, last channel is data coverage, value
# channels are premultiplied by coverage. Bump PREP_VERSION whenever a prep
# function changes so cached prepared rasters are rebuilt from the raw ones.

PREP_VERSION = 3


class Colormap:
    """GIBS colormap: maps the rendered colours back to a 0..1 data value."""

    def __init__(self, path: Path) -> None:
        import xml.etree.ElementTree as ET

        entries = [
            e
            for e in ET.parse(path).iter()
            if e.tag.endswith("ColorMapEntry")
            and e.get("transparent") != "true"
            and e.get("nodata") != "true"
        ]
        if not entries:
            raise ValueError(f"{path}: no colormap entries")
        self.rgb = np.array([[int(c) for c in e.get("rgb", "").split(",")] for e in entries])
        self.value = np.linspace(0.0, 1.0, len(entries))

    def decode(self, rgba: np.ndarray) -> np.ndarray:
        out = np.zeros(rgba.shape[:2], np.float32)
        mask = rgba[..., 3] > 0
        px = rgba[mask][:, :3].astype(np.int64)
        if len(px) == 0:
            return out
        uniq, inv = np.unique((px[:, 0] << 16) | (px[:, 1] << 8) | px[:, 2], return_inverse=True)
        colors = np.stack([uniq >> 16, (uniq >> 8) & 255, uniq & 255], axis=-1)
        values = np.empty(len(uniq))
        for i in range(0, len(uniq), 4096):
            d = ((colors[i : i + 4096, None, :] - self.rgb[None]) ** 2).sum(-1)
            values[i : i + 4096] = self.value[d.argmin(1)]
        out[mask] = values[inv]
        return out


def to_u8(x: np.ndarray) -> np.ndarray:
    return np.round(np.clip(x, 0, 1) * 255).astype(np.uint8)


def prep_rgb(layer: "Layer", rgba: np.ndarray, cmap: Colormap | None) -> np.ndarray:
    a = rgba[..., 3:4].astype(np.uint16)
    rgb = (rgba[..., :3].astype(np.uint16) * a + 127) // 255
    return np.concatenate([rgb.astype(np.uint8), rgba[..., 3:4]], axis=-1)


def prep_lights(layer: "Layer", rgba: np.ndarray, cmap: Colormap | None) -> np.ndarray:
    """Black Marble -> city light intensity; drops its dim blue land texture."""
    red = rgba[..., 0].astype(np.float32) / 255
    full = np.full(rgba.shape[:2], 255, np.uint8)
    return np.stack([to_u8(np.clip((red - 0.12) / 0.75, 0, 1) ** 1.2), full], axis=-1)


def prep_cloud(layer: "Layer", rgba: np.ndarray, cmap: Colormap | None) -> np.ndarray:
    """Infrared 10.8 µm brightness (cold = bright) -> cloud opacity."""
    v = rgba[..., 0].astype(np.float32) / 255
    cov = rgba[..., 3].astype(np.float32) / 255
    assert layer.transform is not None
    return np.stack([to_u8(layer.transform(v) * cov), rgba[..., 3]], axis=-1)


def prep_scalar(layer: "Layer", rgba: np.ndarray, cmap: Colormap | None) -> np.ndarray:
    """Colormapped data value (or plain presence) -> opacity, full coverage."""
    v = cmap.decode(rgba) if cmap else rgba[..., 3].astype(np.float32) / 255
    if layer.transform is not None:
        v = layer.transform(v) * (rgba[..., 3] > 0)
    full = np.full(rgba.shape[:2], 255, np.uint8)
    return np.stack([to_u8(v), full], axis=-1)


def prep_tint(layer: "Layer", rgba: np.ndarray, cmap: Colormap | None) -> np.ndarray:
    """Colormapped value plus where it is defined, full coverage."""
    assert cmap is not None
    present = (rgba[..., 3] > 0).astype(np.float32)
    full = np.full(rgba.shape[:2], 255, np.uint8)
    return np.stack([to_u8(cmap.decode(rgba) * present), to_u8(present), full], axis=-1)


def combine_max(layers: list[np.ndarray]) -> np.ndarray:
    out = layers[0].copy()
    for older in layers[1:]:
        np.maximum(out, older, out=out)
    return out


def combine_fill(layers: list[np.ndarray]) -> np.ndarray:
    """Fill where the newest has no data (channel -2 = presence) from older."""
    out = layers[0].copy()
    for older in layers[1:]:
        gap = out[..., -2] == 0
        out[gap] = older[gap]
    return out


# --------------------------------------------------------------------------
# fetching


class FetchError(Exception):
    pass


def http_get(url: str, timeout: float = 120) -> tuple[bytes, str]:
    last: Exception | None = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read(), resp.headers.get("Content-Type", "")
        except Exception as e:  # noqa: BLE001 - network errors come in many types
            last = e
            time.sleep(2 * (attempt + 1))
    raise FetchError(f"{url}: {last}")


def fetch_image(url: str) -> np.ndarray:
    body, ctype = http_get(url)
    if not ctype.startswith("image/"):
        raise FetchError(f"{url}: got {ctype}: {body[:200]!r}")
    return np.asarray(Image.open(io.BytesIO(body)).convert("RGBA"))


def split_columns(level: Level) -> list[tuple[int, int]]:
    px = (level.east - level.west) / level.width
    cuts = {0, level.width}
    for meridian in (-180.0, 180.0):
        if level.west < meridian < level.east and not level.wrap:
            cuts.add(round((meridian - level.west) / px))
    c = 0
    while c < level.width:
        cuts.add(c)
        c += MAX_TILE
    edges = sorted(x for x in cuts if 0 <= x <= level.width)
    return [(a, b) for a, b in zip(edges, edges[1:]) if b > a]


def fetch_level(src: Wms, level: Level, t: str | None) -> np.ndarray:
    factor = max(1, min(src.oversample, 2 * MAX_LEVEL_SIDE // max(level.width, level.height)))
    big = dataclasses.replace(level, width=level.width * factor, height=level.height * factor,
                              data=None)
    img = fetch_tiles(src, big, t)
    if factor > 1:
        img = np.asarray(Image.fromarray(img, "RGBA").reduce(factor))
    return img


def apply_gain(rgba: np.ndarray, gain: tuple[float, float, float] | None) -> np.ndarray:
    if gain is None:
        return rgba
    out = rgba.copy()
    out[..., :3] = to_u8(rgba[..., :3] / 255.0 * np.array(gain))
    return out


def fetch_tiles(src: Wms, level: Level, t: str | None) -> np.ndarray:
    px_lon = (level.east - level.west) / level.width
    px_lat = (level.north - level.south) / level.height
    rows = [(r, min(r + MAX_TILE, level.height)) for r in range(0, level.height, MAX_TILE)]
    img = np.zeros((level.height, level.width, 4), np.uint8)

    def one(r0: int, r1: int, c0: int, c1: int) -> None:
        w = level.west + c0 * px_lon
        e = level.west + c1 * px_lon
        mid = (w + e) / 2
        shift = -360.0 if mid > 180 else 360.0 if mid < -180 else 0.0
        w, e = max(-180.0, w + shift), min(180.0, e + shift)
        n = level.north - r0 * px_lat
        s = level.north - r1 * px_lat
        tile = fetch_image(src.url((s, w, n, e), c1 - c0, r1 - r0, t))
        if tile.shape[:2] != (r1 - r0, c1 - c0):
            tile = np.asarray(Image.fromarray(tile).resize((c1 - c0, r1 - r0), Image.BILINEAR))
        img[r0:r1, c0:c1] = tile

    with concurrent.futures.ThreadPoolExecutor(max_workers=TILE_WORKERS) as pool:
        futures = [pool.submit(one, r0, r1, c0, c1)
                   for r0, r1 in rows for c0, c1 in split_columns(level)]
        for fut in futures:
            fut.result()  # re-raise the first failure
    return img


@dataclass
class Layer:
    name: str
    local: Wms | None
    global_: Wms
    prep: Callable[["Layer", np.ndarray, Colormap | None], np.ndarray]
    combine: Callable[[list[np.ndarray]], np.ndarray] = combine_max
    colormap: str | None = None  # GIBS colormap name
    transform: Callable[[np.ndarray], np.ndarray] | None = None
    required: bool = False
    cmap: Colormap | None = None
    levels: list[Level] = field(default_factory=list)
    log_res: np.ndarray | None = None


class Cache:
    """Raw WMS rasters as PNG (refetched after the source TTL) and prepared
    rasters as .npy (rebuilt when a raw one changed or PREP_VERSION moved)."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.used: set[Path] = set()

    def _path(self, prefix: str, ident: object, suffix: str) -> Path:
        digest = hashlib.sha1(json.dumps(ident, sort_keys=True).encode()).hexdigest()[:16]
        path = self.root / f"{prefix}-{digest}{suffix}"
        self.used.add(path)
        return path

    def raw(self, src: Wms, level: Level, t: str | None) -> Path | None:
        ident = [src.layer, t, level.bbox, level.width, level.height, src.oversample]
        path = self._path(src.key, ident, ".png")
        if path.exists() and time.time() - path.stat().st_mtime < src.ttl:
            return path
        try:
            t0 = time.monotonic()
            img = fetch_level(src, level, t)
            tmp = path.with_name(f".{path.name}.tmp")
            Image.fromarray(img, "RGBA").save(tmp, format="PNG", compress_level=1)
            os.replace(tmp, path)
            log(f"fetched {src.key} {t or ''} {level.width}x{level.height} "
                f"@{level.res:.2f}km in {time.monotonic() - t0:.1f}s")
        except Exception as e:  # noqa: BLE001 - any failure falls back to the cache
            log(f"warning: {src.key} {t or ''}: {e}"
                + ("; using cached copy" if path.exists() else ""))
        return path if path.exists() else None

    def get(self, layer: Layer, src: Wms, level: Level, when: dt.datetime) -> np.ndarray | None:
        raws = [p for t in src.times(when) if (p := self.raw(src, level, t)) is not None]
        if not raws:
            return None
        path = self._path(
            f"{layer.name}-prep",
            [PREP_VERSION, src.key, src.gain, [p.name for p in raws]],
            ".npy",
        )
        newest = max(p.stat().st_mtime for p in raws)
        if not path.exists() or path.stat().st_mtime < newest:
            try:
                preps = [
                    layer.prep(layer, apply_gain(np.asarray(Image.open(p).convert("RGBA")), src.gain),
                               layer.cmap)
                    for p in raws
                ]
                tmp = path.with_name(f".{path.name}.tmp.npy")
                np.save(tmp, layer.combine(preps))
                os.replace(tmp, path)
            except Exception as e:  # noqa: BLE001 - a broken raster drops the level
                log(f"warning: {layer.name}: preparing {src.key}: {e}")
                return None
        return np.load(path, mmap_mode="r")

    def get_url(self, name: str, url: str, ttl: float) -> Path | None:
        path = self.root / name
        self.used.add(path)
        if path.exists() and time.time() - path.stat().st_mtime < ttl:
            return path
        try:
            body, _ = http_get(url, timeout=30)
            if not body:
                raise FetchError(f"{url}: empty response")
            tmp = path.with_name(f".{path.name}.tmp")
            tmp.write_bytes(body)
            os.replace(tmp, path)
        except Exception as e:  # noqa: BLE001
            log(f"warning: {name}: {e}")
        return path if path.exists() else None

    def cleanup(self, max_age: float = 3 * 86400) -> None:
        """Delete files no run has used for max_age.

        File mtimes are the fetch times the TTLs run on, so last use is kept
        in a separate index; that also lets several homes share one cache
        without deleting each other's local imagery.
        """
        index_path = self.root / "last-used.json"
        try:
            last_used = json.loads(index_path.read_text())
        except (OSError, ValueError):
            last_used = {}
        now = time.time()
        for p in self.used:
            last_used[p.name] = now
        for p in self.root.iterdir():
            if p == index_path or p.name.startswith("."):
                continue
            seen = last_used.get(p.name, p.stat().st_mtime)
            if now - seen > max_age:
                p.unlink()
                last_used.pop(p.name, None)
        last_used = {name: t for name, t in last_used.items() if (self.root / name).exists()}
        tmp = index_path.with_name(f".{index_path.name}.tmp")
        tmp.write_text(json.dumps(last_used))
        os.replace(tmp, index_path)


def snow_fraction(ndsi: np.ndarray) -> np.ndarray:
    # MODIS/VIIRS fractional snow cover from NDSI, ignoring the faint
    # detections that are mostly cloud edges and bright soil
    return smoothstep(0.35, 0.6, ndsi)


def cloud_opacity(ir: np.ndarray) -> np.ndarray:
    return smoothstep(0.42, 0.78, ir) ** 1.2


def layers() -> list[Layer]:
    day = 86400.0
    return [
        Layer(
            "day",
            # s2cloudless is bluer than Blue Marble over the same land
            Wms("s2cloudless", EOX, "s2cloudless-2025", 0.01, 180 * day, "image/jpeg",
                oversample=4, gain=(1.0, 0.96, 0.85)),
            Wms("bluemarble", GIBS, "BlueMarble_NextGeneration", 0.5, 180 * day, "image/jpeg"),
            prep_rgb,
            required=True,
        ),
        Layer(
            "lights",
            None,
            Wms("blackmarble", GIBS, "VIIRS_Black_Marble", 0.5, 180 * day, "image/jpeg",
                time="2016-01-01"),
            prep_lights,
        ),
        Layer(
            "clouds",
            Wms("mtg-ir105", EUMETSAT, "mtg_fd:ir105_hrfi", 1.0, 600),
            Wms("georing-ir108", EUMETSAT, "mumi:worldcloudmap_ir108", 3.0, 3600),
            prep_cloud,
            transform=cloud_opacity,
        ),
        Layer(
            "snow",
            None,
            Wms("snow", GIBS, "VIIRS_NOAA20_NDSI_Snow_Cover", 0.375, 6 * 3600,
                days_back=(1, 2, 3)),
            prep_scalar,
            colormap="MODIS_NDSI_Snow_Cover",
            transform=snow_fraction,
        ),
        Layer(
            "ice",
            None,
            Wms("seaice", GIBS, "GHRSST_L4_MUR_Sea_Ice_Concentration", 1.0, 6 * 3600,
                days_back=(1, 2, 3)),
            prep_scalar,
            colormap="GHRSST_Sea_Ice_Concentration",
            transform=lambda c: smoothstep(0.15, 0.9, c),
        ),
        Layer(
            "fire",
            None,
            Wms("fire", GIBS, "VIIRS_NOAA20_Thermal_Anomalies_375m_All", 0.375, 3600,
                days_back=(0, 1)),
            prep_scalar,
        ),
        Layer(
            "chlorophyll",
            None,
            Wms("chlorophyll", GIBS, "VIIRS_NOAA20_Chlorophyll_a", 1.0, 6 * 3600,
                days_back=(1, 2, 3, 4)),
            prep_tint,
            combine=combine_fill,
            colormap="VIIRS_Chlorophyll",
        ),
    ]


def load_layers(proj: LensMap, cache: Cache, when: dt.datetime) -> dict[str, Layer]:
    all_layers = []
    for layer in layers():
        if layer.colormap:
            path = cache.get_url(f"colormap-{layer.colormap}.xml",
                                 f"https://gibs.earthdata.nasa.gov/colormaps/v1.3/{layer.colormap}.xml",
                                 30 * 86400)
            try:
                layer.cmap = Colormap(path) if path else None
            except Exception as e:  # noqa: BLE001
                log(f"warning: colormap {layer.colormap}: {e}")
            if layer.cmap is None:
                log(f"warning: no colormap for {layer.name}, leaving it out")
                continue
        all_layers.append(layer)
    jobs = []
    for layer in all_layers:
        local_src = layer.local or layer.global_
        for lvl in plan_local(proj, local_src.native_km):
            jobs.append((layer, local_src, lvl))
        jobs.append((layer, layer.global_, global_level(GLOBAL_WIDTH)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        futures = [(layer, lvl, pool.submit(cache.get, layer, src, lvl, when))
                   for layer, src, lvl in jobs]
        for layer, lvl, fut in futures:
            lvl.data = fut.result()
            if lvl.data is not None:
                layer.levels.append(lvl)
    out = {}
    for layer in all_layers:
        if not layer.levels or not layer.levels[-1].wrap:
            if layer.required:
                raise SystemExit(f"no global data for required layer {layer.name}")
            log(f"warning: layer {layer.name} has no global data, leaving it out")
            continue
        layer.levels.extend(mipmaps(layer.levels[-1], proj.q_max))
        # np.interp needs increasing resolutions; a size-capped local level
        # can end up coarser than the next one
        layer.log_res = np.maximum.accumulate(np.log([lvl.res for lvl in layer.levels]))
        out[layer.name] = layer
    return out


# --------------------------------------------------------------------------
# sampling


def sample_level(level: Level, lat: np.ndarray, lon: np.ndarray):
    data = level.data
    assert data is not None
    h, w = data.shape[:2]
    col = ((lon - level.west) % 360.0) / (level.east - level.west) * w - 0.5
    row = (level.north - lat) / (level.north - level.south) * h - 0.5
    if level.wrap:
        valid = np.ones(lat.shape, bool)
        c = np.floor(col)
        fc = (col - c)[:, None]
        c0 = c.astype(np.int64) % w
        c1 = (c0 + 1) % w
    else:
        valid = (col >= -0.5) & (col <= w - 0.5) & (row >= -0.5) & (row <= h - 0.5)
        col = np.clip(col, 0, w - 1)
        c0 = np.floor(col).astype(np.int64)
        c1 = np.minimum(c0 + 1, w - 1)
        fc = (col - c0)[:, None]
    row = np.clip(row, 0, h - 1)
    r0 = np.floor(row).astype(np.int64)
    r1 = np.minimum(r0 + 1, h - 1)
    fr = (row - r0)[:, None]
    top = data[r0, c0] * (1 - fc) + data[r0, c1] * fc
    bottom = data[r1, c0] * (1 - fc) + data[r1, c1] * fc
    return (top * (1 - fr) + bottom * fr) / 255.0, valid


def sample(layer: Layer, lat: np.ndarray, lon: np.ndarray, logq: np.ndarray):
    """Trilinear sample: blend the two levels whose resolution brackets q.

    Returns premultiplied values and the total data coverage.
    """
    n = len(layer.levels)
    t = np.interp(logq, layer.log_res, np.arange(n, dtype=np.float64))
    channels = layer.levels[0].data.shape[-1] - 1
    out = np.zeros((len(lat), channels))
    rem = np.ones(len(lat))
    for i, lvl in enumerate(layer.levels):
        w = np.clip(i + 1 - t, 0.0, 1.0)
        idx = np.nonzero((w > 0) & (rem > 1e-4))[0]
        if len(idx) == 0:
            continue
        v, valid = sample_level(lvl, lat[idx], lon[idx])
        wi = rem[idx] * w[idx] * valid
        out[idx] += v[:, :-1] * wi[:, None]
        rem[idx] -= wi * v[:, -1]
    return out, 1.0 - rem


def lerp(a: np.ndarray, b, t: np.ndarray) -> np.ndarray:
    return a + (np.asarray(b) - a) * t[:, None]


def subsolar_cos(lat, lon, sun_lat: float, sun_lon: float) -> np.ndarray:
    la, lo = np.radians(lat), np.radians(lon)
    sl, so = math.radians(sun_lat), math.radians(sun_lon)
    return np.sin(la) * math.sin(sl) + np.cos(la) * math.cos(sl) * np.cos(lo - so)


# --------------------------------------------------------------------------
# cloud post-processing: the best live cloud data is ~1 km, far coarser than
# the zoomed-in pixels around home. Synthesise the missing detail (noise
# anchored to the ground, so it moves with the clouds, not the screen), and
# light the clouds from the sun: relief shading plus shadows on the ground.

CLOUD_DATA_KM = 1.0  # resolution of the finest cloud source
CLOUD_HEIGHT_KM = 3.0  # assumed cloud height for the shadow offset


def value_noise(p: np.ndarray) -> np.ndarray:
    """Smooth 3D value noise in [-1, 1] at integer lattice spacing."""
    i = np.floor(p).astype(np.int64)
    f = p - i
    u = f * f * (3 - 2 * f)
    out = np.zeros(len(p))
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                h = ((i[:, 0] + dx) * 73856093) ^ ((i[:, 1] + dy) * 19349663) ^ ((i[:, 2] + dz) * 83492791)
                h = (h * 0x2545F491) & 0xFFFFFF
                w = (u[:, 0] if dx else 1 - u[:, 0]) * (u[:, 1] if dy else 1 - u[:, 1]) \
                    * (u[:, 2] if dz else 1 - u[:, 2])
                out += w * (h / 0x7FFFFF - 1.0)
    return out


def cloud_detail(a: np.ndarray, lat: np.ndarray, lon: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Turn the soft, upsampled cloud edges into crisp fractal ones.

    Octaves (in km on the ground) are only added where they span at least
    two output px and lie below the data resolution, so the far, small parts
    of the map stay as they are.
    """
    out = a.copy()
    flat_a, flat_q = a.ravel(), q.ravel()
    todo = np.nonzero((flat_a > 0.02) & (flat_a < 0.98) & (flat_q < 2 * CLOUD_DATA_KM))[0]
    octaves = [(0.4, 0.35), (0.8, 0.5), (1.6, 0.75), (3.2, 1.0)]  # wavelength km, amplitude
    total = sum(amp for _, amp in octaves)
    flat_out = out.ravel()
    for c0 in range(0, len(todo), 1_000_000):
        idx = todo[c0 : c0 + 1_000_000]
        la, lo = np.radians(lat.ravel()[idx]), np.radians(lon.ravel()[idx])
        p = R_EARTH * np.stack([np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)], -1)
        qi, ai = flat_q[idx], flat_a[idx]
        n = np.zeros(len(idx))
        weight = np.zeros(len(idx))
        for wavelength, amp in octaves:
            w = smoothstep(2.0, 4.0, wavelength / qi) * amp
            n += w * value_noise(p / wavelength)
            weight += w
        detail = np.clip(weight / total * 1.5, 0, 1) * smoothstep(2 * CLOUD_DATA_KM, 0.5 * CLOUD_DATA_KM, qi)
        nn = n / np.maximum(weight, 1e-6)  # fBm in [-1, 1]
        # modulate rather than threshold: thin parts get the most texture,
        # dense cores only some, and translucency survives
        textured = np.clip(ai * (1 + 0.9 * nn * (1 - 0.6 * ai)), 0, 1)
        textured = textured + (smoothstep(0.15, 0.85, textured) - textured) * 0.5
        flat_out[idx] = ai + (textured - ai) * detail
    return out


def box_blur(a: np.ndarray, r: int) -> np.ndarray:
    """Approximate Gaussian blur (three box passes per axis)."""
    if r < 1:
        return a
    out = a.astype(np.float32)
    for axis in (0, 1):
        for _ in range(3):
            pad = [(0, 0), (0, 0)]
            pad[axis] = (r + 1, r)
            c = np.cumsum(np.pad(out, pad, mode="edge"), axis=axis, dtype=np.float64)
            hi = np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
            lo = np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)
            out = ((hi - lo) / (2 * r + 1)).astype(np.float32)
    return out


def gather(a: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    """Bilinear lookup of a 2D array at fractional pixel positions."""
    h, w = a.shape
    x = np.clip(x, 0, w - 1.001)
    y = np.clip(y, 0, h - 1.001)
    x0, y0 = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
    fx, fy = x - x0, y - y0
    top = a[y0, x0] * (1 - fx) + a[y0, x0 + 1] * fx
    bottom = a[y0 + 1, x0] * (1 - fx) + a[y0 + 1, x0 + 1] * fx
    return top * (1 - fy) + bottom * fy


def render_base(proj: LensMap, lay: dict[str, Layer], sun: tuple[float, float]) -> np.ndarray:
    W, H = proj.width, proj.height
    ground = np.zeros((H, W, 3), np.float32)
    cloud = np.zeros((H, W), np.float32)
    cosz_f = np.zeros((H, W), np.float32)
    lights = np.zeros((H, W), np.float32)
    lat_f = np.zeros((H, W), np.float32)
    lon_f = np.zeros((H, W), np.float32)
    q_f = np.zeros((H, W), np.float32)
    chunk = max(1, 1_000_000 // W)
    xs = np.arange(W) + 0.5
    snow_rgb = np.array([0.87, 0.87, 0.87])
    ice_rgb = np.array([0.90, 0.94, 1.00])
    fire_rgb = np.array([0.94, 0.52, 0.05])
    # chlorophyll: turquoise for moderately productive water, green for blooms
    plankton_rgb = np.array([0.06, 0.32, 0.40])
    bloom_rgb = np.array([0.14, 0.40, 0.16])
    # the night side is the (high resolution) day map in faint moonlight
    moonlight = np.array([0.20, 0.24, 0.36])
    for y0 in range(0, H, chunk):
        ys = np.arange(y0, min(H, y0 + chunk)) + 0.5
        rows = slice(y0, y0 + len(ys))
        X, Y = np.meshgrid(xs, ys)
        lat, lon, q = proj.inverse(X.ravel(), Y.ravel())
        logq = np.log(q)

        def get(name: str):
            return sample(lay[name], lat, lon, logq) if name in lay else None

        day, cov = get("day")
        day /= np.maximum(cov, 1e-6)[:, None]

        if (s := get("chlorophyll")) is not None:
            # the value is log-scaled 0.01..20 mg/m³: 0.30 is ~0.1 mg/m³
            # (productive shelf water), 0.75 is ~3 mg/m³ (a bloom)
            v, _ = s
            present = v[:, 1]
            value = v[:, 0] / np.maximum(present, 1e-6)
            tint = lerp(np.tile(plankton_rgb, (len(value), 1)), bloom_rgb,
                        smoothstep(0.55, 0.85, value))
            day = lerp(day, tint, present * smoothstep(0.30, 0.75, value) * 0.7)
        if (s := get("ice")) is not None:
            day = lerp(day, ice_rgb, s[0][:, 0] * 0.9)
        if (s := get("snow")) is not None:
            day = lerp(day, snow_rgb, s[0][:, 0] * 0.85)

        cosz = subsolar_cos(lat, lon, *sun)
        light = smoothstep(-0.10, 0.08, cosz)
        day_lit = day * (0.55 + 0.45 * np.sqrt(np.clip(cosz, 0, 1)))[:, None]
        color = lerp(day * moonlight, day_lit, light)
        if (s := get("fire")) is not None:
            color = np.maximum(color, fire_rgb * 0.8 * s[0][:, 0][:, None])
        if (s := get("clouds")) is not None:
            cloud[rows] = np.clip(s[0][:, 0], 0, 1).reshape(len(ys), W)
        if (s := get("lights")) is not None:
            lights[rows] = (s[0][:, 0] * (1 - light)).reshape(len(ys), W)

        ground[rows] = color.reshape(len(ys), W, 3)
        cosz_f[rows] = cosz.reshape(len(ys), W)
        lat_f[rows] = lat.reshape(len(ys), W)
        lon_f[rows] = lon.reshape(len(ys), W)
        q_f[rows] = q.reshape(len(ys), W)

    scale = H / 1800
    light = smoothstep(-0.10, 0.08, cosz_f)
    if "clouds" in lay:
        cloud = cloud_detail(cloud, lat_f, lon_f, q_f)
    del lat_f, lon_f

    # sun direction on screen: cos(zenith) grows towards the sun
    gy, gx = np.gradient(cosz_f)
    norm = np.hypot(gx, gy)
    lx = np.where(norm > 1e-9, gx / np.maximum(norm, 1e-9), 0.0).astype(np.float32)
    ly = np.where(norm > 1e-9, gy / np.maximum(norm, 1e-9), 0.0).astype(np.float32)

    # shadows: the cloud seen from the ground towards the sun, displaced by
    # height / tan(elevation), only where the sun is up
    elev = np.arcsin(np.clip(cosz_f, 0.0, 1.0))
    offset = np.clip(CLOUD_HEIGHT_KM / np.maximum(np.tan(elev), 0.1) / q_f, 0, 40 * scale)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    soft = box_blur(cloud, max(1, round(1.5 * scale)))
    shadow = gather(soft, xx + lx * offset, yy + ly * offset)
    del xx, yy
    ground *= (1 - 0.45 * shadow * light * smoothstep(0.0, 0.15, cosz_f))[..., None]

    # relief: treat the (blurred) opacity as cloud height and light its
    # slopes; a slope facing the sun has its height falling towards the sun
    height = box_blur(cloud, max(1, round(2 * scale)))
    hy, hx = np.gradient(height)
    relief = np.clip(1 - 6.0 * (hx * lx + hy * ly) / scale, 0.6, 1.12)

    sunlit = light * (0.6 + 0.4 * np.sqrt(np.clip(cosz_f, 0, 1))) * relief
    cloud_rgb = (
        np.array([0.11, 0.12, 0.16], np.float32) * (1 - light)[..., None]
        + np.array([0.88, 0.89, 0.90], np.float32) * sunlit[..., None]
    )
    out = ground + (cloud_rgb - ground) * cloud[..., None]

    # city lights as a glow drawn in screen space: smooth at any zoom, so the
    # ~1 km squares of the source never show; clouds dim them
    lights *= 1 - 0.75 * cloud
    img = Image.fromarray(to_u8(lights), "L")
    core = np.asarray(img.filter(ImageFilter.GaussianBlur(0.9 * scale)), np.float32) / 255
    halo = np.asarray(img.filter(ImageFilter.GaussianBlur(6 * scale)), np.float32) / 255
    glow = np.minimum(core * 1.1 + halo * 0.8, 1.5)[..., None]
    out += glow * np.array([1.0, 0.80, 0.50], np.float32)
    return to_u8(out)


# --------------------------------------------------------------------------
# sky: sun, moon, planets and constellations at their sub-points


PLANETS = {
    "mercury": "☿",
    "venus": "♀",
    "mars": "♂",
    "jupiter": "♃",
    "saturn": "♄",
    "uranus": "♅",
    "neptune": "♆",
}


@dataclass
class Sky:
    bodies: dict[str, tuple[float, float]]
    moon_elongation: float
    lines: list[tuple[tuple[float, float], tuple[float, float]]]


def wrap180(x):
    return (np.asarray(x) + 180.0) % 360.0 - 180.0


def compute_sky(when: dt.datetime, constellations: Path | None) -> Sky:
    warnings.filterwarnings("ignore", module="astropy")
    warnings.filterwarnings("ignore", module="erfa")
    from astropy.utils import iers

    # offline: bundled IERS tables, UT1-UTC drift is far below a pixel
    iers.conf.auto_download = False
    iers.conf.auto_max_age = None
    iers.conf.iers_degraded_accuracy = "warn"
    import astropy.units as u
    from astropy.coordinates import TETE, SkyCoord, get_body
    from astropy.time import Time

    t = Time(when)
    gast = t.sidereal_time("apparent", "greenwich").deg
    frame = TETE(obstime=t)

    def subpoints(coord):
        c = coord.transform_to(frame)
        return np.asarray(c.dec.deg), wrap180(np.asarray(c.ra.deg) - gast)

    bodies = {}
    raw = {}
    for name in ["sun", "moon", *PLANETS]:
        raw[name] = get_body(name, t)
        la, lo = subpoints(raw[name])
        bodies[name] = (float(la), float(lo))
    elong = float(raw["sun"].separation(raw["moon"]).deg)

    lines = []
    if constellations is not None:
        feats = json.loads(constellations.read_text())["features"]
        strips = [
            line for f in feats for line in f["geometry"]["coordinates"] if len(line) > 1
        ]
        pts = np.array([p for line in strips for p in line], dtype=np.float64)
        la, lo = subpoints(SkyCoord(ra=pts[:, 0] * u.deg, dec=pts[:, 1] * u.deg, frame="icrs"))
        i = 0
        for line in strips:
            for k in range(len(line) - 1):
                lines.append(((la[i + k], lo[i + k]), (la[i + k + 1], lo[i + k + 1])))
            i += len(line)
    return Sky(bodies, elong, lines)


def to_vec(lat: float, lon: float) -> np.ndarray:
    la, lo = math.radians(lat), math.radians(lon)
    return np.array([math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la)])


def great_circle(a, b, proj: LensMap, max_px: float = 3.0) -> list[list[tuple[float, float]]]:
    """Project the great circle arc a->b, split where it wraps around the map."""
    va, vb = to_vec(*a), to_vec(*b)
    omega = math.acos(max(-1.0, min(1.0, float(va @ vb))))
    # sample densely, then drop points that add nothing on screen
    n = 2
    while n < 4096:
        ts = np.linspace(0, 1, n)
        if omega < 1e-9:
            vs = np.outer(1 - ts, va) + np.outer(ts, vb)
        else:
            vs = (np.outer(np.sin((1 - ts) * omega), va) + np.outer(np.sin(ts * omega), vb)) / math.sin(omega)
        lat = np.degrees(np.arcsin(np.clip(vs[:, 2], -1, 1)))
        lon = np.degrees(np.arctan2(vs[:, 1], vs[:, 0]))
        x, y = proj.forward(lat, lon)
        step = np.hypot(np.diff(x), np.diff(y))
        if step.max() <= max_px:
            break
        n *= 2
    pieces, cur = [], [(x[0], y[0])]
    for k, s in enumerate(step):
        if s > proj.width * 0.25:
            if len(cur) > 1:
                pieces.append(cur)
            cur = []
        cur.append((x[k + 1], y[k + 1]))
    if len(cur) > 1:
        pieces.append(cur)
    return pieces


def sun_icon(path: Path | None, size: int) -> Image.Image:
    if path is not None:
        try:
            img = Image.open(path).convert("RGB").resize((size, size), Image.LANCZOS)
            yy, xx = np.mgrid[:size, :size]
            r = np.hypot(xx - size / 2 + 0.5, yy - size / 2 + 0.5) / (size / 2)
            alpha = np.clip((0.86 - r) / 0.06, 0, 1)
            rgba = np.dstack([np.asarray(img), (alpha * 255).astype(np.uint8)])
            return Image.fromarray(rgba, "RGBA")
        except Exception as e:  # noqa: BLE001
            log(f"warning: sun image: {e}")
    img = Image.new("RGBA", (size, size))
    ImageDraw.Draw(img).ellipse((size * 0.2, size * 0.2, size * 0.8, size * 0.8), fill=(255, 210, 80, 255))
    return img


def moon_icon(size: int, elongation: float, sun_dir: tuple[float, float]) -> Image.Image:
    """Moon disc lit from screen direction sun_dir with the real phase."""
    phase = math.radians(180.0 - elongation)  # sun-moon-earth angle
    ex, ey = sun_dir
    yy, xx = np.mgrid[:size, :size]
    x = (xx + 0.5 - size / 2) / (size / 2)
    y = -(yy + 0.5 - size / 2) / (size / 2)
    r2 = x * x + y * y
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    lit = (x * ex + y * ey) * math.sin(phase) + z * math.cos(phase)
    shade = np.clip(lit * 4, 0, 1) * 0.85 + 0.12
    alpha = np.clip((1 - np.sqrt(r2)) * size / 2, 0, 1)
    g = (shade * 235).astype(np.uint8)
    rgba = np.dstack([g, g, (shade * 225).astype(np.uint8), (alpha * 255).astype(np.uint8)])
    return Image.fromarray(rgba, "RGBA")


def paste_centered(canvas: Image.Image, icon: Image.Image, x: float, y: float) -> None:
    canvas.alpha_composite(icon, (int(round(x - icon.width / 2)), int(round(y - icon.height / 2))))


def draw_lines(canvas: Image.Image, proj: LensMap, sky: Sky, scale: float) -> None:
    layer = Image.new("RGBA", canvas.size)
    d = ImageDraw.Draw(layer)
    width = max(1, round(1.2 * scale))
    for a, b in sky.lines:
        for piece in great_circle(a, b, proj):
            d.line(piece, fill=(255, 255, 255, 110), width=width, joint="curve")
    canvas.alpha_composite(layer)


def draw_bodies(canvas, proj, sky: Sky, scale: float, font_path, sun_image) -> None:
    sx, sy = proj.forward(*sky.bodies["sun"])
    mx, my = proj.forward(*sky.bodies["moon"])
    font = ImageFont.truetype(str(font_path), max(8, round(34 * scale))) if font_path else None
    d = ImageDraw.Draw(canvas)
    for name, glyph in PLANETS.items():
        x, y = proj.forward(*sky.bodies[name])
        if font is not None:
            d.text((float(x), float(y)), glyph, font=font, anchor="mm", fill=(254, 128, 25, 255),
                   stroke_width=max(1, round(2 * scale)), stroke_fill=(0, 0, 0, 200))
        else:
            r = 6 * scale
            d.ellipse((x - r, y - r, x + r, y + r), fill=(254, 128, 25, 255))
    dx, dy = float(sx - mx), float(my - sy)
    norm = math.hypot(dx, dy) or 1.0
    paste_centered(canvas, moon_icon(max(8, round(50 * scale)), sky.moon_elongation, (dx / norm, dy / norm)),
                   float(mx), float(my))
    paste_centered(canvas, sun_icon(sun_image, max(8, round(100 * scale))), float(sx), float(sy))


def draw_markers(canvas, proj, markers: list[tuple[float, float]], icon_path, scale: float) -> None:
    if not markers or icon_path is None:
        return
    size = max(8, round(20 * scale))
    icon = Image.open(icon_path).convert("RGBA").resize((size, size), Image.LANCZOS)
    for lat, lon in markers:
        x, y = proj.forward(lat, lon)
        paste_centered(canvas, icon, float(x), float(y))


def load_markers(path: Path | None) -> list[tuple[float, float]]:
    if path is None:
        return []
    try:
        data = json.loads(path.read_text())
    except Exception as e:  # noqa: BLE001
        log(f"warning: markers: {e}")
        return []
    entries = data.values() if isinstance(data, dict) else data
    out = []
    for v in entries:
        if isinstance(v, dict) and v.get("latitude") is not None and v.get("longitude") is not None:
            out.append((float(v["latitude"]), float(v["longitude"])))
    return out


def save(img: Image.Image, path: Path, **kw) -> None:
    tmp = path.with_name(f".{path.name}.tmp")
    img.save(tmp, format=path.suffix.lstrip(".").replace("jpg", "jpeg").upper(), **kw)
    os.replace(tmp, path)


# --------------------------------------------------------------------------


def main() -> None:
    env = os.environ.get
    p = argparse.ArgumentParser(prog="realwallpaper", description=__doc__.splitlines()[0])
    p.add_argument("--dir", type=Path, default=Path("."),
                   help="output and cache directory (default: .)")
    p.add_argument("--cache-dir", type=Path, default=None,
                   help="downloaded data, may be shared between runs for different homes "
                        "(default: DIR/cache)")
    p.add_argument("--lat", type=float, default=52.520008,
                   help="home latitude in degrees, south negative (default Berlin)")
    p.add_argument("--lon", type=float, default=13.404954,
                   help="home longitude in degrees, west negative (default Berlin)")
    p.add_argument("--width", type=int, default=3840)
    p.add_argument("--height", type=int, default=2160)
    p.add_argument("--magnification", type=float, default=6.0,
                   help="zoom at home relative to the plain map (default 6)")
    p.add_argument("--lens", type=float, default=1.0,
                   help="lens size relative to the screen; 1 reaches the edges (default 1)")
    p.add_argument("--lens-shape", choices=["circle", "ellipse", "rect"], default="ellipse",
                   help="circle; ellipse or rect follow the screen's aspect (default ellipse)")
    p.add_argument("--focus", type=float, default=0.0,
                   help="share of the lens zoomed undistorted before the transition (default 0)")
    p.add_argument("--falloff", type=float, default=0.65,
                   help="where across the lens (0..1) the distortion peaks; higher keeps "
                        "the middle closer to a plain zoom (default 0.65)")
    p.add_argument("--projection", choices=["lens", "plain", "world"], default="lens",
                   help="lens: centred on home with the zoom lens; plain: centred on home "
                        "without distortion; world: classic north-up map (default lens)")
    p.add_argument("--marker-url", default=None,
                   help="JSON with {name: {latitude, longitude}} for krebs markers")
    p.add_argument("--time", type=dt.datetime.fromisoformat, default=None,
                   help="render for this UTC time instead of now (ISO 8601)")
    p.add_argument("--no-archive", action="store_true", help="do not keep a jpg in archive/")
    args = p.parse_args()

    when = args.time or dt.datetime.now(dt.timezone.utc)
    if when.tzinfo is None:
        when = when.replace(tzinfo=dt.timezone.utc)
    when = when.astimezone(dt.timezone.utc)

    out_dir = args.dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    cache = Cache(args.cache_dir.resolve() if args.cache_dir else out_dir / "cache")
    proj = LensMap(args.lat, args.lon, args.width, args.height,
                   args.magnification, args.lens, args.lens_shape, args.focus, args.falloff,
                   args.projection)
    home_x, home_y = proj.forward(args.lat, args.lon)
    home_q = proj.inverse(np.array([home_x]), np.array([home_y]))[2][0]
    log(f"projection: {args.projection}, home at {home_q * 1000:.0f} m/px, "
        f"finest {proj.q0 * 1000:.0f} m/px")

    font = env("REALWALLPAPER_FONT")
    constellations = env("REALWALLPAPER_CONSTELLATIONS")
    krebs_icon = env("REALWALLPAPER_KREBS_ICON")

    t0 = time.monotonic()
    sun_image = cache.get_url("sun.jpg", "https://sdo.gsfc.nasa.gov/assets/img/latest/latest_512_0171.jpg", 3600)
    marker_file = cache.get_url("markers.json", args.marker_url, 0) if args.marker_url else None
    lay = load_layers(proj, cache, when)
    log(f"data ready in {time.monotonic() - t0:.1f}s")

    try:
        sky = compute_sky(when, Path(constellations) if constellations else None)
    except Exception as e:  # noqa: BLE001 - the map is still useful without the sky
        log(f"warning: sky: {e}")
        sky = None
    sun = sky.bodies["sun"] if sky else (0.0, 0.0)

    t0 = time.monotonic()
    base = Image.fromarray(render_base(proj, lay, sun)).convert("RGBA")
    log(f"rendered in {time.monotonic() - t0:.1f}s")

    scale = args.height / 1800
    markers = load_markers(marker_file)

    plain = base
    marker = plain.copy()
    if sky:
        draw_bodies(marker, proj, sky, scale, font, sun_image)
    krebs = marker.copy()
    draw_markers(krebs, proj, markers, krebs_icon, scale)
    stars = plain.copy()
    if sky:
        draw_lines(stars, proj, sky, scale)
        draw_bodies(stars, proj, sky, scale, font, sun_image)
    draw_markers(stars, proj, markers, krebs_icon, scale)

    for name, img in [
        ("realwallpaper.png", plain),
        ("realwallpaper-marker.png", marker),
        ("realwallpaper-krebs.png", krebs),
        ("realwallpaper-krebs-stars.png", stars),
    ]:
        save(img.convert("RGB"), out_dir / name, compress_level=3)
    if not args.no_archive:
        (out_dir / "archive").mkdir(exist_ok=True)
        save(krebs.convert("RGB"), out_dir / "archive" / f"{when.strftime('%Y-%m-%dT%H:%M:%SZ')}.jpg",
             quality=88)
    cache.cleanup()
    log("done")


if __name__ == "__main__":
    main()
