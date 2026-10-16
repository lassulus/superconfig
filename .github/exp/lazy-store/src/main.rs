//! Lazy nix store for .github/exp/lazy-fuse.sh.
//!
//!   closure OUT DRV...      collect what building DRVs needs from the caches
//!                           (the wanted outputs of their input derivations
//!                           plus their own outputs, and the closure of all
//!                           that) by fetching only narinfos. Writes
//!                           OUT/paths.json (per path: cache, NAR url,
//!                           compression, hash), OUT/db.dump (input for
//!                           `nix-store --load-db`) and OUT/closure.json.
//!   fetch OUT NAME...       fetch store paths of OUT/paths.json like the
//!                           first open() would, and check them against
//!                           their listing (testing without FUSE)
//!   mount OUT UPPER MNT     mount the store dir UPPER, merged with the paths
//!                           of OUT/paths.json, at MNT (see storefs.rs).
//!                           Stats go to OUT/stats.json.
//!     [--workers N]         FUSE worker threads (default 64)
//!     [--no-passthrough]    don't use kernel FUSE passthrough

mod closure;
mod http;
mod lazy;
mod nar;
mod stats;
mod storefs;

use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use fuse_backend_rs::api::server::Server;
use fuse_backend_rs::passthrough::{self, BackingFiles, PassthroughFs};
use fuse_backend_rs::transport::{
    fuse_backing_close, fuse_backing_open, FuseServing, FuseSession, SyncFuseServing,
    SyncServingConfig,
};

pub const STORE: &str = "/nix/store/";

/// Registers backing files for kernel FUSE passthrough on the session's
/// /dev/fuse fd, which only exists once mounted.
#[derive(Default)]
pub struct Backing(OnceLock<File>);

impl Backing {
    pub fn open_fd(&self, fd: RawFd) -> io::Result<u32> {
        let f = self
            .0
            .get()
            .ok_or_else(|| io::Error::from_raw_os_error(libc::ENODEV))?;
        fuse_backing_open(f, fd)
    }

    pub fn close_id(&self, id: u32) {
        if let Some(f) = self.0.get() {
            if let Err(e) = fuse_backing_close(f, id) {
                eprintln!("closing backing id {id}: {e}");
            }
        }
    }
}

struct SharedBacking(Arc<Backing>);

impl BackingFiles for SharedBacking {
    fn open(&self, fd: BorrowedFd<'_>) -> io::Result<u32> {
        self.0.open_fd(fd.as_raw_fd())
    }

    fn close(&self, id: u32) -> io::Result<()> {
        let f = self
            .0
             .0
            .get()
            .ok_or_else(|| io::Error::from_raw_os_error(libc::ENODEV))?;
        fuse_backing_close(f, id)
    }
}

/// fuse-backend-rs logs through `log`: warnings and errors to stderr.
struct Logger;

impl log::Log for Logger {
    fn enabled(&self, m: &log::Metadata) -> bool {
        m.level() <= log::Level::Warn
    }

    fn log(&self, r: &log::Record) {
        if self.enabled(r.metadata()) {
            eprintln!("{} {}: {}", r.level(), r.target(), r.args());
        }
    }

    fn flush(&self) {}
}

fn mount(
    outdir: &Path,
    upper: &Path,
    mnt: &Path,
    workers: usize,
    use_passthrough: bool,
) -> io::Result<()> {
    let backing = use_passthrough.then(|| Arc::new(Backing::default()));
    let lower = lazy::LazyFs::new(outdir, backing.clone())?;

    let upper_fs = {
        let cfg = passthrough::Config {
            root_dir: upper
                .to_str()
                .ok_or_else(|| io::Error::other("non-UTF-8 upper dir"))?
                .into(),
            do_import: true,
            xattr: false,
            ..Default::default()
        };
        let mut fs = PassthroughFs::<()>::new(cfg)?;
        if let Some(b) = &backing {
            fs.set_backing_files(Arc::new(SharedBacking(b.clone())));
        }
        fs
    };
    let stats = lower.stats.clone();
    let fs = storefs::StoreFs::new(upper_fs, upper.to_path_buf(), lower);

    let mut se = FuseSession::new(mnt, "lazystore", "", false).map_err(io::Error::other)?;
    se.mount().map_err(io::Error::other)?;
    if let Some(b) = &backing {
        let f = se
            .get_fuse_file()
            .ok_or_else(|| io::Error::other("no fuse fd"))?
            .try_clone()?;
        let _ = b.0.set(f);
    }
    let server = Arc::new(Server::new(fs));
    let serving = SyncFuseServing::new(
        se,
        server,
        SyncServingConfig {
            workers,
            blocking: true,
        },
    )
    .map_err(io::Error::other)?;
    eprintln!(
        "mounted {} on {} ({workers} workers)",
        upper.display(),
        mnt.display()
    );
    serving.wait();
    stats.save();
    eprintln!("FUSE main loop exited");
    Ok(())
}

fn usage() -> ! {
    eprintln!(
        "usage: lazy-store closure OUT DRV... | fetch OUT NAME... | mount OUT UPPER MNT [--workers N] [--no-passthrough]"
    );
    std::process::exit(2)
}

fn main() {
    let _ = log::set_logger(&Logger).map(|_| log::set_max_level(log::LevelFilter::Warn));
    let args: Vec<String> = std::env::args().skip(1).collect();
    let r = match args.first().map(String::as_str) {
        Some("closure") if args.len() >= 3 => closure::closure(Path::new(&args[1]), &args[2..]),
        Some("fetch") if args.len() >= 3 => {
            lazy::LazyFs::new(Path::new(&args[1]), None).and_then(|fs| {
                for name in &args[2..] {
                    println!("{}", fs.fetch_and_check(name)?.display());
                }
                Ok(())
            })
        }
        Some("mount") if args.len() >= 4 => {
            let (mut workers, mut pt) = (64, true);
            let mut rest = args[4..].iter();
            while let Some(a) = rest.next() {
                match a.as_str() {
                    "--workers" => {
                        workers = rest
                            .next()
                            .and_then(|n| n.parse().ok())
                            .unwrap_or_else(|| usage())
                    }
                    "--no-passthrough" => pt = false,
                    _ => usage(),
                }
            }
            mount(
                &PathBuf::from(&args[1]),
                Path::new(&args[2]),
                Path::new(&args[3]),
                workers,
                pt,
            )
        }
        _ => usage(),
    };
    if let Err(e) = r {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
