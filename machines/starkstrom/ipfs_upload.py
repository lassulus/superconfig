"""Anonymous tarball -> IPFS pinning endpoint for ipfs.lassul.us.

POST a tar archive (optionally gzip/xz/bzip2 compressed) as the raw request
body. It is extracted to a scratch dir, added to IPFS recursively (copied into
the blockstore -- NOT --nocopy), and recursively pinned. Each upload's pin is a
GC root, so the content survives `ipfs repo gc` until an operator unpins it.
The root CID is returned as JSON; the scratch files are then deleted.

The node announces only what is in its MFS (Provide.Strategy = "mfs"), so
each upload is also linked into MFS at /announced/<cid>, which lets public
gateways find it. `POST /?announce=0` skips that: the content is pinned and
served by this host's own gateway, but never announced to the DHT/IPNI.

There is no mutable name: reads are immutable at /ipfs/<cid>/. Re-upload to
"update" -- you get a new CID back.
"""
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import tarfile
import tempfile
import time
import urllib.parse

IPFS_BIN = os.environ.get("IPFS_BIN", "ipfs")
IPFS_API = os.environ.get("IPFS_API", "/ip4/127.0.0.1/tcp/5001")
STAGING = os.environ.get("STAGING", "/var/lib/ipfs/incoming")
ROOTS_FILE = os.environ.get("ROOTS_FILE", "/var/lib/ipfs/gc-roots")
GATEWAY_BASE = os.environ.get("GATEWAY_BASE", "https://ipfs.lassul.us")
BIND = os.environ.get("BIND", "127.0.0.1")
PORT = int(os.environ.get("PORT", "8090"))
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(8 * 1024**3)))
MAX_EXTRACT_BYTES = int(os.environ.get("MAX_EXTRACT_BYTES", str(20 * 1024**3)))
MAX_FILES = int(os.environ.get("MAX_FILES", "200000"))
# reject uploads once the IPFS filesystem has less than this much free space
MIN_FREE_BYTES = int(os.environ.get("MIN_FREE_BYTES", str(300 * 1024**3)))
DISK_PATH = os.environ.get("DISK_PATH", "/var/lib/ipfs")

_HOST = GATEWAY_BASE.split("://", 1)[-1]
HELP = (
    "%s - anonymous IPFS pinning\n\n"
    "Upload a directory; the response is its CID. Read it at /ipfs/<cid>/.\n\n"
    "  tar -C mydir -c . | curl --data-binary @- %s/\n"
    "  # compressed tars work too (tar -cz / -cJ / -cj); do NOT set Content-Encoding.\n\n"
    "  # ?announce=0: pinned and served here, but not announced to public gateways\n"
    "  curl --data-binary @site.tar '%s/?announce=0'\n\n"
    "Re-upload to 'update' (new CID). Content stays pinned until an operator\n"
    "prunes it (ipfs-roots rm <cid> && ipfs-gc).\n"
).encode() % (_HOST.encode(), GATEWAY_BASE.encode(), GATEWAY_BASE.encode())


def _add_to_ipfs(path):
    out = subprocess.run(
        [IPFS_BIN, "--api", IPFS_API, "add", "-Q", "-r",
         "--cid-version=1", "--pin=true", path],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip().splitlines()[-1]


def _announce(cid):
    # MFS is all the node announces; a CID already linked there (same
    # content uploaded twice) is fine
    out = subprocess.run(
        [IPFS_BIN, "--api", IPFS_API, "files", "cp", "--parents",
         "/ipfs/%s" % cid, "/announced/%s" % cid],
        capture_output=True, text=True,
    )
    if out.returncode != 0 and "already" not in out.stderr:
        raise subprocess.CalledProcessError(out.returncode, out.args, out.stdout, out.stderr)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ipfs-upload/1"

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(HELP)))
        self.end_headers()
        self.wfile.write(HELP)

    def do_POST(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        announce = query.get("announce", ["1"])[-1] != "0"
        try:
            free = shutil.disk_usage(DISK_PATH).free
        except OSError:
            free = None
        if free is not None and free < MIN_FREE_BYTES:
            return self._json(507, {
                "error": "not enough space left",
                "free_bytes": free,
                "min_free_bytes": MIN_FREE_BYTES,
            })
        os.makedirs(STAGING, exist_ok=True)
        tmp = tempfile.NamedTemporaryFile(dir=STAGING, suffix=".tar", delete=False)
        workdir = None
        try:
            if not self._recv_body(tmp):
                return
            tmp.close()
            workdir = tempfile.mkdtemp(dir=STAGING)
            if not self._extract(tmp.name, workdir):
                return
            try:
                cid = _add_to_ipfs(workdir)
            except subprocess.CalledProcessError as e:
                return self._json(500, {
                    "error": "ipfs add failed",
                    "detail": (e.stderr or "").strip()[-500:],
                })
            if announce:
                try:
                    _announce(cid)
                except subprocess.CalledProcessError as e:
                    return self._json(500, {
                        "error": "pinned, but linking into MFS (announce) failed",
                        "cid": cid,
                        "detail": (e.stderr or "").strip()[-500:],
                    })
            try:
                with open(ROOTS_FILE, "a") as f:
                    f.write("%s\t%s\t%s\n" % (
                        cid,
                        time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                        self.client_address[0],
                    ))
            except OSError:
                pass
            self._json(200, {"cid": cid, "url": "%s/ipfs/%s/" % (GATEWAY_BASE, cid)})
        finally:
            if workdir:
                shutil.rmtree(workdir, ignore_errors=True)
            try:
                os.unlink(tmp.name)
            except OSError:
                pass

    def _recv_body(self, tmp):
        length = self.headers.get("Content-Length")
        total = 0
        if length is not None:
            try:
                remaining = int(length)
            except ValueError:
                self._json(400, {"error": "bad Content-Length"})
                return False
            if remaining > MAX_BYTES:
                self._json(413, {"error": "archive too large"})
                return False
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 16, remaining))
                if not chunk:
                    break
                tmp.write(chunk)
                total += len(chunk)
                remaining -= len(chunk)
        else:
            while True:
                chunk = self.rfile.read(1 << 16)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    self._json(413, {"error": "archive too large"})
                    return False
                tmp.write(chunk)
        if total == 0:
            self._json(400, {"error": "empty body; POST a tar archive"})
            return False
        return True

    def _extract(self, tar_path, workdir):
        try:
            with tarfile.open(tar_path, "r:*") as tar:
                nfiles = 0
                nbytes = 0
                for m in tar.getmembers():
                    if m.isdir():
                        continue
                    nfiles += 1
                    nbytes += m.size
                if nfiles > MAX_FILES:
                    self._json(413, {"error": "too many files"})
                    return False
                if nbytes > MAX_EXTRACT_BYTES:
                    self._json(413, {"error": "extracted size too large"})
                    return False
                # Python 3.12 'data' filter: strips setuid/dev nodes and
                # rejects absolute paths, .. traversal and links escaping dest.
                tar.extractall(workdir, filter="data")
        except (tarfile.TarError, OSError, ValueError) as e:
            self._json(400, {"error": "bad archive", "detail": str(e)[:500]})
            return False
        return True


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    os.makedirs(STAGING, exist_ok=True)
    httpd = Server((BIND, PORT), Handler)
    print("ipfs-upload listening on %s:%d" % (BIND, PORT), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
