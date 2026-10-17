//! The lower layer: all store paths of OUT/paths.json, read-only. Metadata
//! comes from the caches' `.ls` listings, all fetched up front and kept in
//! memory; the first open() of a file in a store path fetches, verifies
//! (NarHash/NarSize) and unpacks that path's NAR. Opens of a path that is
//! being fetched wait for that fetch.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::ffi::{CStr, CString};
use std::fs::File;
use std::io;
use std::mem::ManuallyDrop;
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use fuse_backend_rs::abi::fuse_abi::stat64;
use fuse_backend_rs::api::filesystem::{
    Context, DirEntry, Entry, FileSystem, GetxattrReply, ListxattrReply, OpenOptions,
    ZeroCopyWriter,
};
use futures_util::{stream, StreamExt};
use harmonia_file_core::{Directory, FileSystemObject, FileTree, Regular, Symlink};
use harmonia_utils_hash::HashFormat;
use tokio_util::io::InspectReader;

use crate::closure::PathInfo;
use crate::http::{self, Http};
use crate::nar::{self, Size, Tree};
use crate::stats::Stats;
use crate::{Backing, STORE};

/// The store paths never change: let the kernel cache everything.
pub const TTL: Duration = Duration::from_secs(86400);

/// Set on the inode numbers (st_ino) of this layer, so they don't collide
/// with the upper layer's.
pub const INO_TAG: u64 = 1 << 62;

enum Kind {
    /// children sorted by name
    Dir(Vec<(Box<str>, u32)>),
    File {
        size: u64,
        exec: bool,
    },
    Symlink(Box<[u8]>),
}

struct Node {
    kind: Kind,
    /// index into `LazyFs::names`
    path: u32,
    /// path below the store path (empty for its root)
    rel: Box<str>,
}

struct Handle {
    file: File,
    ino: u64,
}

pub struct LazyFs {
    names: Vec<String>,
    infos: Vec<PathInfo>,
    /// inode `i` is `nodes[i - 1]`; inode 1 is the store dir
    nodes: Vec<Node>,
    cache: PathBuf,
    http: Http,
    pub stats: Arc<Stats>,
    /// per store path: where it is unpacked, once fetched
    fetched: Vec<tokio::sync::Mutex<Option<PathBuf>>>,
    /// for the FUSE worker threads, to fetch on the runtime
    rt: tokio::runtime::Handle,
    handles: RwLock<HashMap<u64, Arc<Handle>>>,
    next_handle: AtomicU64,
    backing: Option<Arc<Backing>>,
    passthrough: AtomicBool,
    /// backing id and open count per inode: the kernel wants all
    /// passthrough opens of an inode to use the same backing file
    backing_ids: Mutex<HashMap<u64, (u32, usize)>>,
    backing_failed: AtomicBool,
}

fn err(e: i32) -> io::Error {
    io::Error::from_raw_os_error(e)
}

/// `dump` (a `nix-store --load-db` input) without the store paths `failed`
/// and everything referring to them, like `closure` leaves out what refers
/// to paths not in the caches; and the names of the paths left out.
fn leave_out<'a>(
    dump: &'a str,
    failed: impl IntoIterator<Item = &'a str>,
) -> io::Result<(String, BTreeSet<String>)> {
    let bad = || io::Error::other("malformed db.dump");
    let name = |l: &'a str| l.strip_prefix(STORE).ok_or_else(bad);
    // per path: name, references and its lines
    let mut records = Vec::new();
    let mut lines = dump.split_inclusive('\n');
    while let Some(p) = lines.next() {
        let mut text = p.to_string();
        for _ in 0..3 {
            text += lines.next().ok_or_else(bad)?;
        }
        let count = lines.next().ok_or_else(bad)?;
        text += count;
        let count: usize = count.trim_end().parse().map_err(|_| bad())?;
        let mut refs = Vec::with_capacity(count);
        for _ in 0..count {
            let r = lines.next().ok_or_else(bad)?;
            text += r;
            refs.push(name(r.trim_end())?);
        }
        records.push((name(p.trim_end())?, refs, text));
    }
    let mut referrers: HashMap<&str, Vec<&str>> = HashMap::new();
    for (n, refs, _) in &records {
        for r in refs.iter().filter(|r| *r != n) {
            referrers.entry(r).or_default().push(n);
        }
    }
    let mut out: BTreeSet<&str> = failed.into_iter().collect();
    let mut todo: Vec<&str> = out.iter().copied().collect();
    while let Some(m) = todo.pop() {
        for r in referrers.get(m).into_iter().flatten() {
            if out.insert(r) {
                todo.push(r);
            }
        }
    }
    let kept = records
        .iter()
        .filter(|(n, _, _)| !out.contains(n))
        .map(|(_, _, t)| t.as_str())
        .collect();
    Ok((kept, out.into_iter().map(str::to_string).collect()))
}

