"""Native messaging host of passkey-firefox: passkeys and logins of the passage store.

Requests (Firefox native messaging: 4-byte length + JSON, both ways):
  {"op": "list", "rp": R}             -> {"names": ["passkey", "passkey-0a1b2c3d", ...]}
  {"op": "logins", "rp": R}           -> {"names": ["user", "pass", "otp", "bob/pass", ...]}
  {"op": "read", "rp": R, "name": N}  -> {"data": base64}   (pass show www/R/N)
  {"op": "otp", "rp": R, "name": N}   -> {"data": base64}   (pass otp www/R/N)
  {"op": "write", "rp": R, "id": H, "data": base64}
                                      -> {"name": N}        (pass insert -m www/R/N)
  errors                              -> {"error": text}

A new passkey is www/R/passkey, or www/R/passkey-H (H: the first 8 lowercase hex chars of its
credential id) when that exists; an existing file is never overwritten. A login is a folder
with pass.age (and optionally user.age, otp.age): www/R itself or one subfolder per further
account, as the Android app reads them. Every read is one `pass show` (or `pass otp`) and so
one approval of the hardware key; nothing is cached. otp.age is only read through `pass otp`.
"""

import base64
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any

RP = re.compile(r"[a-z0-9-]+(\.[a-z0-9-]+)*")
NAME = re.compile(r"passkey(-[^/]+)?")
ID8 = re.compile(r"[0-9a-f]{8}")
STORE = Path(os.environ.get("PASSAGE_DIR") or Path.home() / ".passage" / "store")
# pass would otherwise decrypt with the cached bulk key, without asking the hardware key
ENV = {k: v for k, v in os.environ.items() if k != "PASS_BULK_KEY_FILE"}


def names(rp: str) -> list[str]:
    try:
        files = os.listdir(STORE / "www" / rp)
    except FileNotFoundError:
        return []
    return sorted(
        f[:-4] for f in files if f.endswith(".age") and NAME.fullmatch(f[:-4])
    )


def logins(rp: str) -> list[str]:
    site = STORE / "www" / rp
    if not site.is_dir():
        return []
    subfolders = sorted(d for d in site.iterdir() if d.is_dir() and d.name[0] != ".")
    return [
        (f"{d.name}/" if d != site else "") + field
        for d in [site, *subfolders]
        if (d / "pass.age").is_file()
        for field in ("user", "pass", "otp")
        if (d / f"{field}.age").is_file()
    ]


def run(op: str, rp: str, name: str) -> dict[str, Any]:
    out = subprocess.run(
        ["pass", op, f"www/{rp}/{name}"],
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        env=ENV,
    )
    if out.returncode != 0:
        return {"error": f"pass {op} failed"}
    return {"data": base64.b64encode(out.stdout).decode()}


def handle(req: dict[str, Any]) -> dict[str, Any]:
    rp = req.get("rp")
    if not isinstance(rp, str) or not RP.fullmatch(rp):
        return {"error": "bad rp id"}
    if req.get("op") == "list":
        return {"names": names(rp)}
    if req.get("op") == "logins":
        return {"names": logins(rp)}
    name = req.get("name")
    if req.get("op") == "read":
        readable = names(rp) + [n for n in logins(rp) if not n.endswith("otp")]
        if name not in readable:
            return {"error": "no such entry"}
        return run("show", rp, name)
    if req.get("op") == "otp":
        if name not in logins(rp) or not name.endswith("otp"):
            return {"error": "no such entry"}
        return run("otp", rp, name)
    if req.get("op") == "write":
        id8 = req.get("id")
        if not isinstance(id8, str) or not ID8.fullmatch(id8):
            return {"error": "bad credential id"}
        existing = names(rp)
        name = "passkey" if "passkey" not in existing else f"passkey-{id8}"
        if name in existing:
            return {"error": f"www/{rp}/{name} exists"}
        out = subprocess.run(
            ["pass", "insert", "-m", "-f", f"www/{rp}/{name}"],
            input=base64.b64decode(req.get("data", ""), validate=True),
            check=False,
            stdout=subprocess.DEVNULL,
            env=ENV,
        )
        return (
            {"name": name} if out.returncode == 0 else {"error": "pass insert failed"}
        )
    return {"error": "bad op"}


def main() -> None:
    while header := sys.stdin.buffer.read(4):
        (length,) = struct.unpack("=I", header)
        try:
            reply = handle(json.loads(sys.stdin.buffer.read(length)))
        except (
            ValueError,
            TypeError,
            AttributeError,
        ) as e:  # malformed request: answer, keep serving
            reply = {"error": str(e)}
        body = json.dumps(reply).encode()
        sys.stdout.buffer.write(struct.pack("=I", len(body)) + body)
        sys.stdout.buffer.flush()


if __name__ == "__main__":
    main()
