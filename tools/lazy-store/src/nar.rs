//! NAR unpacking and store path listings.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;

use futures_util::TryStreamExt;
use harmonia_file_core::{Directory, FileSystemObject, FileTree, Regular, Symlink};
use harmonia_file_nar::{parse_nar, restore, NarWriteError};
use harmonia_utils_hash::{fmt::Any, Algorithm, Context, Hash};
use serde::Deserialize;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio_util::io::InspectReader;

/// Does `actual` match a narinfo NarHash (`sha256:` in any encoding)?
pub fn hash_matches(expected: &str, actual: &Hash) -> bool {
    expected
        .parse::<Any<Hash>>()
        .is_ok_and(|e| e.into_hash() == *actual)
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Size {
    pub size: u64,
}

/// The metadata of a store path, as in the caches' `.ls` listings.
pub type Tree = FileTree<Size>;

/// Parse a `.ls` listing (`{"version": 1, "root": {...}}`). Empty
/// directories may come without `entries`.
pub fn from_listing(body: &[u8]) -> io::Result<Tree> {
    fn fill(v: &mut serde_json::Value) {
        if v["type"] == "directory" {
            match v.get_mut("entries").and_then(|e| e.as_object_mut()) {
                Some(e) => e.values_mut().for_each(fill),
                None => v["entries"] = serde_json::json!({}),
            }
        }
    }
    let mut v: serde_json::Value = serde_json::from_slice(body).map_err(io::Error::other)?;
    let mut root = v["root"].take();
    fill(&mut root);
    serde_json::from_value(root).map_err(io::Error::other)
}

/// Listing of an unpacked store path (for paths without `.ls`).
pub fn from_path(p: &Path) -> io::Result<Tree> {
    let m = fs::symlink_metadata(p)?;
    let t = m.file_type();
    Ok(FileTree(if t.is_dir() {
        let mut entries = BTreeMap::new();
        for d in fs::read_dir(p)? {
            let d = d?;
            let name = d.file_name().into_string().map_err(|n| {
                io::Error::other(format!("non-UTF-8 name {n:?} in {}", p.display()))
            })?;
            entries.insert(name, Box::new(from_path(&d.path())?));
        }
        FileSystemObject::Directory(Directory { entries })
    } else if t.is_symlink() {
        let target = fs::read_link(p)?.to_string_lossy().into_owned();
        FileSystemObject::Symlink(Symlink { target })
    } else {
        FileSystemObject::Regular(Regular {
            executable: m.mode() & 0o100 != 0,
            contents: Size { size: m.size() },
        })
    }))
}

/// Unpack the NAR read from `r` to `dest` (which must not exist), read-only
/// like in the store. Returns the NAR's sha256 and size; checking them is
/// up to the caller. Data after the NAR counts into the size.
pub async fn unpack(r: impl AsyncRead + Unpin + Send, dest: &Path) -> io::Result<(Hash, u64)> {
    let mut hash = Context::new(Algorithm::SHA256);
    let mut size = 0;
    let mut r = InspectReader::new(r, |b: &[u8]| {
        hash.update(b);
        size += b.len() as u64;
    });
    let events =
        parse_nar(&mut r).map_err(|e| NarWriteError::create_file_error(dest.to_owned(), e));
    restore(events, dest).await.map_err(io::Error::other)?;
    r.read(&mut [0; 1]).await?;
    drop(r);
    let d = dest.to_owned();
    tokio::task::spawn_blocking(move || read_only(&d))
        .await
        .map_err(io::Error::other)??;
    Ok((hash.finish(), size))
}

/// Store permissions: 0444 or 0555 for files, 0555 for directories.
fn read_only(p: &Path) -> io::Result<()> {
    let m = fs::symlink_metadata(p)?;
    let mode = if m.is_symlink() {
        return Ok(());
    } else if m.is_dir() {
        for d in fs::read_dir(p)? {
            read_only(&d?.path())?;
        }
        0o555
    } else if m.mode() & 0o100 != 0 {
        0o555
    } else {
        0o444
    };
    fs::set_permissions(p, fs::Permissions::from_mode(mode))
}

/// Remove a (partially) unpacked tree, including read-only directories.
pub fn remove(p: &Path) -> io::Result<()> {
    let m = match fs::symlink_metadata(p) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    if m.is_dir() {
        fs::set_permissions(p, fs::Permissions::from_mode(0o755))?;
        for d in fs::read_dir(p)? {
            remove(&d?.path())?;
        }
        fs::remove_dir(p)
    } else {
        fs::remove_file(p)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_matches_nix() {
        // nix hash convert --to nix32 sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        let d = Algorithm::SHA256.digest(b"");
        assert!(hash_matches(
            "sha256:0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73",
            &d
        ));
        assert!(hash_matches(
            "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            &d
        ));
        assert!(!hash_matches(
            "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73",
            &d
        ));
    }

    #[tokio::test]
    async fn unpack_and_list() {
        let tmp = std::env::temp_dir().join(format!("lazy-store-test-{}", std::process::id()));
        let (src, dir) = (tmp.join("src"), tmp.join("out"));
        let _ = remove(&tmp);
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("bin"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(src.join("bin"), fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::symlink("bin", src.join("link")).unwrap();
        let data: Vec<u8> = harmonia_file_nar::NarByteStream::new(src.clone())
            .try_collect::<Vec<_>>()
            .await
            .unwrap()
            .concat();

        let (h, n) = unpack(&data[..], &dir).await.unwrap();
        assert_eq!(n, data.len() as u64);
        assert_eq!(h, Algorithm::SHA256.digest(&data));
        assert_eq!(fs::metadata(dir.join("bin")).unwrap().mode() & 0o777, 0o555);
        assert_eq!(fs::metadata(&dir).unwrap().mode() & 0o777, 0o555);
        let t = from_path(&dir).unwrap();
        let ls = br#"{"version":1,"root":{"type":"directory","entries":{
            "bin":{"type":"regular","size":10,"executable":true,"narOffset":96},
            "link":{"type":"symlink","target":"bin"}}}}"#;
        assert_eq!(from_listing(ls).unwrap(), t);
        remove(&dir).unwrap();

        // as cache.lassul.us serves empty directories
        let ls = br#"{"version":1,"root":{"type":"directory","entries":{
            "empty":{"type":"directory"}}}}"#;
        fs::create_dir_all(dir.join("empty")).unwrap();
        assert_eq!(from_listing(ls).unwrap(), from_path(&dir).unwrap());
        assert_eq!(
            from_listing(br#"{"version":1,"root":{"type":"directory"}}"#).unwrap(),
            FileTree(FileSystemObject::Directory(Directory {
                entries: BTreeMap::new()
            }))
        );
        remove(&dir).unwrap();

        // the caller's NarSize check rejects it
        let mut trailing = data.clone();
        trailing.push(0);
        let (_, n) = unpack(&trailing[..], &dir).await.unwrap();
        assert_eq!(n, trailing.len() as u64);
        remove(&tmp).unwrap();
    }
}