impl LazyFs {
    pub async fn new(outdir: &Path, backing: Option<Arc<Backing>>) -> io::Result<LazyFs> {
        let paths: BTreeMap<String, PathInfo> =
            serde_json::from_slice(&std::fs::read(outdir.join("paths.json"))?)?;
        let (names, infos): (Vec<String>, Vec<PathInfo>) = paths.into_iter().unzip();
        let cache = outdir.join("cache");
        std::fs::create_dir_all(&cache)?;
        let http = Http::new(infos.iter().map(|i| i.cache.as_str())).await;
        let mut fs = LazyFs {
            fetched: names.iter().map(|_| Default::default()).collect(),
            rt: tokio::runtime::Handle::current(),
            names,
            infos,
            nodes: Vec::new(),
            cache,
            http,
            stats: Arc::new(Stats::new(Some(outdir.join("stats.json")))),
            handles: RwLock::new(HashMap::new()),
            next_handle: AtomicU64::new(1),
            backing,
            passthrough: AtomicBool::new(false),
            backing_ids: Mutex::new(HashMap::new()),
            backing_failed: AtomicBool::new(false),
        };
        fs.load_listings(outdir).await?;
        fs.stats.save();
        Ok(fs)
    }

    /// Fetch the `.ls` listing of every store path (falling back to the NAR
    /// for paths without one) and build the inode table from them. Paths
    /// left without a listing, and everything referring to them, are left
    /// out of OUT/paths.json and OUT/db.dump (see `leave_out`), so they are
    /// neither served nor registered; OUT/no-listing.json counts them.
    async fn load_listings(&mut self, outdir: &Path) -> io::Result<()> {
        let t = Instant::now();
        let total = self.names.len();
        let mut trees: Vec<Option<io::Result<Tree>>> = (0..total).map(|_| None).collect();
        let this = &*self;
        let mut done = stream::iter(0..total)
            .map(|i| async move { (i, this.listing(i).await) })
            .buffer_unordered(64);
        let mut n = 0;
        while let Some((i, r)) = done.next().await {
            trees[i] = Some(r);
            n += 1;
            if n % 500 == 0 {
                eprintln!("listings: {n}/{total}");
            }
        }
        drop(done);
        let trees = trees.into_iter().map(Option::unwrap);
        let mut root = Vec::with_capacity(total);
        self.nodes.push(Node {
            kind: Kind::Dir(Vec::new()),
            path: u32::MAX,
            rel: "".into(),
        });
        let mut ok = Vec::with_capacity(total);
        let mut failed = Vec::new();
        for (i, t) in trees.enumerate() {
            match t {
                Ok(t) => ok.push((i, t)),
                Err(e) => {
                    eprintln!("no listing for {}: {e}", self.names[i]);
                    failed.push(self.names[i].clone());
                }
            }
        }
        let mut left_out = BTreeSet::new();
        if !failed.is_empty() {
            let dump = std::fs::read_to_string(outdir.join("db.dump"))?;
            let (kept, out) = leave_out(&dump, failed.iter().map(String::as_str))?;
            std::fs::write(outdir.join("db.dump"), kept)?;
            let paths: BTreeMap<&String, &PathInfo> = self
                .names
                .iter()
                .zip(&self.infos)
                .filter(|(n, _)| !out.contains(n.as_str()))
                .collect();
            std::fs::write(outdir.join("paths.json"), serde_json::to_vec(&paths)?)?;
            left_out = out;
        }
        std::fs::write(
            outdir.join("no-listing.json"),
            serde_json::to_vec(&serde_json::json!({
                "failed": failed,
                "incomplete": left_out.len() - failed.len(),
            }))?,
        )?;
        for (i, t) in ok {
            if left_out.contains(&self.names[i]) {
                continue;
            }
            let ino = self.add(i as u32, String::new(), t);
            root.push((self.names[i].clone().into_boxed_str(), ino));
        }
        root.sort();
        self.nodes[0].kind = Kind::Dir(root);
        eprintln!(
            "listings: {} store paths, {} inodes in {:.1} s; {} without a listing, {} referring to those left out",
            self.names.len(),
            self.nodes.len(),
            t.elapsed().as_secs_f64(),
            failed.len(),
            left_out.len() - failed.len(),
        );
        Ok(())
    }

