//! NAR unpacking and store path listings.

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::Path;

use sha2::{Digest, Sha256};

const NIX32: &[u8] = b"0123456789abcdfghijklmnpqrsvwxyz";

pub fn nix32(b: &[u8]) -> String {
    let n = (b.len() * 8 - 1) / 5 + 1;
    (0..n)
        .rev()
        .map(|i| {
            let bit = i * 5;
            let (j, k) = (bit / 8, bit % 8);
            let mut c = (b[j] as u32) >> k;
            if j + 1 < b.len() {
                c |= (b[j + 1] as u32) << (8 - k);
            }
            NIX32[(c & 0x1f) as usize] as char
        })
        .collect()
}

/// Does `digest` match a narinfo NarHash (`sha256:<nix32>` or base16)?
pub fn hash_matches(expected: &str, digest: &[u8]) -> bool {
    let Some(h) = expected.strip_prefix("sha256:") else {
        return false;
    };
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    h == nix32(digest) || h == hex
}

/// The metadata of a store path, as in the caches' `.ls` listings.
#[derive(Debug, Clone, PartialEq)]
pub enum Tree {
    Dir(BTreeMap<String, Tree>),
    File { size: u64, exec: bool },
    Symlink(String),
}

impl Tree {
    /// Parse a `.ls` listing (`{"version": 1, "root": {...}}`).
    pub fn from_listing(body: &[u8]) -> io::Result<Tree> {
        let v: serde_json::Value = serde_json::from_slice(body).map_err(io::Error::other)?;
        Tree::from_json(&v["root"])
    }

    fn from_json(v: &serde_json::Value) -> io::Result<Tree> {
        let bad = || io::Error::other(format!("bad listing node {v}"));
        Ok(match v["type"].as_str().ok_or_else(bad)? {
            "directory" => {
                let mut m = BTreeMap::new();
                if let Some(e) = v["entries"].as_object() {
                    for (k, c) in e {
                        m.insert(k.clone(), Tree::from_json(c)?);
                    }
                }
                Tree::Dir(m)
            }
            "regular" => Tree::File {
                size: v["size"].as_u64().unwrap_or(0),
                exec: v["executable"].as_bool().unwrap_or(false),
            },
            "symlink" => Tree::Symlink(v["target"].as_str().ok_or_else(bad)?.to_string()),
            _ => return Err(bad()),
        })
    }

    /// Listing of an unpacked store path (for paths without `.ls`).
    pub fn from_path(p: &Path) -> io::Result<Tree> {
        let m = fs::symlink_metadata(p)?;
        let t = m.file_type();
        Ok(if t.is_dir() {
            let mut e = BTreeMap::new();
            for d in fs::read_dir(p)? {
                let d = d?;
                let name = d.file_name().into_string().map_err(|n| {
                    io::Error::other(format!("non-UTF-8 name {n:?} in {}", p.display()))
                })?;
                e.insert(name, Tree::from_path(&d.path())?);
            }
            Tree::Dir(e)
        } else if t.is_symlink() {
            Tree::Symlink(fs::read_link(p)?.to_string_lossy().into_owned())
        } else {
            Tree::File {
                size: m.size(),
                exec: m.mode() & 0o100 != 0,
            }
        })
    }
}

/// Reads through to `inner`, hashing and counting what passes.
pub struct HashingReader<R> {
    inner: R,
    pub hasher: Sha256,
    pub n: u64,
}

impl<R: Read> Read for HashingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hasher.update(&buf[..n]);
        self.n += n as u64;
        Ok(n)
    }
}

/// Counts the bytes read from `inner` (the compressed download size).
pub struct CountingReader<R> {
    pub inner: R,
    pub n: u64,
}

impl<R: Read> Read for CountingReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.n += n as u64;
        Ok(n)
    }
}

fn bad(msg: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("NAR: {}", msg.into()))
}

struct Nar<R> {
    r: HashingReader<R>,
}

impl<R: Read> Nar<R> {
    fn int(&mut self) -> io::Result<u64> {
        let mut b = [0u8; 8];
        self.r.read_exact(&mut b)?;
        Ok(u64::from_le_bytes(b))
    }

    fn pad(&mut self, n: u64) -> io::Result<()> {
        let p = ((8 - n % 8) % 8) as usize;
        let mut b = [0u8; 8];
        self.r.read_exact(&mut b[..p])?;
        if b[..p].iter().any(|&x| x != 0) {
            return Err(bad("non-zero padding"));
        }
        Ok(())
    }

    fn str(&mut self, limit: u64) -> io::Result<Vec<u8>> {
        let n = self.int()?;
        if n > limit {
            return Err(bad("string too long"));
        }
        let mut s = vec![0u8; n as usize];
        self.r.read_exact(&mut s)?;
        self.pad(n)?;
        Ok(s)
    }

    fn expect(&mut self, s: &[u8]) -> io::Result<()> {
        let got = self.str(4096)?;
        if got != s {
            return Err(bad(format!(
                "expected {:?}, got {:?}",
                String::from_utf8_lossy(s),
                String::from_utf8_lossy(&got)
            )));
        }
        Ok(())
    }

