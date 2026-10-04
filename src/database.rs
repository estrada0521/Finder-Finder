use std::collections::{HashMap, HashSet};
/// Bidirectional walk that never returns to a category a branch has left.
pub fn provenance_distances(
    seed: &String,
    edges: &[(String, String)],
    category_of: &HashMap<String, String>,
    max_hops: usize,
) -> HashMap<String, usize> {
    let mut adj: HashMap<String, Vec<String>> = HashMap::new();
    for (from, to) in edges {
        adj.entry(from.clone()).or_default().push(to.clone());
        adj.entry(to.clone()).or_default().push(from.clone());
    }
    let category = |key: &String| category_of.get(key).cloned().unwrap_or_default();

    // Every path from the seed is explored independently: the "categories left
    // behind" set belongs to a branch, not to a record, so one branch pruning a
    // category never constrains another. Bounded by max_hops, so the path
    // count stays small.
    let mut dist: HashMap<String, usize> = HashMap::new();
    let mut stack: Vec<(String, usize, HashSet<String>, HashSet<String>)> = vec![(
        seed.clone(),
        0,
        HashSet::new(),
        HashSet::from([seed.clone()]),
    )];
    while let Some((node, hop, departed, on_path)) = stack.pop() {
        if &node != seed {
            dist.entry(node.clone())
                .and_modify(|d| *d = (*d).min(hop))
                .or_insert(hop);
        }
        if hop == max_hops {
            continue;
        }
        let node_category = category(&node);
        for next in adj.get(&node).into_iter().flatten() {
            if on_path.contains(next) {
                continue;
            }
            let next_category = category(next);
            let mut next_departed = departed.clone();
            if !next_category.is_empty() && next_category != node_category {
                if departed.contains(&next_category) {
                    continue; // returning to a category this branch already left
                }
                next_departed.insert(node_category.clone());
            }
            let mut next_on_path = on_path.clone();
            next_on_path.insert(next.clone());
            stack.push((next.clone(), hop + 1, next_departed, next_on_path));
        }
    }
    dist.remove(seed);
    dist
}

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub fn record_dirs(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut dirs = Vec::new();
    for entry in fs::read_dir(root).map_err(|e| format!("{}: {e}", root.display()))? {
        let path = entry.map_err(|e| e.to_string())?.path();
        if path.is_dir()
            && path
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(crate::settings::is_record_id)
            && path.join("metadata.json").is_file()
        {
            dirs.push(path);
        }
    }
    dirs.sort();
    Ok(dirs)
}

pub fn resolve_root(explicit: Option<String>) -> Result<PathBuf, String> {
    let raw = if let Some(root) = explicit {
        root
    } else if let Ok(root) = std::env::var("FINDER_FINDER_DB_ROOT") {
        root
    } else {
        let path = crate::settings::settings_path();
        let settings: Value = serde_json::from_str(&fs::read_to_string(&path).map_err(|e| {
            format!(
                "DB root is not configured ({}: {e}); use --db-root",
                path.display()
            )
        })?)
        .map_err(|e| e.to_string())?;
        settings
            .get("dbRoot")
            .and_then(Value::as_str)
            .ok_or("settings.dbRoot is missing")?
            .to_owned()
    };
    if raw.trim().is_empty() {
        return Err("DB root is empty".into());
    }
    let root = fs::canonicalize(raw).map_err(|e| format!("DB root: {e}"))?;
    if !root.is_dir() {
        return Err("DB root is not a directory".into());
    }
    Ok(root)
}

