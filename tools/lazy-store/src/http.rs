//! Binary cache access: GET with retries, and body decoding.

use std::io;
use std::pin::Pin;
use std::time::Duration;

use async_compression::tokio::bufread::{
    BrotliDecoder, BzDecoder, GzipDecoder, XzDecoder, ZstdDecoder,
};
use futures_util::TryStreamExt;
use tokio::io::{AsyncBufRead, AsyncRead, AsyncReadExt, BufReader};
use tokio::time::sleep;
use tokio_util::io::StreamReader;

const TRIES: u32 = 6;

pub type Body = Pin<Box<dyn AsyncRead + Send>>;

pub struct Http {
    client: reqwest::Client,
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
    /// `caches` are base URLs. Their hosts are resolved right away and then
    /// served from memory: once the FUSE file system is mounted on
    /// /nix/store, getaddrinfo() could end up looking for NSS modules in
    /// the store, i.e. in a request to ourselves.
    pub async fn new<'a>(caches: impl IntoIterator<Item = &'a str>) -> Http {
        // rustls with bundled roots: nothing read from /etc/ssl or the store
        let roots = webpki_root_certs::TLS_SERVER_ROOT_CERTS
            .iter()
            .filter_map(|c| reqwest::Certificate::from_der(c).ok());
        let mut b = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(30))
            .read_timeout(Duration::from_secs(60))
            .pool_max_idle_per_host(64)
            .tls_certs_only(roots);
        for c in caches {
            let Ok(u) = reqwest::Url::parse(c) else {
                continue;
            };
            let (Some(host), Some(port)) = (u.host_str(), u.port_or_known_default()) else {
                continue;
            };
            match tokio::net::lookup_host((host, port)).await {
                Ok(a) => b = b.resolve_to_addrs(host, &a.collect::<Vec<_>>()),
                Err(e) => eprintln!("resolving {host}:{port}: {e}"),
            };
        }
        Http {
            client: b.build().expect("building the HTTP client"),
        }
    }

    /// GET `url`, retrying 429/5xx and transport errors with backoff (the
    /// caches answer 503 under load). Returns the body reader and its
    /// Content-Encoding.
    pub async fn open(&self, url: &str) -> Result<(Body, Option<String>), Error> {
        if let Some(path) = url.strip_prefix("file://") {
            return match tokio::fs::File::open(path).await {
                Ok(f) => Ok((Box::pin(f), None)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Err(Error::NotFound),
                Err(e) => Err(Error::Other(format!("{url}: {e}"))),
            };
        }
        let mut n = 0;
        loop {
            let err = match self.client.get(url).send().await {
                Ok(r) if r.status().is_success() => {
                    let enc = r
                        .headers()
                        .get("content-encoding")
                        .and_then(|v| v.to_str().ok())
                        .map(str::to_string);
                    let body = r.bytes_stream().map_err(io::Error::other);
                    return Ok((Box::pin(StreamReader::new(body)), enc));
                }
                Ok(r) => match r.status().as_u16() {
                    403 | 404 => return Err(Error::NotFound),
                    code if code != 429 && code < 500 => {
                        return Err(Error::Other(format!("{url}: HTTP {code}")))
                    }
                    code => format!("HTTP {code}"),
                },
                Err(e) => e.to_string(),
            };
            n += 1;
            if n == TRIES {
                return Err(Error::Other(format!("{url}: {err}")));
            }
            eprintln!("retry {n}/{} {url}: {err}", TRIES - 1);
            sleep(Duration::from_secs((1u64 << (n - 1)).min(30))).await;
        }
    }

    /// GET `url` -> decoded body. Transfer errors while reading the body are
    /// retried like failed requests.
    pub async fn get(&self, url: &str) -> Result<(Vec<u8>, usize), Error> {
        let mut n = 0;
        loop {
            let (mut r, enc) = self.open(url).await?;
            let mut body = Vec::new();
            match r.read_to_end(&mut body).await {
                Ok(_) => {
                    let len = body.len();
                    let dec = decode(&body, enc.as_deref())
                        .await
                        .map_err(|e| Error::Other(format!("{url}: decoding: {e}")))?;
                    return Ok((dec, len));
                }
                Err(e) => {
                    n += 1;
                    if n == TRIES {
                        return Err(Error::Other(format!("{url}: {e}")));
                    }
                    eprintln!("retry {n}/{} {url}: {e}", TRIES - 1);
                    sleep(Duration::from_secs((1u64 << (n - 1)).min(30))).await;
                }
            }
        }
    }
}

/// Wrap `r` in a decompressor for `method` (narinfo Compression or
/// Content-Encoding). Concatenated streams are decoded as one, like Nix.
pub fn decoder<'a>(
    method: &str,
    r: impl AsyncBufRead + Send + 'a,
) -> io::Result<Pin<Box<dyn AsyncRead + Send + 'a>>> {
    fn multi<D: AsyncRead + Send>(mut d: D, set: impl FnOnce(&mut D)) -> D {
        set(&mut d);
        d
    }
    Ok(match method {
        "" | "none" | "identity" => Box::pin(r),
        "zstd" => Box::pin(multi(ZstdDecoder::new(r), |d| d.multiple_members(true))),
        "xz" => Box::pin(multi(XzDecoder::new(r), |d| d.multiple_members(true))),
        "bzip2" => Box::pin(multi(BzDecoder::new(r), |d| d.multiple_members(true))),
        "gzip" => Box::pin(multi(GzipDecoder::new(r), |d| d.multiple_members(true))),
        "br" => Box::pin(BrotliDecoder::new(r)),
        m => return Err(io::Error::other(format!("unknown compression {m:?}"))),
    })
}

/// `decoder` for an unbuffered body.
pub fn decode_body<'a>(
    method: &str,
    r: impl AsyncRead + Send + 'a,
) -> io::Result<Pin<Box<dyn AsyncRead + Send + 'a>>> {
    decoder(method, BufReader::with_capacity(1 << 16, r))
}

const MAGIC: &[(&[u8], &str)] = &[
    (b"\x28\xb5\x2f\xfd", "zstd"),
    (b"\xfd7zXZ\x00", "xz"),
    (b"\x1f\x8b", "gzip"),
];

/// Both caches store narinfo/.ls zstd-compressed (Content-Encoding), but the
/// CDN sometimes serves them without that header: sniff the magic too.
pub async fn decode(body: &[u8], encoding: Option<&str>) -> io::Result<Vec<u8>> {
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
    decoder(enc, body)?.read_to_end(&mut out).await?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn decode_sniffs_zstd() {
        let mut z = Vec::new();
        async_compression::tokio::bufread::ZstdEncoder::new(&b"{\"root\":1}"[..])
            .read_to_end(&mut z)
            .await
            .unwrap();
        assert_eq!(decode(&z, None).await.unwrap(), b"{\"root\":1}");
        assert_eq!(decode(&z, Some("zstd")).await.unwrap(), b"{\"root\":1}");
        assert_eq!(decode(b"plain", None).await.unwrap(), b"plain");
    }
}
