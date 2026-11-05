"""sunray host side: runs one private Sunshine and relays its UDP over stdio.

Started by the sunray client as
`python3 -c <this file> <base,base,...> [key=value ...]` over ssh: the port
bases free on the client, then Sunshine config overrides.
Stdout carries one JSON line, then frames; stdin carries frames.
"""

import asyncio
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
from pathlib import Path

TCP_OFFSETS = (-5, 0, 1, 21)
UDP_OFFSETS = (9, 10, 11, 13)
FRAME = struct.Struct("!BH")


def frame(offset, data):
    return FRAME.pack(offset, len(data)) + data


async def read_frames(reader, deliver):
    """Call deliver(offset, payload) for every frame until EOF."""
    while True:
        try:
            header = await reader.readexactly(FRAME.size)
        except asyncio.IncompleteReadError:
            return
        offset, size = FRAME.unpack(header)
        deliver(offset, await reader.readexactly(size))


async def stdio():
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer
    )
    transport, protocol = await loop.connect_write_pipe(
        asyncio.streams.FlowControlMixin, sys.stdout.buffer
    )
    writer = asyncio.StreamWriter(transport, protocol, reader, loop)
    return reader, writer


def free(port, kind, addr="127.0.0.1"):
    with socket.socket(socket.AF_INET, kind) as s:
        # like Sunshine's own listeners: TIME_WAIT leftovers don't count
        if kind == socket.SOCK_STREAM:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((addr, port))
        except OSError:
            return False
    return True


def free_bases(addr="127.0.0.1"):
    """Port bases whose Sunshine ports are all free on addr."""
    return [
        base
        for base in range(47989, 65514, 100)
        if all(free(base + o, socket.SOCK_STREAM, addr) for o in TCP_OFFSETS)
        and all(free(base + o, socket.SOCK_DGRAM, addr) for o in UDP_OFFSETS)
    ]


def pick_base(candidates):
    """First base free here among those the client has free locally."""
    here = set(free_bases())
    for base in candidates:
        if base in here:
            return base
    raise SystemExit("sunray: no Sunshine port range free on both client and host")


def session_env():
    """Our env plus the graphical session's display variables."""
    env = dict(os.environ)
    out = subprocess.run(
        ["systemctl", "--user", "show-environment"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        key, _, value = line.partition("=")
        if key in ("WAYLAND_DISPLAY", "DISPLAY") and key not in env:
            env[key] = value
    return env


async def wait_listening(port, proc, log):
    while proc.poll() is None:
        try:
            socket.create_connection(("127.0.0.1", port)).close()
            return
        except OSError:
            await asyncio.sleep(0.2)
    raise SystemExit("sunray: sunshine exited:\n" + log.read_text()[-2000:])


class Udp(asyncio.DatagramProtocol):
    def __init__(self, offset, writer):
        self.offset = offset
        self.writer = writer

    def datagram_received(self, data, addr):
        self.writer.write(frame(self.offset, data))


async def main():
    state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "sunray"
    state.mkdir(parents=True, exist_ok=True)
    apps = state / "apps.json"
    if not apps.exists():
        apps.write_text(json.dumps({"env": {}, "apps": [{"name": "Desktop"}]}))

    bases, *overrides = sys.argv[1:]
    base = pick_base(int(b) for b in bases.split(","))
    conf = state / f"sunshine-{base}.conf"
    creds = state / f"creds-{base}.json"
    log = state / f"sunshine-{base}.log"
    conf.write_text(
        "".join(
            f"{k} = {v}\n"
            for k, v in {
                "port": base,
                "bind_address": "127.0.0.1",
                # sway screencopy; "auto" picks the portal, whose source
                # picker dialog nobody can answer before the stream exists
                "capture": "wlr",
                "origin_web_ui_allowed": "pc",
                "file_apps": apps,
                "file_state": state / "sunshine_state.json",
                "credentials_file": creds,
                "pkey": state / "cakey.pem",
                "cert": state / "cacert.pem",
                "log_path": log,
            }.items()
        )
    )
    password = secrets.token_hex(16)
    env = session_env()
    subprocess.run(
        ["sunshine", conf, "--creds", "sunray", password],
        env=env,
        stdout=subprocess.DEVNULL,
        check=True,
    )
    proc = subprocess.Popen(
        ["sunshine", conf, *overrides],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        await wait_listening(base + 1, proc, log)
        reader, writer = await stdio()
        writer.write(
            (json.dumps({"port": base, "user": "sunray", "password": password}) + "\n").encode()
        )
        loop = asyncio.get_running_loop()
        socks = {}
        for offset in UDP_OFFSETS:
            socks[offset], _ = await loop.create_datagram_endpoint(
                lambda o=offset: Udp(o, writer), remote_addr=("127.0.0.1", base + offset)
            )
        await read_frames(reader, lambda o, data: socks[o].sendto(data))
    finally:
        proc.terminate()
        proc.wait()
        creds.unlink(missing_ok=True)
        conf.unlink(missing_ok=True)


if __name__ == "__main__":
    asyncio.run(main())