    async fn listing(&self, i: usize) -> io::Result<Tree> {
        let info = &self.infos[i];
        let h = self.names[i].split('-').next().unwrap_or("");
        match self.http.get(&format!("{}/{h}.ls", info.cache)).await {
            Ok((body, len)) => {
                self.stats.add("ls", len as u64);
                nar::from_listing(&body)
            }
            // no listing: fall back to the NAR
            Err(http::Error::NotFound) => nar::from_path(&self.fetch(i).await?),
            Err(e) => Err(e.into()),
        }
    }

    /// Add the nodes of `t` (at `rel` in store path `path`), return its inode.
    fn add(&mut self, path: u32, rel: String, FileTree(t): Tree) -> u32 {
        let ino = self.nodes.len() as u32 + 1;
        let (kind, entries) = match t {
            FileSystemObject::Regular(r) => {
                let (size, exec) = (r.contents.size, r.executable);
                (Kind::File { size, exec }, None)
            }
            FileSystemObject::Symlink(s) => (Kind::Symlink(s.target.into_bytes().into()), None),
            FileSystemObject::Directory(d) => (Kind::Dir(Vec::new()), Some(d.entries)),
        };
        self.nodes.push(Node {
            kind,
            path,
            rel: rel.clone().into(),
        });
        if let Some(entries) = entries {
            let mut children = Vec::with_capacity(entries.len());
            for (name, c) in entries {
                let r = if rel.is_empty() {
                    name.clone()
                } else {
                    format!("{rel}/{name}")
                };
                children.push((name.into_boxed_str(), self.add(path, r, *c)));
            }
            // BTreeMap order is sorted already
            self.nodes[ino as usize - 1].kind = Kind::Dir(children);
        }
        ino
    }

    /// The listing of `ino` as built from the `.ls` (for `fetch`).
    fn tree_of(&self, ino: u64) -> Tree {
        FileTree(match &self.nodes[ino as usize - 1].kind {
            Kind::Dir(c) => FileSystemObject::Directory(Directory {
                entries: c
                    .iter()
                    .map(|(n, i)| (n.to_string(), Box::new(self.tree_of(*i as u64))))
                    .collect(),
            }),
            Kind::File { size, exec } => FileSystemObject::Regular(Regular {
                executable: *exec,
                contents: Size { size: *size },
            }),
            Kind::Symlink(t) => FileSystemObject::Symlink(Symlink {
                target: String::from_utf8_lossy(t).into_owned(),
            }),
        })
    }

    /// Fetch store path `name` as an open() would and check that what got
    /// unpacked matches its listing (`lazy-store fetch`, no FUSE needed).
    pub async fn fetch_and_check(&self, name: &str) -> io::Result<PathBuf> {
        let c = CString::new(name).map_err(io::Error::other)?;
        let ino = self.lookup_child(1, &c).ok_or_else(|| err(libc::ENOENT))?;
        let p = self
            .fetch(self.nodes[ino as usize - 1].path as usize)
            .await?;
        if nar::from_path(&p)? != self.tree_of(ino) {
            return Err(io::Error::other(format!(
                "{name}: unpacked tree differs from its listing"
            )));
        }
        Ok(p)
    }

    pub fn set_passthrough(&self, on: bool) {
        self.passthrough
            .store(on && self.backing.is_some(), Ordering::Relaxed);
    }

    fn node(&self, ino: u64) -> io::Result<&Node> {
        (ino as usize)
            .checked_sub(1)
            .and_then(|i| self.nodes.get(i))
            .ok_or_else(|| err(libc::ENOENT))
    }

    pub fn has_root_entry(&self, name: &CStr) -> bool {
        self.lookup_child(1, name).is_some()
    }

