//! Counters written to OUT/stats.json (and merged into closure.json).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Default)]
struct Inner {
    c: BTreeMap<String, u64>,
    nars: Vec<(String, u64, u64)>,
}

#[derive(Default)]
pub struct Stats {
    path: Option<PathBuf>,
    inner: Mutex<Inner>,
}

impl Stats {
    pub fn new(path: Option<PathBuf>) -> Stats {
        Stats {
            path,
            ..Default::default()
        }
    }

    pub fn add(&self, kind: &str, nbytes: u64) {
        let mut i = self.inner.lock().unwrap();
        *i.c.entry(format!("{kind}_count")).or_default() += 1;
        *i.c.entry(format!("{kind}_bytes")).or_default() += nbytes;
    }

    pub fn nar(&self, name: &str, file_bytes: u64, nar_bytes: u64) {
        {
            let mut i = self.inner.lock().unwrap();
            i.nars.push((name.to_string(), file_bytes, nar_bytes));
            *i.c.entry("nar_count".into()).or_default() += 1;
            *i.c.entry("nar_bytes".into()).or_default() += file_bytes;
            *i.c.entry("nar_unpacked_bytes".into()).or_default() += nar_bytes;
        }
        self.save();
    }

    pub fn counters(&self) -> serde_json::Map<String, serde_json::Value> {
        let i = self.inner.lock().unwrap();
        i.c.iter().map(|(k, v)| (k.clone(), (*v).into())).collect()
    }

    pub fn save(&self) {
        let Some(path) = &self.path else { return };
        let i = self.inner.lock().unwrap();
        let mut j: serde_json::Map<_, _> =
            i.c.iter().map(|(k, v)| (k.clone(), (*v).into())).collect();
        j.insert("nars".into(), serde_json::to_value(&i.nars).unwrap());
        let tmp = path.with_extension("json.tmp");
        let r = std::fs::write(&tmp, serde_json::to_vec(&j).unwrap())
            .and_then(|_| std::fs::rename(&tmp, path));
        if let Err(e) = r {
            eprintln!("writing {}: {e}", path.display());
        }
    }
}
