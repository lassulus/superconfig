"""book: a minimal request-and-approve booking page backed by CalDAV.

Guests pick a free slot and send a request. The request is held in SQLite,
mirrored into the owner's CalDAV calendar as a TENTATIVE event and mailed to
the owner with an approve/decline link. Approving turns the event CONFIRMED
and mails the guest an invitation; declining, cancelling or letting a request
run past its start time removes the event again.

Free/busy comes from every calendar in the CalDAV user's home collection plus
the held requests themselves. If the calendar cannot be read, no slots are
offered: an unreachable calendar must never look like an empty one.

The calendar is also a control surface: every minute the events of bookings
that have not started yet are read back. Deleting (or cancelling) one cancels
an approved booking or declines a request, moving one reschedules it, and
confirming a tentative request approves it -- each with the same mail to the
guest as the admin page would send. A calendar that cannot be read changes
nothing.

The only mail a stranger can trigger goes to the owner. Guests receive mail
only after the owner acted on their request, so the form cannot be abused to
send mail to arbitrary addresses.

With --busy-token-file, /busy/<token>.ics serves the same busy time (calendar
plus held requests) as an iCalendar feed of merged intervals that carry
nothing but their times.
"""

import argparse
import base64
import hashlib
import json
import logging
import os
import re
import secrets
import smtplib
import sqlite3
import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from zoneinfo import ZoneInfo, available_timezones

import icalendar
import jinja2
import recurring_ical_events

log = logging.getLogger("book")

UTC = timezone.utc
WEEKDAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
TIMEZONES = sorted(available_timezones())
SLOT_FORMAT = "%Y%m%dT%H%M%SZ"
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{20,64}$")
MAX_BODY = 16 * 1024
LIMITS = {"name": 100, "email": 254, "note": 2000, "message": 2000}
# The busy feed covers [now - BUSY_PAST, now + BUSY_AHEAD).
BUSY_PAST = timedelta(days=7)
BUSY_AHEAD = timedelta(days=90)

DAV = "DAV:"
CALDAV = "urn:ietf:params:xml:ns:caldav"


# --- configuration -----------------------------------------------------------


@dataclass(frozen=True)
class EventType:
    slug: str
    title: str
    minutes: int
    description: str


@dataclass(frozen=True)
class Config:
    listen_host: str
    listen_port: int
    base_url: str
    owner: str
    intro: str
    tz: ZoneInfo
    event_types: tuple[EventType, ...]
    hours: dict[int, tuple[tuple[int, int], ...]]  # weekday -> (start, end) minutes
    slot_step: int
    buffer: int
    min_notice: timedelta
    horizon: timedelta
    caldav_url: str
    caldav_user: str
    caldav_password: str
    caldav_calendar: str
    smtp_host: str
    smtp_port: int
    mail_from: str
    notify: str
    db: str
    templates: str
    static: str

    def event_type(self, slug: str) -> EventType | None:
        return next((e for e in self.event_types if e.slug == slug), None)


def parse_hhmm(s: str) -> int:
    h, m = s.split(":")
    minutes = int(h) * 60 + int(m)
    if not 0 <= minutes <= 24 * 60:
        raise ValueError(f"time out of range: {s}")
    return minutes


def load_config(path: str, password_file: str, templates: str, static: str) -> Config:
    raw = json.loads(Path(path).read_text())
    host, _, port = raw["listen"].rpartition(":")
    hours: dict[int, tuple[tuple[int, int], ...]] = {}
    for day, ranges in raw["hours"].items():
        spans = []
        for r in ranges:
            a, b = (parse_hhmm(x) for x in r.split("-"))
            if a >= b:
                raise ValueError(f"empty working-hours range {r} on {day}")
            spans.append((a, b))
        hours[WEEKDAYS.index(day)] = tuple(sorted(spans))
    event_types = tuple(
        EventType(e["slug"], e["title"], int(e["minutes"]), e.get("description", ""))
        for e in raw["eventTypes"]
    )
    for e in event_types:
        if not re.fullmatch(r"[a-z0-9-]+", e.slug) or e.slug in ("a", "r"):
            raise ValueError(f"invalid event type slug: {e.slug}")
    if not event_types:
        raise ValueError("no event types configured")
    caldav = raw["caldav"]
    smtp = raw["smtp"]
    return Config(
        listen_host=host,
        listen_port=int(port),
        base_url=raw["baseUrl"].rstrip("/"),
        owner=raw["owner"],
        intro=raw.get("intro", ""),
        tz=ZoneInfo(raw["timezone"]),
        event_types=event_types,
        hours=hours,
        slot_step=int(raw.get("slotStep", 30)),
        buffer=int(raw.get("bufferMinutes", 0)),
        min_notice=timedelta(hours=float(raw.get("minNoticeHours", 24))),
        horizon=timedelta(days=int(raw.get("horizonDays", 28))),
        caldav_url=caldav["url"].rstrip("/"),
        caldav_user=caldav["user"],
        caldav_password=Path(password_file).read_text().strip(),
        caldav_calendar=caldav.get("calendar", "bookings"),
        smtp_host=smtp.get("host", "127.0.0.1"),
        smtp_port=int(smtp.get("port", 25)),
        mail_from=smtp["from"],
        notify=smtp["notify"],
        db=raw["database"],
        templates=templates,
        static=static,
    )


