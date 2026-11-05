"""sunray: stream a host's desktop to Moonlight, with ssh as auth and transport.

usage: sunray [-o key=value]... <host> [app]

Everything goes through one ssh connection: Sunshine's TCP ports as ssh
forwards, its UDP streams as frames over the ssh session's stdio. Each
host gets its own loopback address, because Moonlight finds its stored
host entries by address.
"""

import argparse
import asyncio
import base64
import hashlib
import json
import secrets
import shlex
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import server


def loopback(host):
    h = hashlib.sha256(host.encode()).digest()
    return f"127.{h[0]}.{h[1]}.{h[2] % 254 + 1}"


def api(addr, port, auth, method="GET", body=None):
    req = urllib.request.Request(
        f"https://{addr}:{port + 1}/api/pin",
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"},
    )
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, context=ctx) as r:
        return json.load(r)


async def pair(addr, port, auth):
    """Pair Moonlight with the host; ssh already proved who we are."""
    target = f"{addr}:{port}"
    listed = await asyncio.create_subprocess_exec(
        "moonlight", "list", target,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if await listed.wait() == 0:
        return
    pin = f"{secrets.randbelow(10000):04d}"
    moonlight = await asyncio.create_subprocess_exec(
        "moonlight", "pair", target, "--pin", pin,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        pending = []
        while not pending:
            if moonlight.returncode is not None:
                raise SystemExit("sunray: moonlight pair exited before pairing")
            await asyncio.sleep(0.5)
            pending = (await asyncio.to_thread(api, addr, port, auth))["pairings"]
        pid = pending[0]["id"]
        result = await asyncio.to_thread(
            api, addr, port, auth, "POST",
            {"pairing_id": pid, "pin": pin, "name": socket.gethostname()},
        )
        if not result.get("status"):
            await asyncio.to_thread(api, addr, port, auth, "DELETE", {"pairing_id": pid})
            raise SystemExit("sunray: pairing failed")
    finally:
        if moonlight.returncode is None:
            moonlight.terminate()
        await moonlight.wait()


class Udp(asyncio.DatagramProtocol):
    def __init__(self, offset, writer):
        self.offset = offset
        self.writer = writer
        self.peer = None

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.peer = addr
        self.writer.write(server.frame(self.offset, data))

    def send(self, data):
        if self.peer:
            self.transport.sendto(data, self.peer)


async def main():
    p = argparse.ArgumentParser(prog="sunray")
    p.add_argument("-o", dest="overrides", action="append", default=[],
                   metavar="key=value", help="Sunshine config override on the host")
    p.add_argument("host", help="anything ssh accepts")
    p.add_argument("app", nargs="?", default="Desktop")
    args = p.parse_args()

    code = base64.b64encode(Path(server.__file__).read_bytes()).decode()
    boot = f"import base64;exec(base64.b64decode('{code}'))"
    addr = loopback(args.host)
    bases = ",".join(map(str, server.free_bases(addr)))
    with tempfile.TemporaryDirectory() as tmp:
        ctl = f"{tmp}/ctl"
        ssh = await asyncio.create_subprocess_exec(
            "ssh", "-M", "-S", ctl, args.host,
            shlex.join(["python3", "-c", boot, bases, *args.overrides]),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        )
        try:
            line = await ssh.stdout.readline()
            if not line:
                raise SystemExit("sunray: host side exited")
            hello = json.loads(line)
            port = hello["port"]
            auth = base64.b64encode(f"{hello['user']}:{hello['password']}".encode()).decode()

            forwards = []
            for o in server.TCP_OFFSETS:
                forwards += ["-L", f"{addr}:{port + o}:127.0.0.1:{port + o}"]
            if subprocess.run(["ssh", "-S", ctl, "-O", "forward", *forwards, args.host],
                              stderr=subprocess.DEVNULL).returncode:
                raise SystemExit("sunray: ssh port forwarding failed")

            loop = asyncio.get_running_loop()
            udp = {}
            for o in server.UDP_OFFSETS:
                _, udp[o] = await loop.create_datagram_endpoint(
                    lambda o=o: Udp(o, ssh.stdin), local_addr=(addr, port + o)
                )
            relay = asyncio.create_task(
                server.read_frames(ssh.stdout, lambda o, data: udp[o].send(data))
            )

            await pair(addr, port, auth)
            moonlight = await asyncio.create_subprocess_exec(
                "moonlight", "stream", f"{addr}:{port}", args.app
            )
            await moonlight.wait()
            relay.cancel()
        finally:
            ssh.stdin.close()
            await ssh.wait()


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
