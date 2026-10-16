#!/usr/bin/env python3
"""Helper for .github/exp/lazy-fuse.sh: a lazy lower store for
nix's local-overlay store, backed by nix binary caches.

  closure OUT DRV...   collect what building DRVs needs from the caches (the
                       wanted outputs of their input derivations plus their
                       own outputs, and the closure of all that) by fetching
                       only narinfos. Writes OUT/paths.json (per path: cache,
                       NAR url, compression, hash) and OUT/db.dump, the input
                       for `nix-store --load-db` into the lower store.
  mount OUT MNT        FUSE-mount the paths of OUT/paths.json at MNT as a
                       read-only store dir. stat/readdir/readlink come from
                       the cache's .ls listing; the first open() of a file in
                       a store path fetches, verifies (NarHash) and unpacks
                       that path's NAR. Stats go to OUT/stats.json.
"""

import collections
import concurrent.futures
import errno
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

STORE = "/nix/store/"
CACHES = os.environ.get(
    "LAZY_STORE_CACHES", "https://cache.nixos.org https://cache.lassul.us"
).split()
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
# nix's LocalStore constructor creates <real>/.links even with read-only=true
# (nix 2.35 local-store.cc), which fails with EROFS on this mount unless the
# directory already exists: serve it as an empty dir.
LINKS = ".links"


def nix32(b):
    n = (len(b) * 8 - 1) // 5 + 1
    out = []
    for i in range(n - 1, -1, -1):
        bit = i * 5
        j, k = divmod(bit, 8)
        c = b[j] >> k
        if j + 1 < len(b):
            c |= b[j + 1] << (8 - k)
        out.append(NIX32[c & 0x1F])
    return "".join(out)


MAGIC = {b"\x28\xb5\x2f\xfd": "zstd", b"\xfd7zXZ\x00": "xz", b"\x1f\x8b": "gzip"}


def decode(body, encoding):
    """Both caches store narinfo/.ls zstd-compressed (Content-Encoding), but
    the CDN sometimes serves them without that header: sniff the magic too."""
    if encoding in (None, "", "identity"):
        encoding = next((t for m, t in MAGIC.items() if body.startswith(m)), None)
        if encoding is None:
            return body
    tool = {"zstd": "zstd", "xz": "xz", "br": "brotli", "gzip": "gzip"}[encoding]
    return subprocess.run([tool, "-dc"], input=body, capture_output=True, check=True).stdout


class Stats:
    def __init__(self, path=None):
        self.path = path
        self.lock = threading.Lock()
        self.c = collections.Counter()
        self.nars = []

    def add(self, kind, nbytes):
        with self.lock:
            self.c[kind + "_count"] += 1
            self.c[kind + "_bytes"] += nbytes

    def nar(self, name, file_bytes, nar_bytes):
        with self.lock:
            self.nars.append([name, file_bytes, nar_bytes])
            self.c["nar_count"] += 1
            self.c["nar_bytes"] += file_bytes
            self.c["nar_unpacked_bytes"] += nar_bytes
        self.save()

    def save(self):
        if not self.path:
            return
        with self.lock:
            tmp = self.path + ".tmp"
            with open(tmp, "w") as f:
                json.dump({**self.c, "nars": self.nars}, f)
            os.replace(tmp, self.path)


def fetch_url(url, tries=6):
    """GET url -> (body, headers), retrying 429/5xx and network errors with
    backoff (cache.nixos.org/cache.lassul.us answer 503 under load)."""
    for n in range(tries):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read(), r.headers
        except urllib.error.HTTPError as e:
            if e.code != 429 and e.code < 500 or n == tries - 1:
                raise
            err = f"HTTP {e.code}"
        except (urllib.error.URLError, OSError) as e:
            if url.startswith("file:") or n == tries - 1:
                raise
            err = repr(e)
        print(f"retry {n + 1}/{tries - 1} {url}: {err}", file=sys.stderr, flush=True)
        time.sleep(min(2**n, 30))


def get(url, stats, kind):
    """GET url -> decoded body, or None on 404/403."""
    try:
        body, headers = fetch_url(url)
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):
            return None
        raise
    except urllib.error.URLError as e:  # file:// caches (tests)
        if isinstance(e.reason, FileNotFoundError):
            return None
        raise
    stats.add(kind, len(body))
    return decode(body, headers.get("Content-Encoding"))


# --- closure ---------------------------------------------------------------


