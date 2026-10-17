//! `closure OUT`: the closure of the store paths on stdin, from the caches'
//! narinfos only.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, BufRead, Write};
use std::path::Path;

use futures_util::{stream, StreamExt};
use harmonia_store_nar_info::{parse_narinfo_txt, NarInfo};
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_utils_hash::{Hash, HashFormat};
use serde::{Deserialize, Serialize};

use crate::http::{self, Http};
use crate::stats::Stats;
use crate::STORE;

/// Per store path, what the lazy layer needs to fetch it (OUT/paths.json).
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PathInfo {
    pub cache: String,
    pub url: String,
    pub compression: String,
    pub nar_hash: String,
    pub nar_size: u64,
    pub file_size: u64,
}

pub fn caches() -> Vec<String> {
    std::env::var("LAZY_STORE_CACHES")
        .unwrap_or_else(|_| "https://cache.nixos.org https://cache.lassul.us".into())
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

/// A narinfo, the cache it is from and its text.
struct Found {
    cache: String,
    info: NarInfo,
    text: Vec<u8>,
}

impl Found {
    fn references(&self) -> &BTreeSet<StorePath> {
        &self.info.info.info.references
    }
}

/// The narinfo of `path` from the first cache that has it.
async fn narinfo(http: &Http, caches: &[String], path: &StorePath, stats: &Stats) -> Option<Found> {
    let h = path.hash();
    for c in caches {
        let url = format!("{c}/{h}.narinfo");
        let err = match http.get(&url).await {
            Ok((text, len)) => {
                stats.add("narinfo", len as u64);
                let parsed = std::str::from_utf8(&text)
                    .map_err(|e| e.to_string())
                    .and_then(|s| {
                        parse_narinfo_txt(&StoreDir::default(), s).map_err(|e| e.to_string())
                    });
                match parsed {
                    Ok(info) => {
                        let cache = c.clone();
                        return Some(Found { cache, info, text });
                    }
                    Err(e) => e,
                }
            }
            Err(http::Error::NotFound) => continue,
            // still failing after the retries
            Err(e) => e.to_string(),
        };
        // try the next cache
        eprintln!("giving up on {url}: {err}");
        stats.add("narinfo_error", 0);
    }
    None
}

/// Writes OUT/paths.json (per path: cache, NAR url, compression, hash),
/// OUT/db.dump (input for `nix-store --load-db`), OUT/narinfo (a binary
/// cache of just the narinfos) and OUT/closure.json.
/// Paths that are in none of the caches, and everything referring to them,
/// are left out: a path is registered only with its whole closure.
pub async fn closure(outdir: &Path) -> io::Result<()> {
    let mut roots = BTreeSet::new();
    for l in io::stdin().lock().lines() {
        let l = l?;
        let l = l.trim();
        if !l.is_empty() {
            let p = l.strip_prefix(STORE).unwrap_or(l);
            roots.insert(p.parse::<StorePath>().map_err(io::Error::other)?);
        }
    }
    let caches = caches();
    let http = Http::new(caches.iter().map(String::as_str)).await;
    let stats = Stats::new(None);
    let mut infos: BTreeMap<StorePath, Found> = BTreeMap::new();
    let mut missing: BTreeSet<StorePath> = BTreeSet::new();
    let mut todo: Vec<StorePath> = roots.iter().cloned().collect();
    while !todo.is_empty() {
        let (http, caches, stats) = (&http, &caches, &stats);
        let mut res = stream::iter(std::mem::take(&mut todo))
            .map(|p| async move {
                let i = narinfo(http, caches, &p, stats).await;
                (p, i)
            })
            .buffer_unordered(32);
        let mut next = BTreeSet::new();
        while let Some((path, i)) = res.next().await {
            let Some(i) = i else {
                missing.insert(path);
                continue;
            };
            next.extend(i.references().iter().cloned());
            infos.insert(path, i);
        }
        todo = next
            .into_iter()
            .filter(|r| !infos.contains_key(r) && !missing.contains(r))
            .collect();
    }

    let mut referrers: HashMap<&StorePath, Vec<&StorePath>> = HashMap::new();
    for (n, i) in &infos {
        for r in i.references().iter().filter(|r| *r != n) {
            referrers.entry(r).or_default().push(n);
        }
    }
    let mut incomplete = BTreeSet::new();
    let mut todo: Vec<&StorePath> = missing.iter().collect();
    while let Some(m) = todo.pop() {
        for r in referrers.get(m).into_iter().flatten() {
            if incomplete.insert((*r).clone()) {
                todo.push(r);
            }
        }
    }
    infos.retain(|n, _| !incomplete.contains(n));

    let nar_hash = |i: &Found| {
        Hash::from(i.info.info.info.nar_hash)
            .as_base32()
            .to_string()
    };
    let paths: BTreeMap<&StorePath, PathInfo> = infos
        .iter()
        .map(|(n, i)| {
            let ni = &i.info.info;
            let info = PathInfo {
                cache: i.cache.clone(),
                url: ni.url.clone().unwrap_or_default(),
                compression: ni.compression.clone().unwrap_or_else(|| "none".into()),
                nar_hash: nar_hash(i),
                nar_size: ni.info.nar_size,
                file_size: ni.download_size.unwrap_or(0),
            };
            (n, info)
        })
        .collect();
    std::fs::write(outdir.join("paths.json"), serde_json::to_vec(&paths)?)?;

    let mut db = io::BufWriter::new(std::fs::File::create(outdir.join("db.dump"))?);
    for (n, i) in &infos {
        let pi = &i.info.info.info;
        let deriver = match &pi.deriver {
            Some(d) if d.is_derivation() => format!("{STORE}{d}"),
            _ => String::new(),
        };
        let refs = i.references();
        writeln!(
            db,
            "{STORE}{n}\n{}\n{}\n{deriver}\n{}",
            nar_hash(i),
            pi.nar_size,
            refs.len()
        )?;
        for r in refs {
            writeln!(db, "{STORE}{r}")?;
        }
    }
    db.flush()?;

    // the narinfos as a binary cache, for their signatures: `nix-store
    // --load-db` registers none, `nix store copy-sigs` adds them
    let dir = outdir.join("narinfo");
    std::fs::create_dir_all(&dir)?;
    std::fs::write(dir.join("nix-cache-info"), "StoreDir: /nix/store\n")?;
    for (n, i) in &infos {
        std::fs::write(dir.join(format!("{}.narinfo", n.hash())), &i.text)?;
    }

    let mut by_cache: BTreeMap<&str, u64> = BTreeMap::new();
    for p in paths.values() {
        *by_cache.entry(&p.cache).or_default() += 1;
    }
    let mut summary = serde_json::json!({
        "roots": roots.len(),
        "paths": infos.len(),
        "missing": missing,
        "incomplete": incomplete.len(),
        "by_cache": by_cache,
        "nar_size": paths.values().map(|p| p.nar_size).sum::<u64>(),
        "file_size": paths.values().map(|p| p.file_size).sum::<u64>(),
    });
    summary.as_object_mut().unwrap().extend(stats.counters());
    let s = serde_json::to_string_pretty(&summary)?;
    std::fs::write(outdir.join("closure.json"), &s)?;
    println!("{s}");
    Ok(())
}
