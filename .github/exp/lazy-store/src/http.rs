//! Binary cache access: GET with retries, and body decoding.

use std::collections::HashMap;
use std::io::{self, Read};
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Mutex;
use std::thread::sleep;
use std::time::Duration;

const TRIES: u32 = 6;

/// Resolves each host once and then serves it from memory. Once the FUSE
/// file system is mounted on /nix/store, getaddrinfo() could end up looking
/// for NSS modules in the store, i.e. in a request to ourselves.
struct Resolver(Mutex<HashMap<String, Vec<SocketAddr>>>);

impl ureq::Resolver for Resolver {
    fn resolve(&self, netloc: &str) -> io::Result<Vec<SocketAddr>> {
        if let Some(a) = self.0.lock().unwrap().get(netloc) {
            return Ok(a.clone());
        }
        let a: Vec<SocketAddr> = netloc.to_socket_addrs()?.collect();
        self.0.lock().unwrap().insert(netloc.to_string(), a.clone());
        Ok(a)
    }
}

pub struct Http {
    agent: ureq::Agent,
}

pub enum Error {
    /// 403/404, or a missing file for file:// caches
    NotFound,
    Other(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NotFound => write!(f, "not found"),
            Error::Other(e) => write!(f, "{e}"),
        }
    }
}

impl From<Error> for io::Error {
    fn from(e: Error) -> io::Error {
        io::Error::other(e.to_string())
    }
}

impl Http {
    /// `caches` are base URLs; their hosts are resolved right away.
    pub fn new<'a>(caches: impl IntoIterator<Item = &'a str>) -> Http {
        let mut known = HashMap::new();
        for c in caches {
            let Some(rest) = c
                .strip_prefix("https://")
                .or_else(|| c.strip_prefix("http://"))
            else {
                continue;
            };
            let host = rest.split('/').next().unwrap_or(rest);
            let port = if c.starts_with("https:") { 443 } else { 80 };
            let netloc = if host.contains(':') {
                host.to_string()
            } else {
                format!("{host}:{port}")
            };
            match netloc.to_socket_addrs() {
                Ok(a) => {
                    known.insert(netloc, a.collect());
                }
                Err(e) => eprintln!("resolving {netloc}: {e}"),
            }
        }
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(30))
            .timeout_read(Duration::from_secs(60))
            .max_idle_connections_per_host(64)
            .resolver(Resolver(Mutex::new(known)))
            .build();
        Http { agent }
    }

    /// GET `url`, retrying 429/5xx and transport errors with backoff (the
    /// caches answer 503 under load). Returns the body reader and its
    /// Content-Encoding.
    pub fn open(&self, url: &str) -> Result<(Box<dyn Read + Send>, Option<String>), Error> {
        if let Some(path) = url.strip_prefix("file://") {
            return match std::fs::File::open(path) {
                Ok(f) => Ok((Box::new(f), None)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Err(Error::NotFound),
                Err(e) => Err(Error::Other(format!("{url}: {e}"))),
            };
        }
        let mut n = 0;
        loop {
            let err = match self.agent.get(url).call() {
                Ok(r) => {
                    let enc = r.header("content-encoding").map(str::to_string);
                    return Ok((Box::new(r.into_reader()), enc));
                }
                Err(ureq::Error::Status(403 | 404, _)) => return Err(Error::NotFound),
                Err(ureq::Error::Status(code, _)) if code != 429 && code < 500 => {
                    return Err(Error::Other(format!("{url}: HTTP {code}")))
                }
                Err(ureq::Error::Status(code, _)) => format!("HTTP {code}"),
                Err(e) => e.to_string(),
            };
            n += 1;
            if n == TRIES {
                return Err(Error::Other(format!("{url}: {err}")));
            }
            eprintln!("retry {n}/{} {url}: {err}", TRIES - 1);
            sleep(Duration::from_secs((1u64 << (n - 1)).min(30)));
        }
    }

    /// GET `url` -> decoded body. Transfer errors while reading the body are
    /// retried like failed requests.
    pub fn get(&self, url: &str) -> Result<(Vec<u8>, usize), Error> {
        let mut n = 0;
        loop {
            let (mut r, enc) = self.open(url)?;
            let mut body = Vec::new();
            match r.read_to_end(&mut body) {
                Ok(_) => {
                    let len = body.len();
                    let dec = decode(&body, enc.as_deref())
                        .map_err(|e| Error::Other(format!("{url}: decoding: {e}")))?;
                    return Ok((dec, len));
                }
                Err(e) => {
                    n += 1;
                    if n == TRIES {
                        return Err(Error::Other(format!("{url}: {e}")));
                    }
                    eprintln!("retry {n}/{} {url}: {e}", TRIES - 1);
                    sleep(Duration::from_secs((1u64 << (n - 1)).min(30)));
                }
            }
        }
    }
}

/// Wrap `r` in a decompressor for `method` (narinfo Compression or
/// Content-Encoding).
pub fn decoder<'a>(
    method: &str,
    r: impl Read + Send + 'a,
) -> io::Result<Box<dyn Read + Send + 'a>> {
    Ok(match method {
        "" | "none" | "identity" => Box::new(r),
        "zstd" => Box::new(zstd::stream::read::Decoder::new(r)?),
        "xz" => Box::new(xz2::read::XzDecoder::new_multi_decoder(r)),
        "bzip2" => Box::new(bzip2::read::MultiBzDecoder::new(r)),
        "gzip" => Box::new(flate2::read::MultiGzDecoder::new(r)),
        "br" => Box::new(brotli_decompressor::Decompressor::new(r, 1 << 16)),
        m => return Err(io::Error::other(format!("unknown compression {m:?}"))),
    })
}

const MAGIC: &[(&[u8], &str)] = &[
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x1f\x8b", "gzip"),
];

/// Both caches store narinfo/.ls zstd-compressed (Content-Encoding), but the
/// CDN sometimes serves them without that header: sniff the magic too.
pub fn decode(body: &[u8], encoding: Option<&str>) -> io::Result<Vec<u8>> {
    let enc = match encoding {
        None | Some("") | Some("identity") => {
            match MAGIC.iter().find(|(m, _)| body.starts_with(m)) {
                Some((_, t)) => *t,
                None => return Ok(body.to_vec()),
            }
        }
        Some(e) => e,
    };
    let mut out = Vec::new();
    decoder(enc, body)?.read_to_end(&mut out)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_sniffs_zstd() {
        let z = zstd::encode_all(&b"{\"root\":1}"[..], 3).unwrap();
        assert_eq!(decode(&z, None).unwrap(), b"{\"root\":1}");
        assert_eq!(decode(&z, Some("zstd")).unwrap(), b"{\"root\":1}");
        assert_eq!(decode(b"plain", None).unwrap(), b"plain");
    }
}
