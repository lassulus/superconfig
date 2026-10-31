//! Binary cache access: GET with retries, and body decoding.

use std::io;
use std::pin::Pin;
use std::time::Duration;

use async_compression::tokio::bufread::{
    BrotliDecoder, BzDecoder, GzipDecoder, XzDecoder, ZstdDecoder,
};
use tokio::io::{AsyncBufRead, AsyncRead, AsyncReadExt, BufReader};
use tokio::time::sleep;
use tokio_util::io::StreamReader;

const TRIES: u32 = 6;

pub type Body = Pin<Box<dyn AsyncRead + Send>>;

#[derive(Clone)]
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

    /// GET `url` -> body reader and its Content-Encoding. When the
    /// connection breaks while the body is read, it continues with a Range
    /// request from the byte reached, like Nix does: B2 closes long
    /// transfers, so a 2 GiB NAR never arrived in one piece on the CI
    /// runners. Gives up after TRIES errors in a row without new data.
    pub async fn open(&self, url: &str) -> Result<(Body, Option<String>), Error> {
        if let Some(path) = url.strip_prefix("file://") {
            return match tokio::fs::File::open(path).await {
                Ok(f) => Ok((Box::pin(f), None)),
                Err(e) if e.kind() == io::ErrorKind::NotFound => Err(Error::NotFound),
                Err(e) => Err(Error::Other(format!("{url}: {e}"))),
            };
        }
        let r = self.send(url, 0).await?;
        let enc = r
            .headers()
            .get("content-encoding")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        let state = (self.clone(), url.to_string(), r, 0u64);
        let body = futures_util::stream::try_unfold(state, |(http, url, mut r, mut from)| async move {
            let mut fails = 0;
            loop {
                let e = match r.chunk().await {
                    Ok(Some(b)) => {
                        from += b.len() as u64;
                        return Ok(Some((b, (http, url, r, from))));
                    }
                    Ok(None) => return Ok(None),
                    Err(e) => chain(&e),
                };
                fails += 1;
                if fails == TRIES {
                    return Err(io::Error::other(format!("{url}: {e}")));
                }
                eprintln!("resuming {url} at byte {from} ({fails}/{}): {e}", TRIES - 1);
                sleep(backoff(fails)).await;
                r = http.send(&url, from).await?;
            }
        });
        Ok((Box::pin(StreamReader::new(body)), enc))
    }

    /// GET `url` from byte `from` on, retrying 429/5xx and transport errors
    /// with backoff (the caches answer 503 under load).
    async fn send(&self, url: &str, from: u64) -> Result<reqwest::Response, Error> {
        let mut n = 0;
        loop {
            let mut req = self.client.get(url);
            if from > 0 {
                req = req.header(reqwest::header::RANGE, format!("bytes={from}-"));
            }
            let err = match req.send().await {
                Ok(r) if r.status().is_success() => {
                    let resumed = r
                        .headers()
                        .get(reqwest::header::CONTENT_RANGE)
                        .and_then(|v| v.to_str().ok())
                        .is_some_and(|v| v.starts_with(&format!("bytes {from}-")));
                    if from == 0 || r.status() == 206 && resumed {
                        return Ok(r);
                    }
                    return Err(Error::Other(format!(
                        "{url}: cannot resume at byte {from}: HTTP {}",
                        r.status().as_u16()
                    )));
                }
                Ok(r) => match r.status().as_u16() {
                    403 | 404 => return Err(Error::NotFound),
                    code if code != 429 && code < 500 => {
                        return Err(Error::Other(format!("{url}: HTTP {code}")))
                    }
                    code => format!("HTTP {code}"),
                },
                Err(e) => chain(&e),
            };
            n += 1;
            if n == TRIES {
                return Err(Error::Other(format!("{url}: {err}")));
            }
            eprintln!("retry {n}/{} {url}: {err}", TRIES - 1);
            sleep(backoff(n)).await;
        }
    }

    /// GET `url` -> decoded body and its size on the wire.
    pub async fn get(&self, url: &str) -> Result<(Vec<u8>, usize), Error> {
        let (mut r, enc) = self.open(url).await?;
        let mut body = Vec::new();
        r.read_to_end(&mut body)
            .await
            .map_err(|e| Error::Other(e.to_string()))?;
        let len = body.len();
        let dec = decode(&body, enc.as_deref())
            .await
            .map_err(|e| Error::Other(format!("{url}: decoding: {e}")))?;
        Ok((dec, len))
    }
}

fn backoff(n: u32) -> Duration {
    Duration::from_secs((1u64 << (n - 1)).min(30))
}

/// `e` with its sources: reqwest's own message for a broken body is just
/// "error decoding response body".
fn chain(e: &dyn std::error::Error) -> String {
    let mut s = e.to_string();
    let mut src = e.source();
    while let Some(c) = src {
        s += &format!(": {c}");
        src = c.source();
    }
    s
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

    /// A server that closes every connection after 300,000 bytes of body:
    /// the body arrives whole, over 4 connections.
    #[tokio::test]
    async fn open_resumes_broken_transfers() {
        use tokio::io::AsyncWriteExt;
        let data: Vec<u8> = (0..1_000_000u32).map(|i| (i % 251) as u8).collect();
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/nar", l.local_addr().unwrap());
        let served = data.clone();
        let server = tokio::spawn(async move {
            for _ in 0..4 {
                let (mut s, _) = l.accept().await.unwrap();
                let (mut req, mut buf) = (Vec::new(), [0; 1024]);
                while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                    let k = s.read(&mut buf).await.unwrap();
                    req.extend_from_slice(&buf[..k]);
                }
                let from: usize = String::from_utf8_lossy(&req)
                    .to_lowercase()
                    .lines()
                    .find_map(|l| l.strip_prefix("range: bytes=").map(|r| r.trim_end_matches('-').parse().unwrap()))
                    .unwrap_or(0);
                let len = served.len();
                let head = if from == 0 {
                    format!("HTTP/1.1 200 OK\r\ncontent-length: {len}\r\n\r\n")
                } else {
                    format!(
                        "HTTP/1.1 206 Partial Content\r\ncontent-range: bytes {from}-{}/{len}\r\ncontent-length: {}\r\n\r\n",
                        len - 1,
                        len - from
                    )
                };
                s.write_all(head.as_bytes()).await.unwrap();
                s.write_all(&served[from..(from + 300_000).min(len)]).await.unwrap();
            }
        });
        let http = Http::new([url.as_str()]).await;
        let mut got = Vec::new();
        match http.open(&url).await {
            Ok((mut body, _)) => body.read_to_end(&mut got).await.unwrap(),
            Err(e) => panic!("{e}"),
        };
        assert!(got == data, "got {} bytes", got.len());
        server.await.unwrap();
    }
}