    pub fn root_entries(&self) -> impl Iterator<Item = (&str, u64, u32)> {
        let Kind::Dir(c) = &self.nodes[0].kind else {
            unreachable!()
        };
        c.iter()
            .map(|(n, i)| (&**n, *i as u64, self.dtype(*i as u64)))
    }

    fn lookup_child(&self, parent: u64, name: &CStr) -> Option<u64> {
        let Kind::Dir(c) = &self.node(parent).ok()?.kind else {
            return None;
        };
        let name = name.to_str().ok()?;
        c.binary_search_by(|(n, _)| (**n).cmp(name))
            .ok()
            .map(|i| c[i].1 as u64)
    }

    fn dtype(&self, ino: u64) -> u32 {
        match self.nodes[ino as usize - 1].kind {
            Kind::Dir(_) => libc::DT_DIR as u32,
            Kind::File { .. } => libc::DT_REG as u32,
            Kind::Symlink(_) => libc::DT_LNK as u32,
        }
    }

    fn stat(&self, ino: u64) -> io::Result<stat64> {
        let n = self.node(ino)?;
        // Safe: stat64 is plain old data.
        let mut st: stat64 = unsafe { std::mem::zeroed() };
        st.st_ino = ino | INO_TAG;
        st.st_blksize = 4096;
        st.st_atime = 1;
        st.st_mtime = 1;
        st.st_ctime = 1;
        match &n.kind {
            Kind::Dir(_) => {
                st.st_mode = libc::S_IFDIR | 0o555;
                // 1: "subdirectory count unknown", which keeps find(1)
                // from skipping entries based on it
                st.st_nlink = 1;
            }
            Kind::File { size, exec } => {
                st.st_mode = libc::S_IFREG | if *exec { 0o555 } else { 0o444 };
                st.st_nlink = 1;
                st.st_size = *size as i64;
                st.st_blocks = size.div_ceil(512) as i64;
            }
            Kind::Symlink(t) => {
                st.st_mode = libc::S_IFLNK | 0o777;
                st.st_nlink = 1;
                st.st_size = t.len() as i64;
            }
        }
        Ok(st)
    }

    /// The unpacked store path `i`, fetching it first if needed. Concurrent
    /// callers for the same path wait for one fetch.
    async fn fetch(&self, i: usize) -> io::Result<PathBuf> {
        let mut slot = self.fetched[i].lock().await;
        if let Some(p) = &*slot {
            return Ok(p.clone());
        }
        let name = &self.names[i];
        let dest = self.cache.join(name);
        let mut last = None;
        for attempt in 1..=3 {
            match self.fetch_once(i, &dest).await {
                Ok(()) => {
                    *slot = Some(dest.clone());
                    return Ok(dest);
                }
                Err(e) => {
                    eprintln!("fetching {name} (attempt {attempt}/3): {e}");
                    last = Some(e);
                }
            }
        }
        Err(last.unwrap())
    }

    async fn fetch_once(&self, i: usize, dest: &Path) -> io::Result<()> {
        let (name, info) = (&self.names[i], &self.infos[i]);
        let t = Instant::now();
        let tmp = dest.with_extension("tmp");
        nar::remove(&tmp)?;
        nar::remove(dest)?;
        let (body, _) = self
            .http
            .open(&format!("{}/{}", info.cache, info.url))
            .await?;
        // the compressed download size
        let mut file_size = 0;
        let mut body = InspectReader::new(body, |b: &[u8]| file_size += b.len() as u64);
        let nar = http::decode_body(&info.compression, &mut body)?;
        let (hash, size) = nar::unpack(nar, &tmp).await?;
        drop(body);
        if !nar::hash_matches(&info.nar_hash, &hash) || size != info.nar_size {
            nar::remove(&tmp)?;
            return Err(io::Error::other(format!(
                "{name}: NAR hash mismatch, {} ({size} bytes) != {} ({} bytes)",
                hash.as_base32(),
                info.nar_hash,
                info.nar_size
            )));
        }
        std::fs::rename(&tmp, dest)?;
        self.stats.nar(name, file_size, size);
        eprintln!(
            "fetched {name}: {file_size} bytes in {:.1} s",
            t.elapsed().as_secs_f64()
        );
        Ok(())
    }