def parse_narinfo(text):
    info = {}
    for line in text.decode().splitlines():
        k, _, v = line.partition(": ")
        info[k] = v
    return info


def narinfo(name, stats):
    h = name.split("-", 1)[0]
    for c in CACHES:
        try:
            body = get(f"{c}/{h}.narinfo", stats, "narinfo")
        except (urllib.error.URLError, OSError) as e:  # still failing: try the next cache
            print(f"giving up on {c}/{h}.narinfo: {e!r}", file=sys.stderr, flush=True)
            stats.add("narinfo_error", 0)
            continue
        if body is not None:
            i = parse_narinfo(body)
            i["cache"] = c
            return i
    return None


def wanted_paths(drvs):
    """Output paths nix makes valid before building DRVs (wanted outputs of
    their input derivations), plus the DRVs' own outputs (`--check` needs
    them valid). Input sources are left out: eval put them into the store."""
    j = json.loads(
        subprocess.run(
            ["nix", "derivation", "show", *drvs], check=True, capture_output=True
        ).stdout
    )
    j = j.get("derivations", j)
    abs_ = lambda p: p if p.startswith("/") else STORE + p  # noqa: E731
    targets = {abs_(d) for d in drvs}
    wanted = collections.defaultdict(set)
    for p, d in j.items():
        if "inputs" in d:  # format 4: {inputs: {drvs: .., srcs: ..}}
            idrvs = d["inputs"].get("drvs", {})
        else:
            idrvs = d.get("inputDrvs", {})
        for ip, o in idrvs.items():
            if abs_(ip) not in targets:
                wanted[abs_(ip)].update(o if isinstance(o, list) else o.get("outputs", []))
    paths = set()
    if wanted:
        j2 = json.loads(
            subprocess.run(
                ["nix", "derivation", "show", *wanted], check=True, capture_output=True
            ).stdout
        )
        j2 = j2.get("derivations", j2)
        for p, d in j2.items():
            outs = d["outputs"]
            for o in wanted[abs_(p)]:
                paths.add(abs_(outs[o]["path"]))
    out = subprocess.run(
        ["nix-store", "-q", "--outputs", *drvs], check=True, capture_output=True, text=True
    ).stdout
    paths.update(out.split())
    return paths


def closure(outdir, roots):
    stats = Stats()
    roots = {p[len(STORE) :] for p in roots}
    infos, missing, todo = {}, [], set(roots)
    with concurrent.futures.ThreadPoolExecutor(32) as ex:
        while todo:
            batch = sorted(todo)
            todo = set()
            for name, i in zip(batch, ex.map(lambda n: narinfo(n, stats), batch)):
                if i is None:
                    missing.append(name)
                    continue
                infos[name] = i
                for r in i.get("References", "").split():
                    if r not in infos and r not in batch:
                        todo.add(r)
            todo -= infos.keys()
            todo -= set(missing)
    paths = {
        n: {
            "cache": i["cache"],
            "url": i["URL"],
            "compression": i.get("Compression", "none"),
            "narHash": i["NarHash"],
            "narSize": int(i["NarSize"]),
            "fileSize": int(i.get("FileSize") or 0),
        }
        for n, i in infos.items()
    }
    with open(os.path.join(outdir, "paths.json"), "w") as f:
        json.dump(paths, f)
    with open(os.path.join(outdir, "db.dump"), "w") as f:
        for n, i in sorted(infos.items()):
            refs = i.get("References", "").split()
            d = i.get("Deriver", "")
            deriver = STORE + d if d.endswith(".drv") else ""
            f.write(f"{STORE}{n}\n{i['NarHash']}\n{i['NarSize']}\n{deriver}\n{len(refs)}\n")
            f.writelines(f"{STORE}{r}\n" for r in refs)
    by_cache = collections.Counter(i["cache"] for i in infos.values())
    summary = {
        "roots": len(roots),
        "paths": len(infos),
        "missing": sorted(missing),
        "by_cache": by_cache,
        "nar_size": sum(p["narSize"] for p in paths.values()),
        "file_size": sum(p["fileSize"] for p in paths.values()),
        **stats.c,
    }
    with open(os.path.join(outdir, "closure.json"), "w") as f:
        json.dump(summary, f, indent=1)
    json.dump(summary, sys.stdout, indent=1)
    print()


# --- NAR unpacking -----------------------------------------------------------


