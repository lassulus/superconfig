"""Prometheus exporter for the DOCSIS side of a FRITZ!Box Cable (6670 & co).

DOCSIS channels come from the web UI's cable information page (data.lua,
page docInfo); router and connection status from TR-064. The web UI session
is kept between scrapes and only renewed when the box rejects it: a login
per scrape would fill the FRITZ!Box event log.
"""

import argparse
import hashlib
import logging
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests
from fritzconnection import FritzConnection
from fritzconnection.core.exceptions import FritzConnectionException

log = logging.getLogger("fritzbox-cable-exporter")

TIMEOUT = 15
NO_SID = "0" * 16


class LoginError(Exception):
    pass


class FritzBox:
    def __init__(self, host: str, password: str) -> None:
        self.host = host
        self.url = f"http://{host}"
        self.password = password
        self.session = requests.Session()
        self.sid = NO_SID
        self.user: str | None = None
        self.tr064: FritzConnection | None = None

    def login(self) -> None:
        """login_sid.lua version 2: PBKDF2 challenge-response."""
        r = self.session.get(f"{self.url}/login_sid.lua?version=2", timeout=TIMEOUT)
        r.raise_for_status()
        challenge = re.search(r"<Challenge>(.*?)</Challenge>", r.text)
        # the user that logged in last is marked; boxes without users list none
        users = re.findall(r"<User(?:\s[^>]*)?>(.*?)</User>", r.text)
        if not challenge or not challenge.group(1).startswith("2$"):
            raise LoginError(f"unexpected login challenge: {r.text[:200]}")
        _, iter1, salt1, iter2, salt2 = challenge.group(1).split("$")
        hash1 = hashlib.pbkdf2_hmac(
            "sha256", self.password.encode(), bytes.fromhex(salt1), int(iter1)
        )
        hash2 = hashlib.pbkdf2_hmac("sha256", hash1, bytes.fromhex(salt2), int(iter2))
        self.user = users[0] if users else ""
        r = self.session.post(
            f"{self.url}/login_sid.lua?version=2",
            data={"username": self.user, "response": f"{salt2}${hash2.hex()}"},
            timeout=TIMEOUT,
        )
        r.raise_for_status()
        sid = re.search(r"<SID>(.*?)</SID>", r.text)
        if not sid or sid.group(1) == NO_SID:
            block = re.search(r"<BlockTime>(\d+)</BlockTime>", r.text)
            raise LoginError(
                f"login as {self.user!r} refused (block time {block.group(1) if block else '?'}s)"
            )
        self.sid = sid.group(1)
        log.info("logged into the web UI as %s", self.user)

    def page(self, name: str) -> dict:
        """A data.lua page; logs in again once when the session is gone (the
        box then answers with the HTML login page instead of JSON)."""
        for attempt in range(2):
            if self.sid == NO_SID:
                self.login()
            r = self.session.post(
                f"{self.url}/data.lua",
                data={"sid": self.sid, "page": name, "xhrId": "all", "lang": "de"},
                timeout=TIMEOUT,
            )
            r.raise_for_status()
            try:
                return r.json()["data"]
            except (ValueError, KeyError):
                self.sid = NO_SID
        raise LoginError(f"data.lua page {name} not readable after a fresh login")

    def action(self, service: str, action: str) -> dict:
        if self.tr064 is None:
            if self.user is None:
                self.login()
            self.tr064 = FritzConnection(
                address=self.host,
                user=self.user,
                password=self.password,
                timeout=TIMEOUT,
                use_cache=False,
            )
        try:
            return self.tr064.call_action(service, action)
        except (FritzConnectionException, requests.RequestException):
            # descriptions may be stale after a firmware update: rebuild next time
            self.tr064 = None
            raise


def esc(v: str) -> str:
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class Metrics:
    """Gauges in Prometheus text format, samples grouped by family."""

    def __init__(self) -> None:
        self.families: dict[str, tuple[str, list[str]]] = {}

    def add(self, name: str, help_: str, value: float, **labels: str) -> None:
        _, samples = self.families.setdefault(name, (help_, []))
        lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
        samples.append(f"{name}{{{lbl}}} {value}" if lbl else f"{name} {value}")

    def text(self) -> str:
        out = []
        for name, (help_, samples) in self.families.items():
            out += [f"# HELP {name} {help_}", f"# TYPE {name} gauge", *samples]
        return "\n".join(out) + "\n"


def number(v) -> float | None:
    m = re.match(r"\s*(-?[0-9.]+)", str(v))
    return float(m.group(1)) if m else None


# docInfo groups channels by DOCSIS version; the channel type is implied
CHANNEL_TYPES = {
    ("downstream", "docsis30"): "SC-QAM",
    ("downstream", "docsis31"): "OFDM",
    ("upstream", "docsis30"): "SC-QAM",
    ("upstream", "docsis31"): "OFDMA",
}


