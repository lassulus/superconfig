#!/usr/bin/env python3
"""Control the user's everyday Firefox from MCP clients without WebDriver.

Two roles:

host   Native messaging host, spawned by Firefox when the Browser MCP
       extension connects. Relays newline-delimited JSON requests from a
       unix socket to the extension and routes replies back. Any number of
       clients can talk to it at once.
serve  stdio MCP server. Connects to the host's socket per tool call, so it
       keeps working across Firefox restarts without restarting itself.

Neither role touches Marionette or remote debugging, so the browser never
reports navigator.webdriver = true and captcha providers see a normal browser.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import itertools
import json
import os
import select
import socket
import struct
import sys
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP, Image

PROTOCOL_LIMIT = 64 * 1024 * 1024  # screenshots can be several MB


def socket_path() -> Path:
    """Socket shared by host and server; both run as the same user."""
    if override := os.environ.get("BROWSER_MCP_SOCKET"):
        return Path(override)
    if runtime := os.environ.get("XDG_RUNTIME_DIR"):
        return Path(runtime) / "browser-mcp.sock"
    return Path.home() / ".cache" / "browser-mcp" / "browser-mcp.sock"


# ── host ────────────────────────────────────────────────────────────────


def read_exact(fd: int, n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        chunk = os.read(fd, n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_native(fd: int) -> dict[str, Any] | None:
    header = read_exact(fd, 4)
    if header is None:
        return None
    (length,) = struct.unpack("=I", header)
    body = read_exact(fd, length)
    if body is None:
        return None
    msg: dict[str, Any] = json.loads(body)
    return msg


def write_native(msg: dict[str, Any]) -> None:
    data = json.dumps(msg).encode()
    sys.stdout.buffer.write(struct.pack("=I", len(data)) + data)
    sys.stdout.buffer.flush()


def bind_socket(path: Path) -> socket.socket:
    """Bind the relay socket, taking it over from a previous host.

    The latest Firefox to start (e.g. after a restart while the old host
    lingers) owns the socket.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with contextlib.suppress(FileNotFoundError):
        path.unlink()
    old_umask = os.umask(0o177)
    try:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(path))
    finally:
        os.umask(old_umask)
    listener.listen()
    listener.setblocking(False)
    return listener


class Client:
    def __init__(self, conn: socket.socket) -> None:
        self.conn = conn
        self.buf = b""


def run_host() -> None:
    path = socket_path()
    listener = bind_socket(path)
    inode = path.stat().st_ino
    stdin_fd = sys.stdin.buffer.fileno()
    clients: dict[int, Client] = {}
    # extension request id -> (client fd, client's own request id)
    pending: dict[int, tuple[int, Any]] = {}
    ids = itertools.count(1)

    def drop(fd: int) -> None:
        client = clients.pop(fd)
        client.conn.close()
        for rid in [r for r, (cfd, _) in pending.items() if cfd == fd]:
            del pending[rid]

    def reply(fd: int, msg: dict[str, Any]) -> None:
        client = clients.get(fd)
        if client is None:
            return
        client.conn.setblocking(True)
        try:
            client.conn.sendall(json.dumps(msg).encode() + b"\n")
        except OSError:
            drop(fd)
        else:
            client.conn.setblocking(False)

    try:
        while True:
            readable, _, _ = select.select(
                [stdin_fd, listener.fileno(), *clients], [], []
            )
            for fd in readable:
                if fd == stdin_fd:
                    msg = read_native(stdin_fd)
                    if msg is None:
                        return  # Firefox closed the port
                    target = pending.pop(msg.get("id", -1), None)
                    if target is not None:
                        cfd, cid = target
                        reply(cfd, {**msg, "id": cid})
                elif fd == listener.fileno():
                    conn, _ = listener.accept()
                    conn.setblocking(False)
                    clients[conn.fileno()] = Client(conn)
                else:
                    client = clients[fd]
                    try:
                        chunk = client.conn.recv(65536)
                    except BlockingIOError:
                        continue
                    except OSError:
                        chunk = b""
                    if not chunk:
                        drop(fd)
                        continue
                    client.buf += chunk
                    while b"\n" in client.buf:
                        line, client.buf = client.buf.split(b"\n", 1)
                        try:
                            req = json.loads(line)
                        except json.JSONDecodeError as e:
                            reply(fd, {"id": None, "error": f"bad request: {e}"})
                            continue
                        rid = next(ids)
                        pending[rid] = (fd, req.get("id"))
                        write_native(
                            {
                                "id": rid,
                                "method": req.get("method"),
                                "params": req.get("params", {}),
                            }
                        )
    finally:
        listener.close()
        # Only remove the socket if a newer host has not taken it over.
        with contextlib.suppress(FileNotFoundError):
            if path.stat().st_ino == inode:
                path.unlink()


# ── MCP server ──────────────────────────────────────────────────────────


class BrowserError(Exception):
    pass


async def call(method: str, params: dict[str, Any] | None = None) -> Any:
    try:
        reader, writer = await asyncio.open_unix_connection(
            str(socket_path()), limit=PROTOCOL_LIMIT
        )
    except (FileNotFoundError, ConnectionRefusedError) as e:
        raise BrowserError(
            "Firefox is not connected: the Browser MCP extension is not "
            "installed/enabled or Firefox is not running"
        ) from e
    try:
        req = {"id": 1, "method": method, "params": params or {}}
        writer.write(json.dumps(req).encode() + b"\n")
        await writer.drain()
        line = await reader.readline()
    finally:
        writer.close()
    if not line:
        raise BrowserError("Firefox disconnected before replying")
    resp: dict[str, Any] = json.loads(line)
    if "error" in resp:
        raise BrowserError(resp["error"])
    return resp.get("result")