class NarReader:
    def __init__(self, f):
        self.f, self.h, self.n = f, hashlib.sha256(), 0

    def read(self, n):
        b = self.f.read(n)
        if len(b) != n:
            raise ValueError("short NAR")
        self.h.update(b)
        self.n += n
        return b

    def int(self):
        return int.from_bytes(self.read(8), "little")

    def str(self, limit=4096):
        n = self.int()
        if n > limit:
            raise ValueError("NAR string too long")
        s = self.read(n)
        self.read((8 - n % 8) % 8)
        return s

    def expect(self, s):
        got = self.str()
        if got != s:
            raise ValueError(f"NAR: expected {s!r}, got {got!r}")

    def node(self, dest):
        self.expect(b"(")
        self.expect(b"type")
        t = self.str()
        if t == b"regular":
            tag, mode = self.str(), 0o444
            if tag == b"executable":
                self.expect(b"")
                tag, mode = self.str(), 0o555
            if tag != b"contents":
                raise ValueError("NAR: expected contents")
            n = self.int()
            with open(dest, "wb") as out:
                while n:
                    b = self.read(min(n, 1 << 20))
                    out.write(b)
                    n -= len(b)
            self.read((8 - self.n % 8) % 8)
            os.chmod(dest, mode)
            self.expect(b")")
        elif t == b"symlink":
            self.expect(b"target")
            os.symlink(self.str(), dest)
            self.expect(b")")
        elif t == b"directory":
            os.mkdir(dest)
            while True:
                tag = self.str()
                if tag == b")":
                    break
                if tag != b"entry":
                    raise ValueError("NAR: expected entry")
                self.expect(b"(")
                self.expect(b"name")
                name = self.str(255)
                if name in (b"", b".", b"..") or b"/" in name:
                    raise ValueError("NAR: bad entry name")
                self.expect(b"node")
                self.node(os.path.join(dest, os.fsdecode(name)))
                self.expect(b")")
            os.chmod(dest, 0o555)
        else:
            raise ValueError(f"NAR: unknown type {t!r}")


def listing_from_tree(p):
    st = os.lstat(p)
    if stat.S_ISDIR(st.st_mode):
        return {
            "type": "directory",
            "entries": {e: listing_from_tree(os.path.join(p, e)) for e in os.listdir(p)},
        }
    if stat.S_ISLNK(st.st_mode):
        return {"type": "symlink", "target": os.readlink(p)}
    return {"type": "regular", "size": st.st_size, "executable": bool(st.st_mode & 0o100)}


# --- FUSE ------------------------------------------------------------------