    fn node(&mut self, dest: &Path) -> io::Result<()> {
        self.expect(b"(")?;
        self.expect(b"type")?;
        match &self.str(4096)?[..] {
            b"regular" => {
                let mut tag = self.str(4096)?;
                let mut mode = 0o444;
                if tag == b"executable" {
                    self.expect(b"")?;
                    tag = self.str(4096)?;
                    mode = 0o555;
                }
                if tag != b"contents" {
                    return Err(bad("expected contents"));
                }
                let n = self.int()?;
                let mut out = io::BufWriter::with_capacity(1 << 20, fs::File::create(dest)?);
                let copied = io::copy(&mut (&mut self.r).take(n), &mut out)?;
                if copied != n {
                    return Err(bad("short file contents"));
                }
                out.flush()?;
                self.pad(n)?;
                fs::set_permissions(dest, fs::Permissions::from_mode(mode))?;
                self.expect(b")")?;
            }
            b"symlink" => {
                self.expect(b"target")?;
                let t = self.str(4096)?;
                symlink(std::ffi::OsStr::from_bytes(&t), dest)?;
                self.expect(b")")?;
            }
            b"directory" => {
                fs::create_dir(dest)?;
                loop {
                    let tag = self.str(4096)?;
                    if tag == b")" {
                        break;
                    }
                    if tag != b"entry" {
                        return Err(bad("expected entry"));
                    }
                    self.expect(b"(")?;
                    self.expect(b"name")?;
                    let name = self.str(255)?;
                    if name.is_empty() || name == b"." || name == b".." || name.contains(&b'/') {
                        return Err(bad("bad entry name"));
                    }
                    self.expect(b"node")?;
                    let name = String::from_utf8(name).map_err(|_| bad("non-UTF-8 name"))?;
                    self.node(&dest.join(name))?;
                    self.expect(b")")?;
                }
                fs::set_permissions(dest, fs::Permissions::from_mode(0o555))?;
            }
            t => {
                return Err(bad(format!(
                    "unknown type {:?}",
                    String::from_utf8_lossy(t)
                )))
            }
        }
        Ok(())
    }
}

/// Unpack the NAR read from `r` to `dest` (which must not exist). Returns
/// the NAR's sha256 and size; checking them is up to the caller. Fails if
/// anything follows the NAR.
pub fn unpack(r: impl Read, dest: &Path) -> io::Result<(Vec<u8>, u64)> {
    let mut nar = Nar {
        r: HashingReader {
            inner: r,
            hasher: Sha256::new(),
            n: 0,
        },
    };
    nar.expect(b"nix-archive-1")?;
    nar.node(dest)?;
    let mut rest = [0u8; 1];
    if nar.r.inner.read(&mut rest)? != 0 {
        return Err(bad("trailing data"));
    }
    let n = nar.r.n;
    Ok((nar.r.hasher.finalize().to_vec(), n))
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

    fn s(out: &mut Vec<u8>, b: &[u8]) {
        out.extend_from_slice(&(b.len() as u64).to_le_bytes());
        out.extend_from_slice(b);
        out.resize(out.len() + (8 - b.len() % 8) % 8, 0);
    }

    fn nar() -> Vec<u8> {
        let mut o = Vec::new();
        for t in [&b"nix-archive-1"[..], b"(", b"type", b"directory"] {
            s(&mut o, t);
        }
        for t in [&b"entry"[..], b"(", b"name", b"bin", b"node", b"("] {
            s(&mut o, t);
        }
        for t in [
            &b"type"[..],
            b"regular",
            b"executable",
            b"",
            b"contents",
            b"#!/bin/sh\n",
        ] {
            s(&mut o, t);
        }
        for t in [&b")"[..], b")"] {
            s(&mut o, t);
        }
        for t in [&b"entry"[..], b"(", b"name", b"link", b"node", b"("] {
            s(&mut o, t);
        }
        for t in [
            &b"type"[..],
            b"symlink",
            b"target",
            b"bin",
            b")",
            b")",
            b")",
        ] {
            s(&mut o, t);
        }
        o
    }

    #[test]
    fn nix32_matches_nix() {
        // nix hash convert --to nix32 sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        let d = Sha256::digest(b"");
        assert_eq!(
            nix32(&d),
            "0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73"
        );
    }

    #[test]
    fn unpack_and_list() {
        let dir = std::env::temp_dir().join(format!("lazy-store-test-{}", std::process::id()));
        let _ = remove(&dir);
        let data = nar();
        let (h, n) = unpack(&data[..], &dir).unwrap();
        assert_eq!(n, data.len() as u64);
        assert_eq!(h, Sha256::digest(&data).to_vec());
        let t = Tree::from_path(&dir).unwrap();
        let mut e = BTreeMap::new();
        e.insert(
            "bin".into(),
            Tree::File {
                size: 10,
                exec: true,
            },
        );
        e.insert("link".into(), Tree::Symlink("bin".into()));
        assert_eq!(t, Tree::Dir(e));
        let ls = br#"{"version":1,"root":{"type":"directory","entries":{
            "bin":{"type":"regular","size":10,"executable":true,"narOffset":96},
            "link":{"type":"symlink","target":"bin"}}}}"#;
        assert_eq!(Tree::from_listing(ls).unwrap(), t);
        remove(&dir).unwrap();

        let mut trailing = data.clone();
        trailing.push(0);
        assert!(unpack(&trailing[..], &dir).is_err());
        remove(&dir).unwrap();
    }
}
