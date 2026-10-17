//! `closure OUT`: the closure of the store paths on stdin, from the caches'
//! narinfos only.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::{self, BufRead, Write};
use std::path::Path;

use futures_util::{stream, StreamExt};
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

fn parse_narinfo(text: &[u8]) -> HashMap<String, String> {
    String::from_utf8_lossy(text)
        .lines()
        .filter_map(|l| l.split_once(": "))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn references(i: &HashMap<String, String>) -> impl Iterator<Item = &str> {
    i.get("References")
        .map(String::as_str)
        .unwrap_or("")
        .split_whitespace()
}

/// The parsed narinfo of `name` from the first cache that has it, and its
/// text.
async fn narinfo(
    http: &Http,
    caches: &[String],
    name: &str,
    stats: &Stats,
) -> Option<(HashMap<String, String>, Vec<u8>)> {
    let h = name.split('-').next().unwrap_or(name);
    for c in caches {
        match http.get(&format!("{c}/{h}.narinfo")).await {
            Ok((body, len)) => {
                stats.add("narinfo", len as u64);
                let mut i = parse_narinfo(&body);
                i.insert("cache".into(), c.clone());
                return Some((i, body));
            }
            Err(http::Error::NotFound) => {}
            // still failing after the retries: try the next cache
            Err(e) => {
                eprintln!("giving up on {c}/{h}.narinfo: {e}");
                stats.add("narinfo_error", 0);
            }
        }
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
            roots.insert(l.strip_prefix(STORE).unwrap_or(l).to_string());
        }
    }
    let caches = caches();
    let http = Http::new(caches.iter().map(String::as_str)).await;
    let stats = Stats::new(None);
    let mut infos: BTreeMap<String, HashMap<String, String>> = BTreeMap::new();
    let mut texts: HashMap<String, Vec<u8>> = HashMap::new();
    let mut missing: BTreeSet<String> = BTreeSet::new();
    let mut todo: Vec<String> = roots.iter().cloned().collect();
    while !todo.is_empty() {
        let (http, caches, stats) = (&http, &caches, &stats);
        let mut res = stream::iter(std::mem::take(&mut todo))
            .map(|n| async move {
                let i = narinfo(http, caches, &n, stats).await;
                (n, i)
            })
            .buffer_unordered(32);
        let mut next = BTreeSet::new();
        while let Some((name, i)) = res.next().await {
            let Some((i, text)) = i else {
                missing.insert(name.clone());
                continue;
            };
            next.extend(references(&i).map(str::to_string));
            infos.insert(name.clone(), i);
            texts.insert(name.clone(), text);
        }
        todo = next
            .into_iter()
            .filter(|r| !infos.contains_key(r) && !missing.contains(r))
            .collect();
    }

    let mut referrers: HashMap<String, Vec<String>> = HashMap::new();
    for (n, i) in &infos {
        for r in references(i).filter(|r| *r != n.as_str()) {
            referrers.entry(r.to_string()).or_default().push(n.clone());
        }
    }
    let mut incomplete = BTreeSet::new();
    let mut todo: Vec<&String> = missing.iter().collect();
    while let Some(m) = todo.pop() {
        for r in referrers.get(m).into_iter().flatten() {
            if incomplete.insert(r.clone()) {
                todo.push(r);
            }
        }
    }
    infos.retain(|n, _| !incomplete.contains(n));

    let mut paths = BTreeMap::new();
    for (n, i) in &infos {
        let get = |k: &str| {
            i.get(k)
                .cloned()
                .ok_or_else(|| io::Error::other(format!("{n}: narinfo without {k}")))
        };
        paths.insert(
            n.clone(),
            PathInfo {
                cache: get("cache")?,
                url: get("URL")?,
                compression: i
                    .get("Compression")
                    .cloned()
                    .unwrap_or_else(|| "none".into()),
                nar_hash: get("NarHash")?,
                nar_size: get("NarSize")?.parse().map_err(io::Error::other)?,
                file_size: i.get("FileSize").and_then(|s| s.parse().ok()).unwrap_or(0),
            },
        );
    }
    std::fs::write(outdir.join("paths.json"), serde_json::to_vec(&paths)?)?;

    let mut db = io::BufWriter::new(std::fs::File::create(outdir.join("db.dump"))?);
    for (n, i) in &infos {
        let refs: Vec<&str> = references(i).collect();
        let d = i.get("Deriver").map(String::as_str).unwrap_or("");
        let deriver = if d.ends_with(".drv") {
            format!("{STORE}{d}")
        } else {
            String::new()
        };
        writeln!(
            db,
            "{STORE}{n}\n{}\n{}\n{deriver}\n{}",
            i["NarHash"],
            i["NarSize"],
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
    for n in infos.keys() {
        let h = n.split('-').next().unwrap_or(n);
        std::fs::write(dir.join(format!("{h}.narinfo")), &texts[n])?;
    }

    let mut by_cache: BTreeMap<String, u64> = BTreeMap::new();
    for p in paths.values() {
        *by_cache.entry(p.cache.clone()).or_default() += 1;
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