def as_text(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, indent=1)


def run_server() -> None:
    mcp = FastMCP(
        "browser",
        instructions=(
            "Controls the user's own running Firefox through an extension "
            "(no WebDriver, so sites don't flag it as automated). Tabs are "
            "addressed by tab_id from list_tabs/open_tab. Open new tabs in "
            "the background unless the user should see them. For "
            "interaction, take a snapshot to get element refs, then click, "
            "fill or press_key by ref. Refs are invalid after the page "
            "navigates. Events are synthetic: captchas and other checks that "
            "require a real user gesture must be solved by the user."
        ),
    )

    @mcp.tool()
    async def list_tabs() -> str:
        """List all open tabs: id, windowId, active, status, title, url."""
        return as_text(await call("list_tabs"))

    @mcp.tool()
    async def open_tab(url: str, active: bool = False, timeout_ms: int = 15000) -> str:
        """Open url in a new tab (in the background unless active) and wait for it to load."""
        return as_text(
            await call(
                "open_tab", {"url": url, "active": active, "timeout_ms": timeout_ms}
            )
        )

    @mcp.tool()
    async def navigate(tab_id: int, url: str, timeout_ms: int = 15000) -> str:
        """Load url in an existing tab and wait for it to load."""
        return as_text(
            await call(
                "navigate", {"tab_id": tab_id, "url": url, "timeout_ms": timeout_ms}
            )
        )

    @mcp.tool()
    async def navigate_history(
        tab_id: int, direction: str, timeout_ms: int = 15000
    ) -> str:
        """Go 'back' or 'forward' in a tab's history and wait for the load."""
        return as_text(
            await call(
                "history",
                {"tab_id": tab_id, "direction": direction, "timeout_ms": timeout_ms},
            )
        )

    @mcp.tool()
    async def reload(tab_id: int, timeout_ms: int = 15000) -> str:
        """Reload a tab and wait for it to load."""
        return as_text(
            await call("reload", {"tab_id": tab_id, "timeout_ms": timeout_ms})
        )

    @mcp.tool()
    async def activate_tab(tab_id: int) -> str:
        """Bring a tab to the front and focus its window."""
        return as_text(await call("activate_tab", {"tab_id": tab_id}))

    @mcp.tool()
    async def close_tab(tab_id: int) -> str:
        """Close a tab."""
        return as_text(await call("close_tab", {"tab_id": tab_id}))

    @mcp.tool()
    async def snapshot(tab_id: int, max_elements: int = 300) -> str:
        """List the visible interactive elements and headings of a tab with refs.

        Lines look like `[12] button "Sign in"`; pass the number as ref to
        click, fill or press_key. Covers open shadow roots, not iframes.
        """
        return as_text(
            await call("snapshot", {"tab_id": tab_id, "max_elements": max_elements})
        )

    @mcp.tool()
    async def get_text(tab_id: int, max_length: int = 20000) -> str:
        """Visible text of a tab (document.body.innerText), truncated to max_length."""
        return as_text(await call("text", {"tab_id": tab_id, "max_length": max_length}))

    @mcp.tool()
    async def click(tab_id: int, ref: int) -> str:
        """Click an element from the latest snapshot."""
        return as_text(await call("click", {"tab_id": tab_id, "ref": ref}))

    @mcp.tool()
    async def fill(tab_id: int, ref: int, value: str) -> str:
        """Replace the value of an input/textarea/contenteditable, pick a select
        option (by value or text), or set a checkbox/radio ("true"/"false")."""
        return as_text(
            await call("fill", {"tab_id": tab_id, "ref": ref, "value": value})
        )

    @mcp.tool()
    async def press_key(tab_id: int, key: str, ref: int | None = None) -> str:
        """Dispatch a key (DOM key name, e.g. "Enter", "Escape", "a") to ref or
        the focused element. Enter in a form input submits the form."""
        return as_text(
            await call("press_key", {"tab_id": tab_id, "key": key, "ref": ref})
        )

    @mcp.tool()
    async def evaluate(tab_id: int, code: str) -> str:
        """Run JavaScript in a tab and return the JSON of its result.

        code is the body of an async function: use `return`. It runs in the
        extension's isolated content-script world with full DOM access;
        page-defined globals are reachable via window.wrappedJSObject.
        """
        return as_text(await call("evaluate", {"tab_id": tab_id, "code": code}))

    @mcp.tool()
    async def screenshot(tab_id: int) -> Image:
        """PNG of a tab's visible viewport; works for background tabs too."""
        data_url = await call("screenshot", {"tab_id": tab_id})
        _, _, b64 = str(data_url).partition(",")
        return Image(data=base64.b64decode(b64), format="png")

    mcp.run()


def main() -> None:
    # Firefox starts the host with the manifest path and extension id as
    # arguments; the MCP server is started without arguments.
    if len(sys.argv) > 1 and sys.argv[1] == "host":
        run_host()
    else:
        run_server()


if __name__ == "__main__":
    main()
