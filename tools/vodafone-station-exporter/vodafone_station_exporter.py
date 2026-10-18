"""Prometheus exporter for the ARRIS TG3442DE "Vodafone Station" cable router.

Logs into the web UI on every scrape (the router keeps one admin session and
times it out after 10 minutes idle, so a held session would lock the web UI
for humans), reads DOCSIS channel status and the status page, and logs out.
"""

import argparse
import hashlib
import json
import logging
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests
from cryptography.hazmat.primitives.ciphers.aead import AESCCM

log = logging.getLogger("vodafone-station-exporter")

TIMEOUT = 15


class LoginError(Exception):
    pass


def js_var(text: str, name: str) -> str | None:
    m = re.search(r"\b%s\s*=\s*'([^']*)'" % re.escape(name), text) or re.search(
        r'\b%s\s*=\s*"([^"]*)"' % re.escape(name), text
    )
    return m.group(1) if m else None


def js_json(text: str, name: str) -> list:
    m = re.search(r"\b%s\s*=\s*(\[.*?\]);" % re.escape(name), text, re.S)
    return json.loads(m.group(1)) if m else []


class Router:
    def __init__(self, url: str, user: str, password: str) -> None:
        self.url = url.rstrip("/")
        self.user = user
        self.password = password

    def fetch(self) -> dict:
        """One login, the data pages, logout."""
        s = requests.Session()
        index = s.get(self.url + "/", timeout=TIMEOUT).text
        iv_hex, salt_hex = js_var(index, "myIv"), js_var(index, "mySalt")
        session_id = js_var(index, "currentSessionId")
        if not (iv_hex and salt_hex and session_id):
            raise LoginError("login page lacks myIv/mySalt/currentSessionId")
        iv = bytes.fromhex(iv_hex)
        # sjcl.misc.pbkdf2 defaults: HMAC-SHA256, here 1000 rounds, 128 bit
        key = hashlib.pbkdf2_hmac(
            "sha256", self.password.encode(), bytes.fromhex(salt_hex), 1000, 16
        )
        ccm = AESCCM(key, tag_length=16)
        payload = json.dumps({"Password": self.password, "Nonce": session_id})
        resp = s.post(
            self.url + "/php/ajaxSet_Password.php",
            json={
                "EncryptData": ccm.encrypt(iv, payload.encode(), b"loginPassword").hex(),
                "Name": self.user,
                "AuthData": "loginPassword",
            },
            timeout=TIMEOUT,
        ).json()
        status = resp.get("p_status", "")
        # "Match" (user) / "AdminMatch" (admin), like the web UI checks
        if "Match" not in status:
            raise LoginError(f"login refused: {resp}")
        nonce = ccm.decrypt(iv, bytes.fromhex(resp["encryptData"]), b"nonce").decode()
        headers = {
            "csrfNonce": nonce,
            "Referer": self.url + "/",
            "X-Requested-With": "XMLHttpRequest",
        }
        try:
            session = s.post(
                self.url + "/php/ajaxSet_Session.php", headers=headers, timeout=TIMEOUT
            ).text
            if '"LoginStatus":"yes"' not in session:
                raise LoginError(f"session not started: {session.strip()}")
            pages = {}
            for page in ("status_docsis_data", "overview_data", "status_status_data"):
                r = s.get(f"{self.url}/php/{page}.php", headers=headers, timeout=TIMEOUT)
                r.raise_for_status()
                pages[page] = r.text
        finally:
            try:
                s.post(self.url + "/php/logout.php", headers=headers, timeout=TIMEOUT)
            except requests.RequestException as e:
                log.warning("logout failed: %s", e)
        return pages


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