# --- time helpers ------------------------------------------------------------


def now_utc() -> datetime:
    return datetime.now(UTC).replace(microsecond=0)


def to_utc(value: date | datetime, tz: ZoneInfo) -> datetime:
    """Normalise an iCalendar DATE/DATE-TIME to aware UTC.

    All-day dates start at local midnight; floating times are the owner's.
    """
    if not isinstance(value, datetime):
        value = datetime(value.year, value.month, value.day)
    if value.tzinfo is None:
        value = value.replace(tzinfo=tz)
    return value.astimezone(UTC)


def epoch(dt: datetime) -> int:
    return int(dt.timestamp())


def from_epoch(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, UTC)


def overlaps(a0: datetime, a1: datetime, intervals: list[tuple[datetime, datetime]]) -> bool:
    return any(a0 < b1 and b0 < a1 for b0, b1 in intervals)


def booking_event(data: bytes, uid: str) -> icalendar.Event:
    """The booking's VEVENT (not an overridden occurrence) from its calendar object.

    ValueError when the object cannot be read as one: that is never a deletion.
    """
    cal = icalendar.Calendar.from_ical(data)
    for ev in cal.walk("VEVENT"):
        if str(ev.get("UID", "")) == uid and "RECURRENCE-ID" not in ev:
            return ev
    raise ValueError(f"no VEVENT with UID {uid}")


# --- CalDAV ------------------------------------------------------------------


class CalDAVError(Exception):
    pass


class CalDAV:
    """Just enough CalDAV for one user's home: list, query, get, put, delete."""

    def __init__(self, cfg: Config):
        self.base = cfg.caldav_url
        self.home = f"/{quote(cfg.caldav_user)}/"
        self.calendar = f"{self.home}{quote(cfg.caldav_calendar)}/"
        token = base64.b64encode(f"{cfg.caldav_user}:{cfg.caldav_password}".encode()).decode()
        self.auth = f"Basic {token}"
        self.tz = cfg.tz
        self._ensured = False

    def _request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
        accept: tuple[int, ...] = (),
    ) -> tuple[int, bytes]:
        req = urllib.request.Request(self.base + path, data=body, method=method)
        req.add_header("Authorization", self.auth)
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            if e.code in accept:
                return e.code, e.read()
            raise CalDAVError(f"{method} {path}: HTTP {e.code}") from e
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise CalDAVError(f"{method} {path}: {e}") from e

    def _xml(self, method: str, path: str, depth: str, body: str, accept=()) -> tuple[int, ET.Element | None]:
        status, data = self._request(
            method,
            path,
            body.encode(),
            {"Depth": depth, "Content-Type": "application/xml; charset=utf-8"},
            accept,
        )
        if status >= 300 or not data.strip():
            return status, None
        try:
            return status, ET.fromstring(data)
        except ET.ParseError as e:
            raise CalDAVError(f"{method} {path}: unparseable response: {e}") from e

    def ensure_calendar(self) -> None:
        if self._ensured:
            return
        status, _ = self._xml(
            "PROPFIND",
            self.calendar,
            "0",
            f'<D:propfind xmlns:D="{DAV}"><D:prop><D:resourcetype/></D:prop></D:propfind>',
            accept=(404,),
        )
        if status == 404:
            log.info("creating calendar %s", self.calendar)
            self._xml(
                "MKCALENDAR",
                self.calendar,
                "0",
                f'<C:mkcalendar xmlns:D="{DAV}" xmlns:C="{CALDAV}"><D:set><D:prop>'
                "<D:displayname>Bookings</D:displayname>"
                '<C:supported-calendar-component-set><C:comp name="VEVENT"/>'
                "</C:supported-calendar-component-set></D:prop></D:set></C:mkcalendar>",
            )
        self._ensured = True

    def calendars(self) -> list[str]:
        _, root = self._xml(
            "PROPFIND",
            self.home,
            "1",
            f'<D:propfind xmlns:D="{DAV}" xmlns:C="{CALDAV}"><D:prop><D:resourcetype/>'
            "<C:supported-calendar-component-set/></D:prop></D:propfind>",
        )
        found = []
        for resp in root.iter(f"{{{DAV}}}response") if root is not None else ():
            href = resp.findtext(f"{{{DAV}}}href")
            if not href or resp.find(f".//{{{DAV}}}resourcetype/{{{CALDAV}}}calendar") is None:
                continue
            comps = [c.get("name") for c in resp.iter(f"{{{CALDAV}}}comp")]
            if comps and "VEVENT" not in comps:
                continue
            found.append(urlsplit(href).path)
        return found

    def busy(self, start: datetime, end: datetime) -> list[tuple[datetime, datetime]]:
        """Opaque, non-cancelled event occurrences in [start, end), in UTC."""
        span = (
            f'<C:time-range start="{start.strftime(SLOT_FORMAT)}" end="{end.strftime(SLOT_FORMAT)}"/>'
        )
        query = (
            f'<C:calendar-query xmlns:D="{DAV}" xmlns:C="{CALDAV}"><D:prop><C:calendar-data/></D:prop>'
            '<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">'
            f"{span}</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>"
        )
        out: list[tuple[datetime, datetime]] = []
        for path in self.calendars():
            _, root = self._xml("REPORT", path, "1", query)
            for data in root.iter(f"{{{CALDAV}}}calendar-data") if root is not None else ():
                if not data.text:
                    continue
                try:
                    cal = icalendar.Calendar.from_ical(data.text)
                    occurrences = recurring_ical_events.of(cal, skip_bad_series=True).between(start, end)
                except Exception:
                    log.exception("unparseable event in %s", path)
                    continue
                for ev in occurrences:
                    if str(ev.get("TRANSP", "OPAQUE")).upper() == "TRANSPARENT":
                        continue
                    if str(ev.get("STATUS", "")).upper() == "CANCELLED":
                        continue
                    try:
                        out.append((to_utc(ev.start, self.tz), to_utc(ev.end, self.tz)))
                    except Exception:
                        log.exception("event without usable start/end in %s", path)
        return out

    def put(self, uid: str, ics: bytes) -> None:
        self.ensure_calendar()
        self._request(
            "PUT",
            f"{self.calendar}{quote(uid)}.ics",
            ics,
            {"Content-Type": "text/calendar; charset=utf-8"},
        )

    def delete(self, uid: str) -> None:
        self._request("DELETE", f"{self.calendar}{quote(uid)}.ics", accept=(404,))

    def get(self, uid: str) -> bytes | None:
        """The booking's calendar object, None once it is gone from the calendar."""
        status, data = self._request("GET", f"{self.calendar}{quote(uid)}.ics", accept=(404,))
        return None if status == 404 else data