    fn entry(&self, ino: u64) -> io::Result<Entry> {
        Ok(Entry {
            inode: ino,
            generation: 0,
            attr: self.stat(ino)?,
            attr_flags: 0,
            attr_timeout: TTL,
            entry_timeout: TTL,
        })
    }

    fn backing_id(&self, ino: u64, file: &File) -> Option<u32> {
        if !self.passthrough.load(Ordering::Relaxed) {
            return None;
        }
        let backing = self.backing.as_ref()?;
        let mut ids = self.backing_ids.lock().unwrap();
        if let Some((id, n)) = ids.get_mut(&ino) {
            *n += 1;
            return Some(*id);
        }
        match backing.open_fd(file.as_raw_fd()) {
            Ok(id) => {
                ids.insert(ino, (id, 1));
                Some(id)
            }
            Err(e) => {
                if !self.backing_failed.swap(true, Ordering::Relaxed) {
                    eprintln!(
                        "lower: FUSE passthrough backing open failed, reading via the daemon: {e}"
                    );
                }
                None
            }
        }
    }

    fn release_backing(&self, ino: u64) {
        let mut ids = self.backing_ids.lock().unwrap();
        if let Some((id, n)) = ids.get_mut(&ino) {
            *n -= 1;
            if *n == 0 {
                let id = *id;
                ids.remove(&ino);
                drop(ids);
                if let Some(b) = &self.backing {
                    b.close_id(id);
                }
            }
        }
    }
}

impl FileSystem for LazyFs {
    type Inode = u64;
    type Handle = u64;

    fn lookup(&self, _ctx: &Context, parent: u64, name: &CStr) -> io::Result<Entry> {
        match self.lookup_child(parent, name) {
            Some(ino) => self.entry(ino),
            None => Err(err(libc::ENOENT)),
        }
    }

    fn getattr(&self, _ctx: &Context, ino: u64, _h: Option<u64>) -> io::Result<(stat64, Duration)> {
        Ok((self.stat(ino)?, TTL))
    }

    fn readlink(&self, _ctx: &Context, ino: u64) -> io::Result<Vec<u8>> {
        match &self.node(ino)?.kind {
            Kind::Symlink(t) => Ok(t.to_vec()),
            _ => Err(err(libc::EINVAL)),
        }
    }

    fn open(
        &self,
        _ctx: &Context,
        ino: u64,
        flags: u32,
        _fuse_flags: u32,
    ) -> io::Result<(Option<u64>, OpenOptions, Option<u32>)> {
        let n = self.node(ino)?;
        if !matches!(n.kind, Kind::File { .. }) {
            return Err(err(libc::EISDIR));
        }
        let acc = flags as i32 & libc::O_ACCMODE;
        if acc != libc::O_RDONLY || flags as i32 & libc::O_TRUNC != 0 {
            return Err(err(libc::EROFS));
        }
        let root = self.rt.block_on(self.fetch(n.path as usize)).map_err(|e| {
            eprintln!("open {}/{}: {e}", self.names[n.path as usize], n.rel);
            err(libc::EIO)
        })?;
        let file = File::open(if n.rel.is_empty() {
            root
        } else {
            root.join(&*n.rel)
        })?;
        let backing = self.backing_id(ino, &file);
        let h = self.next_handle.fetch_add(1, Ordering::Relaxed);
        self.handles
            .write()
            .unwrap()
            .insert(h, Arc::new(Handle { file, ino }));
        Ok(match backing {
            Some(id) => (Some(h), OpenOptions::PASSTHROUGH, Some(id)),
            None => (Some(h), OpenOptions::KEEP_CACHE, None),
        })
    }

    fn read(
        &self,
        _ctx: &Context,
        _ino: u64,
        handle: u64,
        w: &mut dyn ZeroCopyWriter,
        size: u32,
        offset: u64,
        _lock_owner: Option<u64>,
        _flags: u32,
    ) -> io::Result<usize> {
        let h = self
            .handles
            .read()
            .unwrap()
            .get(&handle)
            .cloned()
            .ok_or_else(|| err(libc::EBADF))?;
        // Safe: borrows the fd of `h.file`, which outlives `f`, without closing it.
        let mut f = ManuallyDrop::new(unsafe { File::from_raw_fd(h.file.as_raw_fd()) });
        w.write_from(&mut *f, size as usize, offset)
    }