class LazyStore:
    def __init__(self, outdir):
        with open(os.path.join(outdir, "paths.json")) as f:
            self.paths = json.load(f)
        self.names = sorted(self.paths)
        self.cache = os.path.join(outdir, "cache")
        os.makedirs(self.cache, exist_ok=True)
        self.stats = Stats(os.path.join(outdir, "stats.json"))
        self.listings, self.unpacked = {}, set()
        self.locks = collections.defaultdict(threading.Lock)

    def listing(self, name):
        if name in self.listings:
            return self.listings[name]
        with self.locks["ls " + name]:
            if name not in self.listings:
                p = self.paths[name]
                body = get(f"{p['cache']}/{name.split('-', 1)[0]}.ls", self.stats, "ls")
                if body is None:  # no listing: fall back to the NAR
                    self.listings[name] = listing_from_tree(self.fetch(name))
                else:
                    self.listings[name] = json.loads(body)["root"]
                self.stats.save()
        return self.listings[name]

    def fetch(self, name):
        dest = os.path.join(self.cache, name)
        if name in self.unpacked:
            return dest
        with self.locks["nar " + name]:
            if name in self.unpacked:
                return dest
            p = self.paths[name]
            tmp = dest + ".tmp"
            shutil.rmtree(tmp, ignore_errors=True)
            if os.path.lexists(tmp):
                os.unlink(tmp)
            body, _ = fetch_url(f"{p['cache']}/{p['url']}")
            tool = {"zstd": ["zstd", "-dc"], "xz": ["xz", "-dc"], "bzip2": ["bzip2", "-dc"]}
            if p["compression"] in ("none", ""):
                f = io.BytesIO(body)
                proc = None
            else:
                proc = subprocess.Popen(
                    tool[p["compression"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE
                )
                threading.Thread(target=lambda: (proc.stdin.write(body), proc.stdin.close())).start()
                f = proc.stdout
            nar = NarReader(f)
            nar.expect(b"nix-archive-1")
            nar.node(tmp)
            if proc:
                if f.read(1):
                    raise ValueError("trailing data after NAR")
                proc.wait()
            got = "sha256:" + nix32(nar.h.digest())
            if got != p["narHash"] or nar.n != p["narSize"]:
                raise ValueError(f"{name}: NAR hash mismatch, {got} != {p['narHash']}")
            os.rename(tmp, dest)
            self.unpacked.add(name)
            self.stats.nar(name, len(body), nar.n)
            print(f"fetched {name}: {len(body)} bytes", file=sys.stderr, flush=True)
            return dest

    def resolve(self, path):
        """'/name/sub/dir' -> (name, sub, listing node); name None for root."""
        parts = [x for x in path.split("/") if x]
        if not parts:
            return None, "", None
        name = parts[0]
        if name == LINKS and len(parts) == 1:
            return name, "", {"type": "directory", "entries": {}}
        if name not in self.paths:
            raise OSError(errno.ENOENT, path)
        node = self.listing(name)
        for x in parts[1:]:
            if node.get("type") != "directory" or x not in node["entries"]:
                raise OSError(errno.ENOENT, path)
            node = node["entries"][x]
        return name, "/".join(parts[1:]), node

    def getattr(self, path, fh=None):
        name, _, node = self.resolve(path)
        a = {"st_uid": 0, "st_gid": 0, "st_atime": 1, "st_mtime": 1, "st_ctime": 1}
        if name is None or node["type"] == "directory":
            return {**a, "st_mode": stat.S_IFDIR | 0o555, "st_nlink": 2}
        if node["type"] == "symlink":
            return {
                **a,
                "st_mode": stat.S_IFLNK | 0o777,
                "st_nlink": 1,
                "st_size": len(os.fsencode(node["target"])),
            }
        mode = 0o555 if node.get("executable") else 0o444
        return {**a, "st_mode": stat.S_IFREG | mode, "st_nlink": 1, "st_size": node["size"]}

    def readdir(self, path, fh):
        name, _, node = self.resolve(path)
        entries = [LINKS, *self.names] if name is None else list(node.get("entries", {}))
        return [".", "..", *entries]

    def readlink(self, path):
        _, _, node = self.resolve(path)
        if node["type"] != "symlink":
            raise OSError(errno.EINVAL, path)
        return node["target"]

    def open(self, path, flags):
        name, sub, node = self.resolve(path)
        if node is None or node["type"] != "regular":
            raise OSError(errno.EISDIR, path)
        if flags & (os.O_WRONLY | os.O_RDWR):
            raise OSError(errno.EROFS, path)
        root = self.fetch(name)
        return os.open(os.path.join(root, sub) if sub else root, os.O_RDONLY)

    def read(self, path, size, offset, fh):
        return os.pread(fh, size, offset)

    def release(self, path, fh):
        os.close(fh)
        return 0


def mount(outdir, mnt):
    from fuse import FUSE, FuseOSError, Operations

    # libfuse2 refuses non-empty mount points ("use the 'nonempty' mount
    # option"); say what is in the way instead of only failing in fuse_main
    if os.listdir(mnt):
        sys.exit(f"mount point {mnt} is not empty: {sorted(os.listdir(mnt))[:10]}")
    store = LazyStore(outdir)
    print(f"mounting {len(store.names)} store paths at {mnt}", file=sys.stderr, flush=True)

    class Ops(Operations):
        def __call__(self, op, *args):
            impl = getattr(store, op, None)
            if impl is None:  # fusepy's read-only defaults (opendir, statfs, ...)
                return super().__call__(op, *args)
            try:
                return impl(*args)
            except OSError as e:
                raise FuseOSError(e.errno or errno.EIO)
            except Exception as e:  # noqa: BLE001
                print(f"{op} {args[:1]}: {e!r}", file=sys.stderr, flush=True)
                raise FuseOSError(errno.EIO)

    store.stats.save()
    FUSE(
        Ops(),
        mnt,
        foreground=True,
        ro=True,
        allow_other=True,
        kernel_cache=True,
        attr_timeout=86400,
        entry_timeout=86400,
        negative_timeout=86400,
    )
    print("FUSE main loop exited", file=sys.stderr, flush=True)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "closure":
        closure(args[0], wanted_paths(args[1:]))
    elif cmd == "mount":
        mount(args[0], args[1])
    else:
        sys.exit(__doc__)
