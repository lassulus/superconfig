//! `closure OUT DRV...`: what building DRVs needs from the caches, from
//! narinfos only.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::Value;

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

fn run_json(cmd: &mut Command) -> io::Result<Value> {
    let out = cmd.output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "{cmd:?}: {}\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        )));
    }
    serde_json::from_slice(&out.stdout).map_err(io::Error::other)
}

fn abs(p: &str) -> String {
    if p.starts_with('/') {
        p.to_string()
    } else {
        format!("{STORE}{p}")
    }
}

fn derivations(
    drvs: impl IntoIterator<Item = String>,
) -> io::Result<serde_json::Map<String, Value>> {
    let j = run_json(Command::new("nix").args(["derivation", "show"]).args(drvs))?;
    // format 4: {"version": 4, "derivations": {...}}
    let j = match j.get("derivations") {
        Some(d) => d.clone(),
        None => j,
    };
    match j {
        Value::Object(m) => Ok(m.into_iter().map(|(k, v)| (abs(&k), v)).collect()),
        _ => Err(io::Error::other("nix derivation show: not an object")),
    }
}

/// Output paths nix makes valid before building DRVs (wanted outputs of
/// their input derivations), plus the DRVs' own outputs (`--check` needs
/// them valid). Input sources are left out: eval put them into the store.
pub fn wanted_paths(drvs: &[String]) -> io::Result<BTreeSet<String>> {
    let targets: HashSet<String> = drvs.iter().map(|d| abs(d)).collect();
    let mut wanted: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for d in derivations(drvs.iter().cloned())?.values() {
        let idrvs = match d.get("inputs") {
            Some(i) => i.get("drvs").cloned().unwrap_or(Value::Null),
            None => d.get("inputDrvs").cloned().unwrap_or(Value::Null),
        };
        let Value::Object(idrvs) = idrvs else {
            continue;
        };
        for (ip, o) in idrvs {
            let ip = abs(&ip);
            if targets.contains(&ip) {
                continue;
            }
            let outs = match &o {
                Value::Array(a) => a.clone(),
                _ => o
                    .get("outputs")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
            };
            let e = wanted.entry(ip).or_default();
            e.extend(outs.iter().filter_map(Value::as_str).map(str::to_string));
        }
    }
    let mut paths = BTreeSet::new();
    if !wanted.is_empty() {
        for (p, d) in derivations(wanted.keys().cloned())? {
            for o in wanted.get(&p).into_iter().flatten() {
                match d["outputs"][o]["path"].as_str() {
                    Some(op) => {
                        paths.insert(abs(op));
                    }
                    None => eprintln!("{p}: output {o} has no path"),
                }
            }
        }
    }
    let out = Command::new("nix-store")
        .args(["-q", "--outputs"])
        .args(drvs)
        .output()?;
    if !out.status.success() {
        return Err(io::Error::other(format!(
            "nix-store -q --outputs: {}",
            out.status
        )));
    }
    paths.extend(
        String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .map(str::to_string),
    );
    Ok(paths)
}

fn parse_narinfo(text: &[u8]) -> HashMap<String, String> {
    String::from_utf8_lossy(text)
        .lines()
        .filter_map(|l| l.split_once(": "))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn narinfo(
    http: &Http,
    caches: &[String],
    name: &str,
    stats: &Stats,
) -> Option<HashMap<String, String>> {
    let h = name.split('-').next().unwrap_or(name);
    for c in caches {
        match http.get(&format!("{c}/{h}.narinfo")) {
            Ok((body, len)) => {
                stats.add("narinfo", len as u64);
                let mut i = parse_narinfo(&body);
                i.insert("cache".into(), c.clone());
                return Some(i);
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

/// Run `f` over `items` on `threads` threads, results in order.
pub fn par_map<T: Sync, R: Send>(
    items: &[T],
    threads: usize,
    f: impl Fn(&T) -> R + Sync,
) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let out: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    std::thread::scope(|s| {
        for _ in 0..threads.min(items.len()) {
            s.spawn(|| loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= items.len() {
                    break;
                }
                let r = f(&items[i]);
                out.lock().unwrap()[i] = Some(r);
            });
        }
    });
    out.into_inner()
        .unwrap()
        .into_iter()
        .map(Option::unwrap)
        .collect()
}

pub fn closure(outdir: &Path, drvs: &[String]) -> io::Result<()> {
    let roots: BTreeSet<String> = wanted_paths(drvs)?
        .into_iter()
        .map(|p| p.strip_prefix(STORE).unwrap_or(&p).to_string())
        .collect();
    let caches = caches();
    let http = Http::new(caches.iter().map(String::as_str));
    let stats = Stats::new(None);
    let mut infos: BTreeMap<String, HashMap<String, String>> = BTreeMap::new();
    let mut missing: BTreeSet<String> = BTreeSet::new();
    let mut todo: Vec<String> = roots.iter().cloned().collect();
    while !todo.is_empty() {
        let res = par_map(&todo, 32, |n| narinfo(&http, &caches, n, &stats));
        let mut next = BTreeSet::new();
        for (name, i) in todo.iter().zip(res) {
            let Some(i) = i else {
                missing.insert(name.clone());
                continue;
            };
            for r in i
                .get("References")
                .map(String::as_str)
                .unwrap_or("")
                .split_whitespace()
            {
                next.insert(r.to_string());
            }
            infos.insert(name.clone(), i);
        }
        todo = next
            .into_iter()
            .filter(|r| !infos.contains_key(r) && !missing.contains(r))
            .collect();
    }

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
        let refs: Vec<&str> = i
            .get("References")
            .map(String::as_str)
            .unwrap_or("")
            .split_whitespace()
            .collect();
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

    let mut by_cache: BTreeMap<String, u64> = BTreeMap::new();
    for p in paths.values() {
        *by_cache.entry(p.cache.clone()).or_default() += 1;
    }
    let mut summary = serde_json::json!({
        "roots": roots.len(),
        "paths": infos.len(),
        "missing": missing,
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