# --- storage -----------------------------------------------------------------


SCHEMA = """
CREATE TABLE IF NOT EXISTS bookings (
  id INTEGER PRIMARY KEY,
  uid TEXT NOT NULL UNIQUE,
  event TEXT NOT NULL,
  title TEXT NOT NULL,
  start INTEGER NOT NULL,
  end INTEGER NOT NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  note TEXT NOT NULL,
  guest_tz TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'declined', 'cancelled', 'expired')),
  guest_token TEXT NOT NULL UNIQUE,
  admin_token TEXT NOT NULL UNIQUE,
  sequence INTEGER NOT NULL DEFAULT 0,
  created INTEGER NOT NULL,
  updated INTEGER NOT NULL,
  ip TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bookings_active ON bookings (status, start);
"""

ACTIVE = ("pending", "approved")


class Store:
    """One connection behind one lock; traffic here is a handful of requests a day."""

    def __init__(self, path: str):
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)

    def holds(self, start: datetime, end: datetime) -> list[tuple[datetime, datetime]]:
        with self.lock:
            rows = self.db.execute(
                "SELECT start, end FROM bookings WHERE status IN (?, ?) AND end > ? AND start < ?",
                (*ACTIVE, epoch(start), epoch(end)),
            ).fetchall()
        return [(from_epoch(r["start"]), from_epoch(r["end"])) for r in rows]

    def by_token(self, column: str, token: str) -> sqlite3.Row | None:
        assert column in ("guest_token", "admin_token")
        with self.lock:
            return self.db.execute(f"SELECT * FROM bookings WHERE {column} = ?", (token,)).fetchone()

    def count(self, where: str, args: tuple) -> int:
        with self.lock:
            return self.db.execute(f"SELECT count(*) FROM bookings WHERE {where}", args).fetchone()[0]

    def insert(self, **row) -> None:
        cols = ", ".join(row)
        marks = ", ".join("?" for _ in row)
        with self.lock:
            self.db.execute(f"INSERT INTO bookings ({cols}) VALUES ({marks})", tuple(row.values()))

    def set_status(self, booking_id: int, status: str) -> None:
        with self.lock:
            self.db.execute(
                "UPDATE bookings SET status = ?, sequence = sequence + 1, updated = ? WHERE id = ?",
                (status, epoch(now_utc()), booking_id),
            )

    def get(self, booking_id: int) -> sqlite3.Row:
        with self.lock:
            return self.db.execute("SELECT * FROM bookings WHERE id = ?", (booking_id,)).fetchone()

    def overdue(self, now: datetime) -> list[sqlite3.Row]:
        with self.lock:
            return self.db.execute(
                "SELECT * FROM bookings WHERE status = 'pending' AND start <= ?", (epoch(now),)
            ).fetchall()

    def upcoming(self, now: datetime) -> list[sqlite3.Row]:
        """Active bookings that have not started yet: the ones the calendar can still change.

        Started ones are left alone, so tidying up a running or past meeting in
        the calendar never mails the guest.
        """
        with self.lock:
            return self.db.execute(
                "SELECT * FROM bookings WHERE status IN (?, ?) AND start > ?", (*ACTIVE, epoch(now))
            ).fetchall()

    def reschedule(self, booking_id: int, start: datetime, end: datetime) -> None:
        with self.lock:
            self.db.execute(
                "UPDATE bookings SET start = ?, end = ?, sequence = sequence + 1, updated = ? WHERE id = ?",
                (epoch(start), epoch(end), epoch(now_utc()), booking_id),
            )