def channel_metrics(m: Metrics, direction: str, channels: list) -> None:
    counts: dict[str, int] = {}
    for ch in channels:
        labels = {
            "direction": direction,
            "channel_id": str(ch.get("ChannelID", "")),
            "channel_type": ch.get("ChannelType", ""),
            "frequency_mhz": str(ch.get("Frequency", "")),
        }
        counts[labels["channel_type"]] = counts.get(labels["channel_type"], 0) + 1
        # "6.4/66.4": dBmV/dBµV
        power = number(str(ch.get("PowerLevel", "")).split("/")[0])
        if power is not None:
            m.add(
                "vodafone_station_docsis_power_dbmv",
                "Channel power level in dBmV",
                power,
                **labels,
            )
        snr = number(ch.get("SNRLevel", ""))
        if snr is not None:
            m.add(
                "vodafone_station_docsis_snr_db",
                "Downstream channel SNR (MER) in dB",
                snr,
                **labels,
            )
        qam = number(re.sub(r"[^0-9]", "", str(ch.get("Modulation", ""))) or "x")
        if qam is not None:
            m.add(
                "vodafone_station_docsis_modulation_qam",
                "QAM order of the channel (64, 256, 4096, ...)",
                qam,
                **labels,
            )
        m.add(
            "vodafone_station_docsis_locked",
            "1 if the channel is locked (OFDMA upstream: OPERATE)",
            1 if ch.get("LockStatus") in ("Locked", "OPERATE") else 0,
            **labels,
        )
    for ctype, n in counts.items():
        m.add(
            "vodafone_station_docsis_channels",
            "Number of bonded channels",
            n,
            direction=direction,
            channel_type=ctype,
        )


def collect(router: Router) -> str:
    m = Metrics()
    start = time.monotonic()
    try:
        pages = router.fetch()
    except (requests.RequestException, LoginError, ValueError, KeyError) as e:
        log.error("scrape failed: %s", e)
        m.add("vodafone_station_up", "1 if the router could be scraped", 0)
        m.add(
            "vodafone_station_scrape_duration_seconds",
            "Time the router scrape took",
            time.monotonic() - start,
        )
        return m.text()

    docsis = pages["status_docsis_data"]
    overview = pages["overview_data"]
    status = pages["status_status_data"]

    m.add("vodafone_station_up", "1 if the router could be scraped", 1)
    m.add(
        "vodafone_station_scrape_duration_seconds",
        "Time the router scrape took",
        time.monotonic() - start,
    )
    m.add(
        "vodafone_station_info",
        "Router firmware and hardware",
        1,
        firmware=js_var(status, "js_FWVersion") or "",
        hardware=js_var(status, "js_HWTypeVersion") or "",
    )
    conn = js_var(overview, "_ga.modemConnectionStatus") or ""
    m.add(
        "vodafone_station_docsis_online",
        "1 if the cable modem reports DOCSIS Online",
        1 if conn == "DOCSIS Online" else 0,
        status=conn,
    )
    m.add(
        "vodafone_station_cm_operational",
        "1 if the cable modem reports itself operational",
        1 if js_var(overview, "js_isCmOperational") == "1" else 0,
    )
    # "29,17,53": days,hours,minutes
    uptime = js_var(status, "js_UptimeSinceReboot") or ""
    parts = [int(p) for p in re.findall(r"\d+", uptime)]
    if len(parts) == 3:
        d, h, mi = parts
        m.add(
            "vodafone_station_uptime_seconds",
            "Time since the router booted (minute resolution)",
            ((d * 24 + h) * 60 + mi) * 60,
        )
    hosts = js_var(overview, "js_hostNums")
    if hosts is not None and hosts.isdigit():
        m.add("vodafone_station_hosts", "Hosts attached to the router", int(hosts))

    channel_metrics(m, "downstream", js_json(docsis, "json_dsData"))
    channel_metrics(m, "upstream", js_json(docsis, "json_usData"))
    return m.text()


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--router", default="http://192.168.0.1")
    p.add_argument("--user", default="admin")
    p.add_argument("--password-file", required=True)
    p.add_argument("--listen", default="127.0.0.1:9764")
    p.add_argument("--once", action="store_true", help="print metrics once and exit")
    args = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    with open(args.password_file) as f:
        password = f.read().strip()
    router = Router(args.router, args.user, password)

    if args.once:
        print(collect(router), end="")
        return

    # The router has one session; concurrent scrapes would log each other out.
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            if self.path != "/metrics":
                self.send_error(404)
                return
            with lock:
                body = collect(router).encode()
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
