//! The file system mounted on /nix/store: the runner's real store (upper,
//! PassthroughFs, all writes go there) merged with the lazy store paths
//! (lower, LazyFs).
//!
//! Unlike a general overlay, the two only meet in the root directory: every
//! entry of the store dir, i.e. every store path, is entirely in one layer
//! (the upper one if it is in both). So nothing ever needs copying up,
//! below the root each request goes straight to the layer of its inode, and
//! both layers can hand their open files to the kernel (FUSE passthrough).
//! Lower inodes are the LazyFs ones with LOWER set; PassthroughFs inode
//! numbers stay below 2^56.

use std::collections::{HashMap, HashSet};
use std::ffi::CStr;
use std::io;
use std::os::unix::fs::{DirEntryExt, FileTypeExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use fuse_backend_rs::abi::fuse_abi::{stat64, statvfs64, CreateIn, FsOptions, SetattrValid};
use fuse_backend_rs::api::filesystem::{
    Context, DirEntry, Entry, FileSystem, GetxattrReply, ListxattrReply, OpenOptions,
    ZeroCopyReader, ZeroCopyWriter, ROOT_ID,
};
use fuse_backend_rs::passthrough::PassthroughFs;

use crate::lazy::{LazyFs, INO_TAG};

const LOWER: u64 = INO_TAG;

fn err(e: i32) -> io::Error {
    io::Error::from_raw_os_error(e)
}

fn is_lower(ino: u64) -> bool {
    ino & LOWER != 0
}

fn errno(e: &io::Error) -> i32 {
    e.raw_os_error().unwrap_or(0)
}

struct RootEnt {
    name: Vec<u8>,
    ino: u64,
    type_: u32,
}

pub struct StoreFs {
    upper: PassthroughFs<()>,
    upper_dir: PathBuf,
    pub lower: LazyFs,
    /// open handles of the root directory: a snapshot of the merged listing
    root_dirs: Mutex<HashMap<u64, Arc<Vec<RootEnt>>>>,
    next_root_handle: AtomicU64,
}

macro_rules! by_layer {
    ($self:ident, $ino:expr, |$fs:ident, $i:ident| $e:expr) => {
        if is_lower($ino) {
            let $fs = &$self.lower;
            let $i = $ino & !LOWER;
            $e
        } else {
            let $fs = &$self.upper;
            let $i = $ino;
            $e
        }
    };
}

/// Writes to the lower layer.
macro_rules! upper_only {
    ($self:ident, $ino:expr, |$fs:ident| $e:expr) => {
        if is_lower($ino) {
            Err(err(libc::EROFS))
        } else {
            let $fs = &$self.upper;
            $e
        }
    };
}

fn tag(mut e: Entry) -> Entry {
    if e.inode != 0 {
        e.inode |= LOWER;
    }
    e
}

impl StoreFs {
    pub fn new(upper: PassthroughFs<()>, upper_dir: PathBuf, lower: LazyFs) -> StoreFs {
        StoreFs {
            upper,
            upper_dir,
            lower,
            root_dirs: Mutex::new(HashMap::new()),
            next_root_handle: AtomicU64::new(1),
        }
    }

    /// Creating `name` in `parent`: fail if it would hide a lower store path.
    fn check_new(&self, parent: u64, name: &CStr) -> io::Result<()> {
        if is_lower(parent) {
            return Err(err(libc::EROFS));
        }
        if parent == ROOT_ID && self.lower.has_root_entry(name) {
            return Err(err(libc::EEXIST));
        }
        Ok(())
    }

    /// Removing `name` from `parent` in the upper layer failed with `e`.
    fn rm_err(&self, parent: u64, name: &CStr, e: io::Error) -> io::Error {
        if parent == ROOT_ID && errno(&e) == libc::ENOENT && self.lower.has_root_entry(name) {
            err(libc::EROFS)
        } else {
            e
        }
    }

    fn root_listing(&self) -> io::Result<Vec<RootEnt>> {
        let mut out = Vec::new();
        let mut seen = HashSet::new();
        for d in std::fs::read_dir(&self.upper_dir)? {
            let d = d?;
            let t = d.file_type()?;
            let type_ = if t.is_dir() {
                libc::DT_DIR
            } else if t.is_symlink() {
                libc::DT_LNK
            } else if t.is_file() {
                libc::DT_REG
            } else if t.is_char_device() {
                libc::DT_CHR
            } else {
                libc::DT_UNKNOWN
            };
            let name = d.file_name().into_encoded_bytes();
            seen.insert(name.clone());
            out.push(RootEnt {
                name,
                ino: d.ino(),
                type_: type_ as u32,
            });
        }
        for (name, ino, type_) in self.lower.root_entries() {
            if !seen.contains(name.as_bytes()) {
                out.push(RootEnt {
                    name: name.as_bytes().to_vec(),
                    ino: ino | LOWER,
                    type_,
                });
            }
        }
        Ok(out)
    }
}

impl FileSystem for StoreFs {
    type Inode = u64;
    type Handle = u64;

    fn init(&self, capable: FsOptions) -> io::Result<FsOptions> {
        let mut opts = self.upper.init(capable)?;
        let pt = opts.contains(FsOptions::PASSTHROUGH);
        self.lower.set_passthrough(pt);
        eprintln!(
            "init: kernel FUSE passthrough {}",
            if pt {
                "on"
            } else if capable.contains(FsOptions::PASSTHROUGH) {
                "offered by the kernel but off"
            } else {
                "not offered by the kernel"
            }
        );
        // the merged root has no readdirplus
        opts.remove(
            FsOptions::DO_READDIRPLUS | FsOptions::READDIRPLUS_AUTO | FsOptions::PERFILE_DAX,
        );
        Ok(opts)
    }

    fn destroy(&self) {
        eprintln!("FUSE connection destroyed");
    }

    fn lookup(&self, ctx: &Context, parent: u64, name: &CStr) -> io::Result<Entry> {
        if parent == ROOT_ID {
            let up = self.upper.lookup(ctx, ROOT_ID, name);
            match &up {
                Ok(e) if e.inode != 0 => return up,
                Ok(_) => {}
                Err(e) if errno(e) == libc::ENOENT => {}
                Err(_) => return up,
            }
            return match self.lower.lookup(ctx, 1, name) {
                Ok(e) => Ok(tag(e)),
                Err(_) => up,
            };
        }
        if is_lower(parent) {
            return self.lower.lookup(ctx, parent & !LOWER, name).map(tag);
        }
        self.upper.lookup(ctx, parent, name)
    }

    fn forget(&self, ctx: &Context, ino: u64, count: u64) {
        if !is_lower(ino) {
            self.upper.forget(ctx, ino, count)
        }
    }

    fn batch_forget(&self, ctx: &Context, requests: Vec<(u64, u64)>) {
        let up: Vec<_> = requests
            .into_iter()
            .filter(|(i, _)| !is_lower(*i))
            .collect();
        self.upper.batch_forget(ctx, up)
    }

    fn getattr(&self, ctx: &Context, ino: u64, h: Option<u64>) -> io::Result<(stat64, Duration)> {
        by_layer!(self, ino, |fs, i| fs.getattr(ctx, i, h))
    }

    fn setattr(
        &self,
        ctx: &Context,
        ino: u64,
        attr: stat64,
        h: Option<u64>,
        valid: SetattrValid,
    ) -> io::Result<(stat64, Duration)> {
        upper_only!(self, ino, |fs| fs.setattr(ctx, ino, attr, h, valid))
    }

    fn readlink(&self, ctx: &Context, ino: u64) -> io::Result<Vec<u8>> {
        by_layer!(self, ino, |fs, i| fs.readlink(ctx, i))
    }

    fn symlink(
        &self,
        ctx: &Context,
        linkname: &CStr,
        parent: u64,
        name: &CStr,
    ) -> io::Result<Entry> {
        self.check_new(parent, name)?;
        self.upper.symlink(ctx, linkname, parent, name)
    }

    fn mknod(
        &self,
        ctx: &Context,
        parent: u64,
        name: &CStr,
        mode: u32,
        rdev: u32,
        umask: u32,
    ) -> io::Result<Entry> {
        self.check_new(parent, name)?;
        self.upper.mknod(ctx, parent, name, mode, rdev, umask)
    }

    fn mkdir(
        &self,
        ctx: &Context,
        parent: u64,
        name: &CStr,
        mode: u32,
        umask: u32,
    ) -> io::Result<Entry> {
        self.check_new(parent, name)?;
        self.upper.mkdir(ctx, parent, name, mode, umask)
    }

    fn unlink(&self, ctx: &Context, parent: u64, name: &CStr) -> io::Result<()> {
        upper_only!(self, parent, |fs| fs
            .unlink(ctx, parent, name)
            .map_err(|e| self.rm_err(parent, name, e)))
    }

    fn rmdir(&self, ctx: &Context, parent: u64, name: &CStr) -> io::Result<()> {
        upper_only!(self, parent, |fs| fs
            .rmdir(ctx, parent, name)
            .map_err(|e| self.rm_err(parent, name, e)))
    }

    fn rename(
        &self,
        ctx: &Context,
        olddir: u64,
        oldname: &CStr,
        newdir: u64,
        newname: &CStr,
        flags: u32,
    ) -> io::Result<()> {
        if is_lower(olddir) || is_lower(newdir) {
            return Err(err(libc::EXDEV));
        }
        // Renaming onto a lower store path hides it, as an overlay would.
        self.upper
            .rename(ctx, olddir, oldname, newdir, newname, flags)
            .map_err(|e| match self.rm_err(olddir, oldname, e) {
                e if errno(&e) == libc::EROFS => err(libc::EXDEV),
                e => e,
            })
    }

    fn link(&self, ctx: &Context, ino: u64, newparent: u64, newname: &CStr) -> io::Result<Entry> {
        if is_lower(ino) {
            return Err(err(libc::EXDEV));
        }
        self.check_new(newparent, newname)?;
        self.upper.link(ctx, ino, newparent, newname)
    }

    fn open(
        &self,
        ctx: &Context,
        ino: u64,
        flags: u32,
        fuse_flags: u32,
    ) -> io::Result<(Option<u64>, OpenOptions, Option<u32>)> {
        by_layer!(self, ino, |fs, i| fs.open(ctx, i, flags, fuse_flags))
    }

    fn create(
        &self,
        ctx: &Context,
        parent: u64,
        name: &CStr,
        args: CreateIn,
    ) -> io::Result<(Entry, Option<u64>, OpenOptions, Option<u32>)> {
        self.check_new(parent, name)?;
        self.upper.create(ctx, parent, name, args)
    }

    fn read(
        &self,
        ctx: &Context,
        ino: u64,
        handle: u64,
        w: &mut dyn ZeroCopyWriter,
        size: u32,
        offset: u64,
        lock_owner: Option<u64>,
        flags: u32,
    ) -> io::Result<usize> {
        by_layer!(self, ino, |fs, i| fs
            .read(ctx, i, handle, w, size, offset, lock_owner, flags))
    }

    fn write(
        &self,
        ctx: &Context,
        ino: u64,
        handle: u64,
        r: &mut dyn ZeroCopyReader,
        size: u32,
        offset: u64,
        lock_owner: Option<u64>,
        delayed_write: bool,
        flags: u32,
        fuse_flags: u32,
    ) -> io::Result<usize> {
        upper_only!(self, ino, |fs| fs.write(
            ctx,
            ino,
            handle,
            r,
            size,
            offset,
            lock_owner,
            delayed_write,
            flags,
            fuse_flags
        ))
    }

    fn flush(&self, ctx: &Context, ino: u64, handle: u64, lock_owner: u64) -> io::Result<()> {
        by_layer!(self, ino, |fs, i| fs.flush(ctx, i, handle, lock_owner))
    }

    fn fsync(&self, ctx: &Context, ino: u64, datasync: bool, handle: u64) -> io::Result<()> {
        by_layer!(self, ino, |fs, i| fs.fsync(ctx, i, datasync, handle))
    }

    fn fallocate(
        &self,
        ctx: &Context,
        ino: u64,
        handle: u64,
        mode: u32,
        offset: u64,
        length: u64,
    ) -> io::Result<()> {
        upper_only!(self, ino, |fs| fs
            .fallocate(ctx, ino, handle, mode, offset, length))
    }

    fn release(
        &self,
        ctx: &Context,
        ino: u64,
        flags: u32,
        handle: u64,
        flush: bool,
        flock_release: bool,
        lock_owner: Option<u64>,
    ) -> io::Result<()> {
        by_layer!(self, ino, |fs, i| fs.release(
            ctx,
            i,
            flags,
            handle,
            flush,
            flock_release,
            lock_owner
        ))
    }

    fn statfs(&self, ctx: &Context, _ino: u64) -> io::Result<statvfs64> {
        self.upper.statfs(ctx, ROOT_ID)
    }

    fn setxattr(
        &self,
        ctx: &Context,
        ino: u64,
        name: &CStr,
        value: &[u8],
        flags: u32,
    ) -> io::Result<()> {
        upper_only!(self, ino, |fs| fs.setxattr(ctx, ino, name, value, flags))
    }

    fn getxattr(
        &self,
        ctx: &Context,
        ino: u64,
        name: &CStr,
        size: u32,
    ) -> io::Result<GetxattrReply> {
        by_layer!(self, ino, |fs, i| fs.getxattr(ctx, i, name, size))
    }

    fn listxattr(&self, ctx: &Context, ino: u64, size: u32) -> io::Result<ListxattrReply> {
        by_layer!(self, ino, |fs, i| fs.listxattr(ctx, i, size))
    }

    fn removexattr(&self, ctx: &Context, ino: u64, name: &CStr) -> io::Result<()> {
        upper_only!(self, ino, |fs| fs.removexattr(ctx, ino, name))
    }

    fn opendir(
        &self,
        ctx: &Context,
        ino: u64,
        flags: u32,
    ) -> io::Result<(Option<u64>, OpenOptions)> {
        if ino == ROOT_ID {
            let h = self.next_root_handle.fetch_add(1, Ordering::Relaxed);
            let l = Arc::new(self.root_listing()?);
            self.root_dirs.lock().unwrap().insert(h, l);
            return Ok((Some(h), OpenOptions::empty()));
        }
        by_layer!(self, ino, |fs, i| fs.opendir(ctx, i, flags))
    }

    fn readdir(
        &self,
        ctx: &Context,
        ino: u64,
        handle: u64,
        size: u32,
        offset: u64,
        add_entry: &mut dyn FnMut(DirEntry) -> io::Result<usize>,
    ) -> io::Result<()> {
        if ino == ROOT_ID {
            let l = self
                .root_dirs
                .lock()
                .unwrap()
                .get(&handle)
                .cloned()
                .ok_or_else(|| err(libc::EBADF))?;
            for (i, e) in l.iter().enumerate().skip(offset as usize) {
                let n = add_entry(DirEntry {
                    ino: e.ino,
                    offset: i as u64 + 1,
                    type_: e.type_,
                    name: &e.name,
                })?;
                if n == 0 {
                    break;
                }
            }
            return Ok(());
        }
        by_layer!(self, ino, |fs, i| fs
            .readdir(ctx, i, handle, size, offset, add_entry))
    }

    fn fsyncdir(&self, ctx: &Context, ino: u64, datasync: bool, handle: u64) -> io::Result<()> {
        if ino == ROOT_ID {
            return std::fs::File::open(&self.upper_dir)?.sync_all();
        }
        by_layer!(self, ino, |fs, i| fs.fsyncdir(ctx, i, datasync, handle))
    }

    fn releasedir(&self, ctx: &Context, ino: u64, flags: u32, handle: u64) -> io::Result<()> {
        if ino == ROOT_ID {
            self.root_dirs.lock().unwrap().remove(&handle);
            return Ok(());
        }
        by_layer!(self, ino, |fs, i| fs.releasedir(ctx, i, flags, handle))
    }

    fn access(&self, ctx: &Context, ino: u64, mask: u32) -> io::Result<()> {
        by_layer!(self, ino, |fs, i| fs.access(ctx, i, mask))
    }

    fn lseek(
        &self,
        ctx: &Context,
        ino: u64,
        handle: u64,
        offset: u64,
        whence: u32,
    ) -> io::Result<u64> {
        by_layer!(self, ino, |fs, i| fs.lseek(ctx, i, handle, offset, whence))
    }

    fn copy_file_range(
        &self,
        ctx: &Context,
        inode_in: u64,
        fh_in: u64,
        offset_in: u64,
        inode_out: u64,
        fh_out: u64,
        offset_out: u64,
        len: u64,
        flags: u64,
    ) -> io::Result<u32> {
        if is_lower(inode_in) || is_lower(inode_out) {
            // makes the caller fall back to read/write
            return Err(err(libc::EXDEV));
        }
        self.upper.copy_file_range(
            ctx, inode_in, fh_in, offset_in, inode_out, fh_out, offset_out, len, flags,
        )
    }
}