def channel_metrics(m: Metrics, direction: str, groups: dict) -> None:
    for version, channels in (groups or {}).items():
        ctype = CHANNEL_TYPES.get((direction, version), version)
        m.add(
            "fritzbox_docsis_channels",
            "Number of bonded channels",
            len(channels),
            direction=direction,
            channel_type=ctype,
        )
        for ch in channels:
            labels = {
                "direction": direction,
                "channel_id": str(ch.get("channelID", "")),
                "channel_type": ctype,
                # SC-QAM: "570.000", OFDM(A): "134.975 - 324.975"
                "frequency_mhz": str(ch.get("frequency", "")),
            }
            power = number(ch.get("powerLevel", ""))
            if power is not None:
                m.add(
                    "fritzbox_docsis_power_dbmv",
                    "Channel power level in dBmV",
                    power,
                    **labels,
                )
            # SC-QAM downstream reports MSE (negative dB), OFDM the MER;
            # both are the channel's SNR in dB, MSE with flipped sign.
            snr = number(ch.get("mer", ""))
            if snr is None and (mse := number(ch.get("mse", ""))) is not None:
                snr = -mse
            if snr is not None:
                m.add(
                    "fritzbox_docsis_snr_db",
                    "Downstream channel SNR in dB (MER, or -MSE for SC-QAM)",
                    snr,
                    **labels,
                )
            qam = number(re.sub(r"[^0-9]", "", str(ch.get("modulation", ""))) or "x")
            if qam is not None:
                m.add(
                    "fritzbox_docsis_modulation_qam",
                    "QAM order of the channel (64, 256, 4096, ...)",
                    qam,
                    **labels,
                )
            for key, name, help_ in (
                (
                    "corrErrors",
                    "fritzbox_docsis_corrected_errors",
                    "Codewords corrected by FEC since the modem synced",
                ),
                (
                    "nonCorrErrors",
                    "fritzbox_docsis_uncorrectable_errors",
                    "Codewords lost despite FEC since the modem synced",
                ),
            ):
                if key in ch:
                    m.add(name, help_, int(ch[key]), **labels)


def collect(box: FritzBox) -> str:
    m = Metrics()
    start = time.monotonic()
    try:
        doc = box.page("docInfo")
        info = box.action("DeviceInfo1", "GetInfo")
        link = box.action("WANCommonInterfaceConfig1", "GetCommonLinkProperties")
        conn = box.action("WANIPConnection1", "GetStatusInfo")
    except (requests.RequestException, FritzConnectionException, LoginError) as e:
        log.error("scrape failed: %s", e)
        m.add("fritzbox_up", "1 if the FRITZ!Box could be scraped", 0)
        m.add(
            "fritzbox_scrape_duration_seconds",
            "Time the scrape took",
            time.monotonic() - start,
        )
        return m.text()

    m.add("fritzbox_up", "1 if the FRITZ!Box could be scraped", 1)
    m.add(
        "fritzbox_scrape_duration_seconds",
        "Time the scrape took",
        time.monotonic() - start,
    )
    m.add(
        "fritzbox_info",
        "Model and FRITZ!OS version",
        1,
        model=info.get("NewModelName", ""),
        firmware=info.get("NewSoftwareVersion", ""),
    )
    m.add(
        "fritzbox_uptime_seconds",
        "Time since the FRITZ!Box booted",
        int(info.get("NewUpTime", 0)),
    )
    status = link.get("NewPhysicalLinkStatus", "")
    m.add(
        "fritzbox_docsis_online",
        "1 if the cable link is up",
        1 if status == "Up" else 0,
        status=status,
    )
    m.add(
        "fritzbox_docsis_ready",
        "1 if the cable information page reports the modem ready",
        1 if doc.get("readyState") == "ready" else 0,
    )
    connected = conn.get("NewConnectionStatus", "")
    m.add(
        "fritzbox_connected",
        "1 if the internet connection is established",
        1 if connected == "Connected" else 0,
        status=connected,
    )
    m.add(
        "fritzbox_connection_uptime_seconds",
        "Time since the internet connection was established",
        int(conn.get("NewUptime", 0)),
    )

    channel_metrics(m, "downstream", doc.get("channelDs"))
    channel_metrics(m, "upstream", doc.get("channelUs"))
    return m.text()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--host", default="192.168.178.1")
    p.add_argument("--password-file", required=True)
    p.add_argument("--listen", default="127.0.0.1:9764")
    p.add_argument("--once", action="store_true", help="print metrics once and exit")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    with open(args.password_file) as f:
        password = f.read().strip()
    box = FritzBox(args.host, password)

    if args.once:
        print(collect(box), end="")
        return

    # one shared session: concurrent scrapes would race on (re)login
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != "/metrics":
                self.send_error(404)
                return
            with lock:
                body = collect(box).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *a) -> None:
            pass

    host, _, port = args.listen.rpartition(":")
    server = ThreadingHTTPServer((host.strip("[]"), int(port)), Handler)
    log.info("listening on %s", args.listen)
    server.serve_forever()


if __name__ == "__main__":
    main()