# --- the application ---------------------------------------------------------


class Unavailable(Exception):
    """The calendar could not be read; refuse to guess."""


class App:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.cal = CalDAV(cfg)
        self.store = Store(cfg.db)
        self.rate: dict[str, deque[float]] = defaultdict(deque)
        self.jinja = jinja2.Environment(
            loader=jinja2.FileSystemLoader(cfg.templates),
            autoescape=jinja2.select_autoescape(["html.j2"]),
            undefined=jinja2.StrictUndefined,
            trim_blocks=True,
            lstrip_blocks=True,
        )

    # availability

    def candidates(self, et: EventType, start: datetime, end: datetime) -> list[datetime]:
        """Slot starts inside working hours, notice and horizon, ignoring busy times."""
        cfg = self.cfg
        now = now_utc()
        earliest = max(start, now + cfg.min_notice)
        latest = min(end, now + cfg.horizon)
        if earliest >= latest:
            return []
        out = []
        day = earliest.astimezone(cfg.tz).date() - timedelta(days=1)
        last = latest.astimezone(cfg.tz).date()
        while day <= last:
            for a, b in cfg.hours.get(day.weekday(), ()):
                m = a
                while m + et.minutes <= b:
                    local = datetime(day.year, day.month, day.day) + timedelta(minutes=m)
                    slot = local.replace(tzinfo=cfg.tz).astimezone(UTC)
                    # Skip nonexistent local times (DST gap): they do not round-trip.
                    if slot.astimezone(cfg.tz).replace(tzinfo=None) == local and earliest <= slot < latest:
                        out.append(slot)
                    m += cfg.slot_step
            day += timedelta(days=1)
        return sorted(set(out))

    def free_slots(self, et: EventType, start: datetime, end: datetime) -> list[datetime]:
        slots = self.candidates(et, start, end)
        if not slots:
            return []
        pad = timedelta(minutes=self.cfg.buffer)
        length = timedelta(minutes=et.minutes)
        window = (slots[0] - pad, slots[-1] + length + pad)
        try:
            busy = self.cal.busy(*window)
        except CalDAVError as e:
            log.error("cannot read calendar: %s", e)
            raise Unavailable from e
        busy += self.store.holds(*window)
        return [s for s in slots if not overlaps(s - pad, s + length + pad, busy)]

    def busy_feed(self) -> bytes:
        """Busy time around now as a VCALENDAR without any event details.

        Overlapping and adjacent intervals are merged; the UID is a hash of
        the interval's times.
        """
        now = now_utc()
        start, end = now - BUSY_PAST, now + BUSY_AHEAD
        try:
            busy = self.cal.busy(start, end)
        except CalDAVError as e:
            log.error("cannot read calendar: %s", e)
            raise Unavailable from e
        busy += self.store.holds(start, end)
        merged: list[list[datetime]] = []
        for a, b in sorted(busy):
            if merged and a <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], b)
            elif a < b:
                merged.append([a, b])
        cal = icalendar.Calendar()
        cal.add("prodid", "-//lassul.us//book busy//EN")
        cal.add("version", "2.0")
        for a, b in merged:
            ev = icalendar.Event()
            digest = hashlib.sha256(f"{epoch(a)}-{epoch(b)}".encode()).hexdigest()
            ev.add("uid", f"{digest[:32]}@busy")
            ev.add("dtstamp", now)
            ev.add("dtstart", a)
            ev.add("dtend", b)
            ev.add("summary", "Busy")
            ev.add("transp", "OPAQUE")
            cal.add_component(ev)
        return cal.to_ical()

    # mail

    def send(
        self,
        to: str,
        subject: str,
        body: str,
        reply_to: str | None = None,
        ics: bytes | None = None,
        method: str | None = None,
    ) -> None:
        msg = EmailMessage()
        msg["From"] = formataddr((self.cfg.owner, self.cfg.mail_from))
        msg["To"] = to
        msg["Subject"] = subject
        msg["Date"] = formatdate(localtime=False)
        msg["Message-ID"] = make_msgid(domain=self.cfg.mail_from.rpartition("@")[2])
        if reply_to:
            msg["Reply-To"] = reply_to
        msg.set_content(body)
        if ics is not None:
            msg.add_attachment(
                ics,
                maintype="text",
                subtype="calendar",
                filename="invite.ics",
                params={"method": method or "PUBLISH"},
            )
        try:
            with smtplib.SMTP(self.cfg.smtp_host, self.cfg.smtp_port, timeout=15) as s:
                s.send_message(msg)
        except (smtplib.SMTPException, OSError):
            log.exception("sending mail to %s failed", to)

    def render_text(self, template: str, **ctx) -> str:
        return self.jinja.get_template(template).render(cfg=self.cfg, **ctx)

    # calendar objects

    def ics(self, b: sqlite3.Row, *, owner_copy: bool, method: str | None = None) -> bytes:
        cfg = self.cfg
        cal = icalendar.Calendar()
        cal.add("prodid", "-//lassul.us//book//EN")
        cal.add("version", "2.0")
        if method:
            cal.add("method", method)
        ev = icalendar.Event()
        ev.add("uid", b["uid"])
        ev.add("sequence", b["sequence"])
        ev.add("dtstamp", now_utc())
        ev.add("dtstart", from_epoch(b["start"]))
        ev.add("dtend", from_epoch(b["end"]))
        if owner_copy:
            pending = b["status"] == "pending"
            summary = f"{'? ' if pending else ''}{b['name']}: {b['title']}"
            ev.add("summary", summary)
            ev.add("status", "TENTATIVE" if pending else "CONFIRMED")
            ev.add(
                "description",
                f"{b['name']} <{b['email']}>\n\n{b['note']}\n\n{cfg.base_url}/a/{b['admin_token']}",
            )
            alarm = icalendar.Alarm()
            alarm.add("action", "DISPLAY")
            alarm.add("trigger", timedelta(minutes=-10))
            alarm.add("description", summary)
            ev.add_component(alarm)
        else:
            ev.add("summary", f"{b['title']} with {cfg.owner}")
            ev.add("status", "CANCELLED" if method == "CANCEL" else "CONFIRMED")
            ev.add("description", f"{b['note']}\n\n{cfg.base_url}/r/{b['guest_token']}")
            ev.add("organizer", f"mailto:{cfg.notify}", parameters={"CN": cfg.owner})
            ev.add(
                "attendee",
                f"mailto:{b['email']}",
                parameters={"CN": b["name"], "ROLE": "REQ-PARTICIPANT", "PARTSTAT": "ACCEPTED"},
            )
        cal.add_component(ev)
        return cal.to_ical()

    def mirror(self, b: sqlite3.Row) -> None:
        """Keep the owner's calendar in line with the booking; best effort."""
        try:
            if b["status"] in ACTIVE:
                self.cal.put(b["uid"], self.ics(b, owner_copy=True))
            else:
                self.cal.delete(b["uid"])
        except CalDAVError as e:
            log.error("calendar mirror for %s failed: %s", b["uid"], e)

    # state transitions

    def request(self, et: EventType, start: datetime, form: dict[str, str], guest_tz: str, ip: str) -> str:
        cfg = self.cfg
        with self.store.lock:
            if start not in self.free_slots(et, start, start + timedelta(seconds=1)):
                raise ValueError("That time is no longer available.")
            token = secrets.token_urlsafe(24)
            self.store.insert(
                uid=f"{secrets.token_hex(16)}@{urlsplit(cfg.base_url).hostname}",
                event=et.slug,
                title=et.title,
                start=epoch(start),
                end=epoch(start + timedelta(minutes=et.minutes)),
                name=form["name"],
                email=form["email"],
                note=form["note"],
                guest_tz=guest_tz,
                status="pending",
                guest_token=token,
                admin_token=secrets.token_urlsafe(24),
                created=epoch(now_utc()),
                updated=epoch(now_utc()),
                ip=ip,
            )
            b = self.store.by_token("guest_token", token)
        self.mirror(b)
        self.send(
            cfg.notify,
            f"Booking request: {b['name']}, {self.when(b, cfg.tz)}",
            self.render_text("mail/request.txt", b=b, when=self.when(b, cfg.tz)),
            reply_to=formataddr((b["name"], b["email"])),
        )
        return token

    def transition(self, b: sqlite3.Row, status: str, message: str = "") -> sqlite3.Row:
        """Move a booking to `status`, mirror it and mail whoever needs to know."""
        cfg = self.cfg
        with self.store.lock:
            current = self.store.get(b["id"])
            allowed = {
                "approved": ("pending",),
                "declined": ("pending",),
                "cancelled": ACTIVE,
                "expired": ("pending",),
            }[status]
            if current["status"] not in allowed:
                return current
            was = current["status"]
            self.store.set_status(b["id"], status)
            b = self.store.get(b["id"])
        self.mirror(b)
        guest_when = self.when(b, ZoneInfo(b["guest_tz"]))
        ctx = {"b": b, "when": guest_when, "message": message}
        if status == "approved":
            self.send(
                b["email"],
                f"Confirmed: {b['title']} with {cfg.owner}, {guest_when}",
                self.render_text("mail/approved.txt", **ctx),
                reply_to=cfg.notify,
                ics=self.ics(b, owner_copy=False, method="REQUEST"),
                method="REQUEST",
            )
        elif status == "declined":
            self.send(
                b["email"],
                f"Declined: {b['title']} with {cfg.owner}, {guest_when}",
                self.render_text("mail/declined.txt", **ctx),
                reply_to=cfg.notify,
            )
        elif status == "cancelled" and was == "approved":
            # The guest holds an invitation; withdraw it either way.
            self.send(
                b["email"],
                f"Cancelled: {b['title']} with {cfg.owner}, {guest_when}",
                self.render_text("mail/cancelled.txt", **ctx),
                reply_to=cfg.notify,
                ics=self.ics(b, owner_copy=False, method="CANCEL"),
                method="CANCEL",
            )
        return b

    def guest_cancel(self, b: sqlite3.Row) -> sqlite3.Row:
        b = self.transition(b, "cancelled")
        if b["status"] == "cancelled":
            self.send(
                self.cfg.notify,
                f"Cancelled by guest: {b['name']}, {self.when(b, self.cfg.tz)}",
                self.render_text("mail/guest-cancelled.txt", b=b, when=self.when(b, self.cfg.tz)),
                reply_to=formataddr((b["name"], b["email"])),
            )
        return b

    def sweep(self) -> None:
        for b in self.store.overdue(now_utc()):
            log.info("expiring unanswered request %s", b["uid"])
            self.transition(b, "expired")

    def reschedule(self, b: sqlite3.Row, start: datetime, end: datetime) -> sqlite3.Row:
        """Move a booking, mirror it and send an approved guest the updated invitation."""
        cfg = self.cfg
        with self.store.lock:
            current = self.store.get(b["id"])
            if current["status"] not in ACTIVE:
                return current
            before = self.when(current, ZoneInfo(current["guest_tz"]))
            self.store.reschedule(b["id"], start, end)
            b = self.store.get(b["id"])
        self.mirror(b)
        if b["status"] == "approved":
            guest_when = self.when(b, ZoneInfo(b["guest_tz"]))
            self.send(
                b["email"],
                f"Rescheduled: {b['title']} with {cfg.owner}, {guest_when}",
                self.render_text("mail/rescheduled.txt", b=b, when=guest_when, before=before),
                reply_to=cfg.notify,
                ics=self.ics(b, owner_copy=False, method="REQUEST"),
                method="REQUEST",
            )
        return b

    def reconcile(self) -> None:
        """Apply what the owner changed on booking events in the calendar.

        CalDAVError propagates: an unreadable calendar must never be taken for
        deleted events.
        """
        for b in self.store.upcoming(now_utc()):
            data = self.cal.get(b["uid"])
            if data is None:
                ev, status = None, "CANCELLED"
            else:
                try:
                    ev = booking_event(data, b["uid"])
                except ValueError:
                    log.exception("booking %s is unreadable in the calendar; left as is", b["uid"])
                    continue
                status = str(ev.get("STATUS", "")).upper()
            if status == "CANCELLED":
                log.info("booking %s removed from the calendar", b["uid"])
                self.transition(b, "cancelled" if b["status"] == "approved" else "declined")
                continue
            try:
                start, end = to_utc(ev.start, self.cfg.tz), to_utc(ev.end, self.cfg.tz)
            except Exception:
                log.exception("booking %s has no usable start/end in the calendar", b["uid"])
                continue
            if end <= start:
                log.error("booking %s ends before it starts in the calendar; ignored", b["uid"])
                continue
            if (epoch(start), epoch(end)) != (b["start"], b["end"]):
                log.info("booking %s moved in the calendar", b["uid"])
                b = self.reschedule(b, start, end)
            if b["status"] == "pending" and status == "CONFIRMED":
                log.info("request %s confirmed in the calendar", b["uid"])
                self.transition(b, "approved")

    def rate_limited(self, ip: str, limit: int = 5, window: float = 3600) -> bool:
        with self.store.lock:
            q = self.rate[ip]
            t = time.monotonic()
            while q and q[0] < t - window:
                q.popleft()
            if len(q) >= limit:
                return True
            q.append(t)
            return False

    # formatting

    @staticmethod
    def when(b: sqlite3.Row, tz: ZoneInfo) -> str:
        s = from_epoch(b["start"]).astimezone(tz)
        e = from_epoch(b["end"]).astimezone(tz)
        return f"{s:%a %d %b %Y, %H:%M}–{e:%H:%M} ({tz.key})"