    fn lseek(
        &self,
        _ctx: &Context,
        _ino: u64,
        handle: u64,
        offset: u64,
        whence: u32,
    ) -> io::Result<u64> {
        let h = self
            .handles
            .read()
            .unwrap()
            .get(&handle)
            .cloned()
            .ok_or_else(|| err(libc::EBADF))?;
        // Safe: plain syscall on an fd we own.
        let r = unsafe { libc::lseek(h.file.as_raw_fd(), offset as i64, whence as i32) };
        if r < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(r as u64)
    }

    fn flush(&self, _ctx: &Context, _ino: u64, _handle: u64, _lock_owner: u64) -> io::Result<()> {
        Ok(())
    }

    fn fsync(&self, _ctx: &Context, _ino: u64, _datasync: bool, _handle: u64) -> io::Result<()> {
        Ok(())
    }

    fn release(
        &self,
        _ctx: &Context,
        _ino: u64,
        _flags: u32,
        handle: u64,
        _flush: bool,
        _flock_release: bool,
        _lock_owner: Option<u64>,
    ) -> io::Result<()> {
        if let Some(h) = self.handles.write().unwrap().remove(&handle) {
            self.release_backing(h.ino);
        }
        Ok(())
    }

    fn opendir(
        &self,
        _ctx: &Context,
        ino: u64,
        _flags: u32,
    ) -> io::Result<(Option<u64>, OpenOptions)> {
        match self.node(ino)?.kind {
            Kind::Dir(_) => Ok((None, OpenOptions::KEEP_CACHE | OpenOptions::CACHE_DIR)),
            _ => Err(err(libc::ENOTDIR)),
        }
    }

    fn readdir(
        &self,
        _ctx: &Context,
        ino: u64,
        _handle: u64,
        _size: u32,
        offset: u64,
        add_entry: &mut dyn FnMut(DirEntry) -> io::Result<usize>,
    ) -> io::Result<()> {
        let Kind::Dir(c) = &self.node(ino)?.kind else {
            return Err(err(libc::ENOTDIR));
        };
        for (i, (name, child)) in c.iter().enumerate().skip(offset as usize) {
            let child = *child as u64;
            let n = add_entry(DirEntry {
                ino: child | INO_TAG,
                offset: i as u64 + 1,
                type_: self.dtype(child),
                name: name.as_bytes(),
            })?;
            if n == 0 {
                break;
            }
        }
        Ok(())
    }

    fn releasedir(&self, _ctx: &Context, _ino: u64, _flags: u32, _handle: u64) -> io::Result<()> {
        Ok(())
    }

    fn getxattr(
        &self,
        _ctx: &Context,
        _ino: u64,
        _name: &CStr,
        _size: u32,
    ) -> io::Result<GetxattrReply> {
        Err(err(libc::ENODATA))
    }

    fn listxattr(&self, _ctx: &Context, _ino: u64, size: u32) -> io::Result<ListxattrReply> {
        Ok(if size == 0 {
            ListxattrReply::Count(0)
        } else {
            ListxattrReply::Names(Vec::new())
        })
    }

    fn access(&self, _ctx: &Context, _ino: u64, mask: u32) -> io::Result<()> {
        if mask as i32 & libc::W_OK != 0 {
            return Err(err(libc::EROFS));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leave_out_referrers() {
        let rec = |n: &str, refs: &[&str]| {
            let mut s = format!("{STORE}{n}\nsha256:x\n8\n\n{}\n", refs.len());
            for r in refs {
                s += &format!("{STORE}{r}\n");
            }
            s
        };
        // w -> x -> y (failed), y -> y, z
        let dump = [
            rec("w", &["x"]),
            rec("x", &["x", "y"]),
            rec("y", &["y"]),
            rec("z", &[]),
        ]
        .concat();
        let (kept, out) = leave_out(&dump, ["y"]).unwrap();
        assert_eq!(kept, rec("z", &[]));
        assert_eq!(out, ["w", "x", "y"].map(String::from).into());
        let (kept, out) = leave_out(&dump, []).unwrap();
        assert_eq!(kept, dump);
        assert!(out.is_empty());
    }
}