pub struct Database {
    pub root: PathBuf,
    pub records: std::collections::BTreeMap<String, Value>,
    pub edges: Vec<Value>,
    pub diagnostics: Vec<Value>,
}
impl Database {
    pub fn read(root: PathBuf) -> Result<Self, String> {
        let mut db = Self {
            root,
            records: Default::default(),
            edges: vec![],
            diagnostics: vec![],
        };
        for dir in record_dirs(&db.root)? {
            let id = dir.file_name().unwrap().to_string_lossy().to_string();
            let result = fs::read_to_string(dir.join("metadata.json"))
                .map_err(|e| e.to_string())
                .and_then(|s| serde_json::from_str::<Value>(&s).map_err(|e| e.to_string()));
            let meta = match result {
                Ok(v) if v.is_object() => v,
                other => {
                    db.diagnostics.push(json!({"record":id,"message":other.err().unwrap_or("metadata must be an object".into())}));
                    continue;
                }
            };
            if !meta.get("category").is_some_and(Value::is_string) {
                db.diagnostics
                    .push(json!({"record":id,"message":"category must be a string"}));
            }
            let mut paths = serde_json::Map::new();
            paths.insert("record".into(), json!(dir));
            paths.insert("metadata".into(), json!(dir.join("metadata.json")));
            for key in ["payload", "preview"] {
                let values = match meta.get(key) {
                    Some(Value::String(s)) => vec![s.clone()],
                    Some(Value::Array(a)) => a
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect(),
                    _ => vec![],
                };
                let mut resolved = vec![];
                for rel in values {
                    let path = Path::new(&rel);
                    if path.is_absolute()
                        || path
                            .components()
                            .any(|c| matches!(c, std::path::Component::ParentDir))
                    {
                        db.diagnostics.push(json!({"record":id,"message":format!("{key} is not record-local: {rel}")}));
                        continue;
                    }
                    let full = dir.join(path);
                    resolved.push(json!({"path":full,"exists":full.is_file()}));
                }
                paths.insert(key.into(), json!(resolved));
            }
            if let Some(links) = meta.get("links") {
                if let Some(links) = links.as_array() {
                    for link in links {
                        if let Some(target) = link
                            .get("id")
                            .and_then(Value::as_str)
                            .filter(|s| crate::settings::is_record_id(s))
                        {
                            db.edges.push(json!({"from":id,"to":target,"link":link}));
                        } else {
                            db.diagnostics.push(json!({"record":id,"message":"link requires a valid string id","link":link}));
                        }
                    }
                } else {
                    db.diagnostics
                        .push(json!({"record":id,"message":"links must be an array"}));
                }
            }
            db.records.insert(id.clone(), json!({"id":id,"category":meta.get("category"),"display_name":meta.get("display_name").and_then(Value::as_str).unwrap_or(&id),"metadata":meta,"paths":paths}));
        }
        for edge in &mut db.edges {
            let exists = db.records.contains_key(edge["to"].as_str().unwrap());
            edge["target_exists"] = json!(exists);
            if !exists {
                db.diagnostics.push(json!({"record":edge["from"],"target":edge["to"],"message":"link target is missing or unreadable"}));
            }
        }
        Ok(db)
    }
    pub fn resolve(&self, input: &str) -> Result<String, String> {
        if self.records.contains_key(input) {
            return Ok(input.into());
        }
        let mut path = fs::canonicalize(input).map_err(|_| format!("record not found: {input}"))?;
        if path.file_name().is_some_and(|n| n == "metadata.json") {
            path.pop();
        }
        let id = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or("invalid record path")?;
        if path.parent() != Some(self.root.as_path()) || !self.records.contains_key(id) {
            return Err(format!(
                "record is outside the selected DB or unreadable: {input}"
            ));
        }
        Ok(id.into())
    }
    pub fn walk(&self, seeds: &[String], direction: &str, depth: usize, related: bool) -> Value {
        let edges: Vec<(String, String)> = self
            .edges
            .iter()
            .map(|e| {
                (
                    e["from"].as_str().unwrap().into(),
                    e["to"].as_str().unwrap().into(),
                )
            })
            .collect();
        let categories = self
            .records
            .iter()
            .map(|(id, r)| (id.clone(), r["category"].as_str().unwrap_or("").into()))
            .collect();
        let mut distances: std::collections::BTreeMap<String, usize> =
            seeds.iter().map(|s| (s.clone(), 0)).collect();
        if related {
            for seed in seeds {
                for (id, hop) in provenance_distances(seed, &edges, &categories, 3) {
                    distances
                        .entry(id)
                        .and_modify(|h| *h = (*h).min(hop))
                        .or_insert(hop);
                }
            }
        } else {
            let mut queue = std::collections::VecDeque::from(seeds.to_vec());
            while let Some(id) = queue.pop_front() {
                let hop = distances[&id];
                if hop >= depth {
                    continue;
                }
                for (from, to) in &edges {
                    let next = if direction != "in" && from == &id {
                        Some(to)
                    } else if direction != "out" && to == &id {
                        Some(from)
                    } else {
                        None
                    };
                    if let Some(next) = next {
                        if !distances.contains_key(next) {
                            distances.insert(next.clone(), hop + 1);
                            queue.push_back(next.clone());
                        }
                    }
                }
            }
        }
        let nodes: Vec<Value> = distances
            .iter()
            .filter(|(id, _)| !seeds.contains(id))
            .map(|(id, hop)| json!({"id":id,"distance":hop,"record":self.records.get(id)}))
            .collect();
        let edges: Vec<&Value> = self
            .edges
            .iter()
            .filter(|e| {
                let from = e["from"].as_str().unwrap();
                let to = e["to"].as_str().unwrap();
                if !distances.contains_key(from) || !distances.contains_key(to) {
                    return false;
                }
                related
                    || (direction != "in" && distances[from] < depth)
                    || (direction != "out" && distances[to] < depth)
            })
            .collect();
        json!({"seeds":seeds,"direction":direction,"depth":if related {3} else {depth},"policy":if related {"gui-related"} else {"links"},"records":nodes,"edges":edges})
    }
}