# --- HTTP --------------------------------------------------------------------


STATIC = {
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/tz.js": ("tz.js", "text/javascript; charset=utf-8"),
    "/font.woff": ("font.woff", "font/woff"),
    "/robots.txt": ("robots.txt", "text/plain; charset=utf-8"),
}

CSP = (
    "default-src 'none'; style-src 'self'; script-src 'self'; font-src 'self'; "
    "form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
)


class HTTPError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class Handler(BaseHTTPRequestHandler):
    app: App
    busy_token: str | None = None
    server_version = "book"
    sys_version = ""

    # plumbing

    def log_message(self, fmt: str, *args) -> None:
        log.info("%s %s", self.client_ip(), fmt % args)

    def client_ip(self) -> str:
        peer = self.client_address[0]
        if peer in ("127.0.0.1", "::1"):
            return self.headers.get("X-Real-IP", peer)
        return peer

    def respond(self, status: HTTPStatus, body: bytes, ctype: str, headers: dict[str, str] | None = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def page(self, template: str, status: HTTPStatus = HTTPStatus.OK, **ctx) -> None:
        html = self.app.jinja.get_template(template).render(cfg=self.app.cfg, **ctx)
        self.respond(status, html.encode(), "text/html; charset=utf-8", {"Cache-Control": "no-store"})

    def redirect(self, location: str) -> None:
        self.respond(HTTPStatus.SEE_OTHER, b"", "text/plain", {"Location": location})

    def query(self) -> dict[str, str]:
        return {k: v[0] for k, v in parse_qs(urlsplit(self.path).query).items()}

    def form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            raise HTTPError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "Request too large.")
        raw = self.rfile.read(length).decode("utf-8", "replace")
        return {k: v[0] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    def guest_tz(self, q: dict[str, str]) -> ZoneInfo:
        tz = q.get("tz", "")
        return ZoneInfo(tz) if tz in TIMEZONES else self.app.cfg.tz

    def dispatch(self, method: str) -> None:
        path = urlsplit(self.path).path
        parts = [p for p in path.split("/") if p]
        try:
            if method == "GET" and path in STATIC:
                return self.static(*STATIC[path])
            if not parts:
                return self.index() if method == "GET" else self.not_found()
            head, rest = parts[0], parts[1:]
            if head == "busy":
                if (
                    method == "GET"
                    and self.busy_token
                    and len(rest) == 1
                    and secrets.compare_digest(rest[0].encode(), f"{self.busy_token}.ics".encode())
                ):
                    return self.respond(
                        HTTPStatus.OK,
                        self.app.busy_feed(),
                        "text/calendar; charset=utf-8",
                        {"Cache-Control": "no-store"},
                    )
                return self.not_found()
            if head in ("a", "r") and rest and TOKEN_RE.match(rest[0]):
                column = "admin_token" if head == "a" else "guest_token"
                b = self.app.store.by_token(column, rest[0])
                if b is None:
                    return self.not_found()
                action = rest[1] if len(rest) > 1 else ""
                if head == "a":
                    return self.admin(method, b, action)
                return self.guest(method, b, action)
            et = self.app.cfg.event_type(head)
            if et is None or len(rest) > 1:
                return self.not_found()
            if not rest:
                return self.slots(et) if method == "GET" else self.not_found()
            try:
                start = datetime.strptime(rest[0], SLOT_FORMAT).replace(tzinfo=UTC)
            except ValueError:
                return self.not_found()
            return self.book(method, et, start)
        except HTTPError as e:
            self.page("message.html.j2", e.status, title="Error", message=e.message)
        except Unavailable:
            self.page(
                "message.html.j2",
                HTTPStatus.SERVICE_UNAVAILABLE,
                title="Unavailable",
                message="The calendar cannot be read right now. Please try again later.",
            )

    def do_GET(self) -> None:
        self.dispatch("GET")

    def do_HEAD(self) -> None:
        self.dispatch("GET")

    def do_POST(self) -> None:
        self.dispatch("POST")

    def not_found(self) -> None:
        self.page("message.html.j2", HTTPStatus.NOT_FOUND, title="Not found", message="Nothing here.")

    def static(self, name: str, ctype: str) -> None:
        try:
            body = (Path(self.app.cfg.static) / name).read_bytes()
        except FileNotFoundError:
            return self.not_found()
        self.respond(HTTPStatus.OK, body, ctype, {"Cache-Control": "public, max-age=86400"})

    # public pages

    def index(self) -> None:
        cfg = self.app.cfg
        q = self.query()
        if len(cfg.event_types) == 1:
            return self.redirect(f"/{cfg.event_types[0].slug}?{urlencode(q)}")
        # Only pass on an explicit zone: pinning the owner's here would stop
        # tz.js from detecting the visitor's zone on the next page.
        tzq = urlencode({"tz": q["tz"]}) if q.get("tz") in TIMEZONES else ""
        self.page("index.html.j2", tzq=tzq)

    def slots(self, et: EventType) -> None:
        q = self.query()
        tz = self.guest_tz(q)
        today = now_utc().astimezone(tz).date()
        try:
            first = date.fromisoformat(q.get("from", ""))
        except ValueError:
            first = today
        first = max(first, today)
        days = [first + timedelta(days=i) for i in range(7)]
        start = datetime(first.year, first.month, first.day, tzinfo=tz).astimezone(UTC)
        end = datetime(days[-1].year, days[-1].month, days[-1].day, tzinfo=tz).astimezone(UTC) + timedelta(days=1)
        by_day: dict[date, list[datetime]] = {d: [] for d in days}
        for s in self.app.free_slots(et, start, end):
            local = s.astimezone(tz)
            if local.date() in by_day:
                by_day[local.date()].append(local)
        horizon = (now_utc() + self.app.cfg.horizon).astimezone(tz).date()
        prev_first = max(first - timedelta(days=7), today) if first > today else None
        next_first = first + timedelta(days=7) if first + timedelta(days=7) <= horizon else None
        self.page(
            "slots.html.j2",
            et=et,
            tz=tz,
            days=by_day,
            fmt=SLOT_FORMAT,
            utc=UTC,
            timezones=TIMEZONES,
            prev=prev_first and urlencode({"tz": tz.key, "from": prev_first.isoformat()}),
            next=next_first and urlencode({"tz": tz.key, "from": next_first.isoformat()}),
            tzq=urlencode({"tz": tz.key}),
            tzaware=True,
        )

    def book(self, method: str, et: EventType, start: datetime) -> None:
        q = self.query()
        tz = self.guest_tz(q)
        values = {"name": "", "email": "", "note": ""}
        error = ""
        if method == "POST":
            form = self.form()
            tz = self.guest_tz(form)
            values = {k: form.get(k, "").strip() for k in values}
            if form.get("website"):  # honeypot: pretend it worked, do nothing
                return self.page("message.html.j2", title="Request sent", message="Request sent.")
            error = self.validate(values)
            if not error:
                ip = self.client_ip()
                if self.app.rate_limited(ip):
                    error = "Too many requests from your address. Please try again later."
                elif self.app.store.count("status = 'pending'", ()) >= 30:
                    error = "Too many open requests right now. Please try again later."
                elif self.app.store.count("status = 'pending' AND email = ?", (values["email"],)) >= 3:
                    error = "You already have several open requests."
                else:
                    try:
                        token = self.app.request(et, start, values, tz.key, ip)
                    except ValueError as e:
                        error = str(e)
                    else:
                        return self.redirect(f"/r/{token}")
        elif start not in self.app.free_slots(et, start, start + timedelta(seconds=1)):
            return self.page(
                "message.html.j2",
                HTTPStatus.GONE,
                title="Taken",
                message="That time is not available.",
                back=f"/{et.slug}?{urlencode({'tz': tz.key})}",
            )
        self.page(
            "book.html.j2",
            HTTPStatus.BAD_REQUEST if error else HTTPStatus.OK,
            et=et,
            tz=tz,
            start=start.astimezone(tz),
            end=(start + timedelta(minutes=et.minutes)).astimezone(tz),
            values=values,
            error=error,
            back=f"/{et.slug}?{urlencode({'tz': tz.key})}",
            tzaware=True,
        )

    @staticmethod
    def validate(values: dict[str, str]) -> str:
        for k, limit in LIMITS.items():
            if len(values.get(k, "")) > limit:
                return f"The {k} is too long."
        if not values["name"]:
            return "Please tell me your name."
        if any(c in values["name"] for c in "\r\n<>\"") or "@" in values["name"]:
            return "Please use a plain name."
        if not EMAIL_RE.match(values["email"]) or any(c in values["email"] for c in "\r\n<>,\"'"):
            return "That email address does not look right."
        return ""

    # token pages: GET only renders, POST acts, so link scanners cannot click buttons

    def guest(self, method: str, b: sqlite3.Row, action: str) -> None:
        if action == "invite.ics" and method == "GET" and b["status"] == "approved":
            return self.respond(
                HTTPStatus.OK,
                self.app.ics(b, owner_copy=False, method="PUBLISH"),
                "text/calendar; charset=utf-8",
                {"Content-Disposition": 'attachment; filename="invite.ics"', "Cache-Control": "no-store"},
            )
        if action == "cancel" and method == "POST":
            self.app.guest_cancel(b)
            return self.redirect(f"/r/{b['guest_token']}")
        if action or method != "GET":
            return self.not_found()
        tz = ZoneInfo(b["guest_tz"])
        self.page(
            "request.html.j2",
            b=b,
            when=self.app.when(b, tz),
            future=from_epoch(b["start"]) > now_utc(),
            noindex=True,
        )

    def admin(self, method: str, b: sqlite3.Row, action: str) -> None:
        if method == "POST" and action in ("approve", "decline", "cancel"):
            message = self.form().get("message", "").strip()[: LIMITS["message"]]
            status = {"approve": "approved", "decline": "declined", "cancel": "cancelled"}[action]
            self.app.transition(b, status, message)
            return self.redirect(f"/a/{b['admin_token']}")
        if action or method != "GET":
            return self.not_found()
        self.page(
            "admin.html.j2",
            b=b,
            when=self.app.when(b, self.app.cfg.tz),
            guest_when=self.app.when(b, ZoneInfo(b["guest_tz"])),
            future=from_epoch(b["start"]) > now_utc(),
            noindex=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True, help="JSON configuration file")
    parser.add_argument("--caldav-password-file", required=True, help="file holding the CalDAV password")
    parser.add_argument("--templates", default=os.environ.get("BOOK_TEMPLATES"), required="BOOK_TEMPLATES" not in os.environ)
    parser.add_argument("--static", default=os.environ.get("BOOK_STATIC"), required="BOOK_STATIC" not in os.environ)
    parser.add_argument("--busy-token-file", help="file holding the secret of the busy feed /busy/<token>.ics")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    cfg = load_config(args.config, args.caldav_password_file, args.templates, args.static)
    app = App(cfg)
    try:
        app.cal.ensure_calendar()
    except CalDAVError as e:
        log.error("calendar not reachable yet: %s", e)

    def sweeper() -> None:
        while True:
            try:
                app.sweep()
            except Exception:
                log.exception("sweep failed")
            try:
                app.reconcile()
            except CalDAVError as e:
                log.error("cannot read bookings back from the calendar: %s", e)
            except Exception:
                log.exception("reconcile failed")
            time.sleep(60)

    threading.Thread(target=sweeper, daemon=True).start()
    Handler.app = app
    if args.busy_token_file:
        Handler.busy_token = Path(args.busy_token_file).read_text().strip()
    server = ThreadingHTTPServer((cfg.listen_host, cfg.listen_port), Handler)
    server.daemon_threads = True
    log.info("listening on %s:%d", cfg.listen_host, cfg.listen_port)
    server.serve_forever()


if __name__ == "__main__":
    main()
