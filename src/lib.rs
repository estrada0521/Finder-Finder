mod settings;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn finder_quicklook_open(
        paths: *const *const std::ffi::c_char,
        names: *const *const std::ffi::c_char,
        count: usize,
    );
    fn finder_quicklook_current_index() -> std::os::raw::c_long;
}

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
struct QlItem {
    payloads: Vec<PathBuf>,
}

static LAST_QL: Mutex<Vec<QlItem>> = Mutex::new(Vec::new());

#[derive(Serialize)]
struct Catalog {
    columns: Vec<CatalogColumn>,
}

#[derive(Serialize)]
struct CatalogColumn {
    kind: String,
    label: String,
    records: Vec<RecordEntry>,
}

#[derive(Serialize, Clone)]
struct RecordEntry {
    id: String,
    title: String,
    payload: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    preview: Option<String>,
    kind: String,
}

fn db_root() -> Result<String, String> {
    Ok(settings::load()?.db_root)
}

fn present_folders() -> Result<Vec<String>, String> {
    settings::present_categories()
}

fn require_folder(kind: &str) -> Result<String, String> {
    let folders = present_folders()?;
    if folders.iter().any(|folder| folder == kind) {
        Ok(kind.to_string())
    } else {
        Err(format!("unknown kind: {kind}"))
    }
}

fn read_json(path: &Path) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or(Value::Null)
}

fn text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.trim().to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn display_name(meta: &Value, id: &str) -> String {
    let name = text(meta.get("display_name"));
    if name.is_empty() {
        id.to_string()
    } else {
        name
    }
}

fn record_dir(root: &Path, id: &str) -> Result<PathBuf, String> {
    if !settings::is_record_id(id) {
        return Err(format!("invalid record id: {id}"));
    }
    Ok(settings::records_dir(root).join(id))
}

fn all_record_dirs(root: &Path) -> Result<Vec<PathBuf>, String> {
    let dir = settings::records_dir(root);
    if !dir.is_dir() {
        return Err(format!("records dir not found: {}", dir.display()));
    }
    let mut dirs = fs::read_dir(&dir)
        .map_err(|err| format!("failed to read records dir: {err}"))?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.is_dir()
                && path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(settings::is_record_id)
                && settings::metadata_path(path).is_file()
        })
        .collect::<Vec<_>>();
    dirs.sort();
    Ok(dirs)
}

fn meta_links(meta: &Value) -> Vec<String> {
    match meta.get("links") {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|item| match item {
                Value::Object(object) => {
                    let id = text(object.get("id"));
                    if id.is_empty() {
                        None
                    } else {
                        Some(id)
                    }
                }
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn string_list(meta: &Value, key: &str) -> Vec<String> {
    match meta.get(key) {
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| text(Some(item)))
            .filter(|value| !value.is_empty())
            .collect(),
        Some(other) => {
            let value = text(Some(other));
            if value.is_empty() {
                Vec::new()
            } else {
                vec![value]
            }
        }
        None => Vec::new(),
    }
}

fn declared_output_rels(meta: &Value) -> Vec<String> {
    string_list(meta, "payload")
}

fn output_paths(dir: &Path, meta: &Value) -> Result<Vec<PathBuf>, String> {
    let rels = declared_output_rels(meta);
    if rels.is_empty() {
        return Err("output not found".to_string());
    }
    rels.into_iter()
        .map(|rel| {
            let path = dir.join(&rel);
            if path.is_file() {
                Ok(path)
            } else {
                Err(format!("output not found: {rel}"))
            }
        })
        .collect()
}

fn preview_path(dir: &Path, meta: &Value) -> Option<PathBuf> {
    let rel = text(meta.get("preview"));
    if rel.is_empty() || Path::new(&rel).is_absolute() {
        return None;
    }
    let record = dir.canonicalize().ok()?;
    let preview = dir.join(rel).canonicalize().ok()?;
    if preview.is_file() && preview.starts_with(record) {
        Some(preview)
    } else {
        None
    }
}

fn entry_for(dir: &Path) -> RecordEntry {
    let id = dir.file_name().unwrap().to_string_lossy().to_string();
    let meta = read_json(&settings::metadata_path(dir));
    RecordEntry {
        id: id.clone(),
        title: display_name(&meta, &id),
        payload: output_paths(dir, &meta)
            .ok()
            .and_then(|paths| paths.first().map(|path| path.to_string_lossy().to_string())),
        preview: preview_path(dir, &meta).map(|path| path.to_string_lossy().to_string()),
        kind: text(meta.get("category")),
    }
}

fn list_catalog() -> Result<Catalog, String> {
    let root = PathBuf::from(db_root()?);
    if !root.is_dir() {
        return Err(format!("DB root not found: {}", root.display()));
    }
    let mut by_category: HashMap<String, Vec<RecordEntry>> = HashMap::new();
    for dir in all_record_dirs(&root)? {
        let entry = entry_for(&dir);
        by_category
            .entry(entry.kind.clone())
            .or_default()
            .push(entry);
    }
    for records in by_category.values_mut() {
        records.sort_by(|a, b| a.id.cmp(&b.id));
    }
    let mut kinds: Vec<String> = by_category.keys().cloned().collect();
    kinds.sort();
    Ok(Catalog {
        columns: kinds
            .into_iter()
            .map(|kind| CatalogColumn {
                label: settings::folder_label(&kind),
                records: by_category.remove(&kind).unwrap_or_default(),
                kind,
            })
            .collect(),
    })
}

#[derive(Serialize)]
struct RelatedCatalog {
    title: String,
    header: String,
    columns: Vec<CatalogColumn>,
}

type NodeKey = String;

/// Record entries plus directed edges `from -> to` as written in `links`.
fn build_graph(root: &Path) -> Result<(HashMap<NodeKey, RecordEntry>, Vec<(NodeKey, NodeKey)>), String> {
    let mut nodes: HashMap<NodeKey, RecordEntry> = HashMap::new();
    let mut edges: Vec<(NodeKey, NodeKey)> = Vec::new();

    for dir in all_record_dirs(root)? {
        let id = dir.file_name().unwrap().to_string_lossy().to_string();
        let meta = read_json(&settings::metadata_path(&dir));
        for target in meta_links(&meta) {
            edges.push((id.clone(), target));
        }
        nodes.insert(id, entry_for(&dir));
    }
    Ok((nodes, edges))
}

/// How far the related walk reaches from a seed.
const PROVENANCE_HOPS: usize = 3;

/// Records within `PROVENANCE_HOPS` of `seed`, following `links` in either
/// direction. Consecutive records of the same category are fine
/// (`Build -> Build -> Analysis -> ...`), but once a path moves *off* a
/// category it may not return to it: `Build -> Analysis -> Build` and
/// `Data -> Rawdata -> Data` are both cut. Because a path has left nothing
/// behind at hop 1, the seed's own direct references always come through.
/// Categories are the opaque `category` label of each record -- no particular
/// category is named or special-cased. `seed` is excluded from the result.
fn provenance_distances(
    seed: &NodeKey,
    edges: &[(NodeKey, NodeKey)],
    category_of: &HashMap<NodeKey, String>,
) -> HashMap<NodeKey, usize> {
    let mut adj: HashMap<NodeKey, Vec<NodeKey>> = HashMap::new();
    for (from, to) in edges {
        adj.entry(from.clone()).or_default().push(to.clone());
        adj.entry(to.clone()).or_default().push(from.clone());
    }
    let category = |key: &NodeKey| category_of.get(key).cloned().unwrap_or_default();

    // Every path from the seed is explored independently: the "categories left
    // behind" set belongs to a branch, not to a record, so one branch pruning a
    // category never constrains another. Bounded by PROVENANCE_HOPS, so the path
    // count stays small.
    let mut dist: HashMap<NodeKey, usize> = HashMap::new();
    let mut stack: Vec<(NodeKey, usize, HashSet<String>, HashSet<NodeKey>)> =
        vec![(seed.clone(), 0, HashSet::new(), HashSet::from([seed.clone()]))];
    while let Some((node, hop, departed, on_path)) = stack.pop() {
        if &node != seed {
            dist.entry(node.clone())
                .and_modify(|d| *d = (*d).min(hop))
                .or_insert(hop);
        }
        if hop == PROVENANCE_HOPS {
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

fn list_related(ids: Vec<String>, direct_only: bool) -> Result<RelatedCatalog, String> {
    let folders = present_folders()?;
    let root = PathBuf::from(db_root()?);
    let (nodes, edges) = build_graph(&root)?;

    let seeds: Vec<String> = ids.into_iter().filter(|id| nodes.contains_key(id)).collect();
    if seeds.is_empty() {
        return Err("no seed record found".to_string());
    }
    let seed_set: HashSet<&String> = seeds.iter().collect();

    let mut distances: HashMap<NodeKey, usize> = HashMap::new();
    if direct_only {
        // Just the records a seed names in `links`, and the records that name a
        // seed -- an audit view of what each seed is directly wired to.
        for (from, to) in &edges {
            if seed_set.contains(from) && !seed_set.contains(to) {
                distances.entry(to.clone()).or_insert(1);
            }
            if seed_set.contains(to) && !seed_set.contains(from) {
                distances.entry(from.clone()).or_insert(1);
            }
        }
    } else {
        let category_of: HashMap<NodeKey, String> = nodes
            .iter()
            .map(|(key, entry)| (key.clone(), entry.kind.clone()))
            .collect();
        for seed in &seeds {
            for (node, hop) in provenance_distances(seed, &edges, &category_of) {
                if seed_set.contains(&node) {
                    continue;
                }
                distances
                    .entry(node)
                    .and_modify(|existing| *existing = (*existing).min(hop))
                    .or_insert(hop);
            }
        }
    }

    let prefix = if direct_only { "Direct links" } else { "Links" };
    let (title, header) = if seeds.len() == 1 {
        let t = nodes[&seeds[0]].title.clone();
        let h = format!("{prefix} · {t}");
        (t, h)
    } else if direct_only {
        let t = format!("{} records", seeds.len());
        (t.clone(), format!("{prefix} · {t}"))
    } else {
        (
            format!("{} records", seeds.len()),
            format!("Linked {} records", seeds.len()),
        )
    };

    let mut ranked: Vec<(usize, usize, CatalogColumn)> = folders
        .iter()
        .enumerate()
        .filter_map(|(folder_index, column_kind)| {
            let mut records = distances
                .iter()
                .filter_map(|(key, hop)| {
                    let entry = nodes.get(key)?;
                    (entry.kind == *column_kind).then(|| (*hop, entry.clone()))
                })
                .collect::<Vec<_>>();
            if records.is_empty() {
                return None;
            }
            records.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.id.cmp(&b.1.id)));
            let min_hop = records[0].0;
            Some((
                min_hop,
                folder_index,
                CatalogColumn {
                    kind: column_kind.clone(),
                    label: settings::folder_label(column_kind),
                    records: records.into_iter().map(|(_, entry)| entry).collect(),
                },
            ))
        })
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let columns = ranked.into_iter().map(|(_, _, column)| column).collect();

    Ok(RelatedCatalog { title, header, columns })
}

fn find_payloads(root: &Path, id: &str) -> Result<Vec<PathBuf>, String> {
    let dir = record_dir(root, id)?;
    if !dir.is_dir() {
        return Err(format!("record not found: {id}"));
    }
    let meta = read_json(&settings::metadata_path(&dir));
    output_paths(&dir, &meta)?
        .into_iter()
        .map(canonical_db_file)
        .collect()
}

fn record_metadata_path(root: &Path, id: &str) -> Result<PathBuf, String> {
    let dir = record_dir(root, id)?;
    let path = settings::metadata_path(&dir);
    if path.is_file() {
        Ok(path)
    } else {
        Err(format!("metadata not found: {id}"))
    }
}

fn canonical_db_file(path: PathBuf) -> Result<PathBuf, String> {
    let root = PathBuf::from(db_root()?)
        .canonicalize()
        .map_err(|err| format!("failed to resolve DB root: {err}"))?;
    let resolved = path
        .canonicalize()
        .map_err(|err| format!("failed to resolve file: {err}"))?;
    if resolved.starts_with(root) {
        Ok(resolved)
    } else {
        Err("file must be inside DB root".to_string())
    }
}

fn open_files(paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    Command::new("open")
        .args(paths)
        .spawn()
        .map_err(|err| format!("failed to open files: {err}"))?;
    Ok(())
}

fn reveal_files(paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    Command::new("open")
        .arg("-R")
        .args(paths)
        .spawn()
        .map_err(|err| format!("failed to reveal files: {err}"))?;
    Ok(())
}

fn quicklook_files_native(items: &[(PathBuf, String)]) -> Result<(), String> {
    if items.is_empty() {
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let paths = items
            .iter()
            .filter_map(|(path, _)| CString::new(path.as_os_str().as_encoded_bytes()).ok())
            .collect::<Vec<_>>();
        let names = items
            .iter()
            .filter_map(|(_, name)| CString::new(name.as_str()).ok())
            .collect::<Vec<_>>();
        if paths.len() != items.len() || names.len() != items.len() {
            return Err("failed to encode Quick Look item".to_string());
        }
        let ptrs = paths.iter().map(|path| path.as_ptr()).collect::<Vec<_>>();
        let name_ptrs = names.iter().map(|name| name.as_ptr()).collect::<Vec<_>>();
        // Called from an AppKit action, hence already on the main thread.
        unsafe { finder_quicklook_open(ptrs.as_ptr(), name_ptrs.as_ptr(), ptrs.len()) };
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Command::new("qlmanage")
            .arg("-p")
            .args(items.iter().map(|(path, _)| path))
            .spawn()
            .map_err(|err| format!("failed to quick look files: {err}"))?;
        Ok(())
    }
}

fn active_ql_item() -> Option<QlItem> {
    let items = LAST_QL.lock().unwrap().clone();
    #[cfg(target_os = "macos")]
    {
        let index = unsafe { finder_quicklook_current_index() };
        if index >= 0 {
            return items.get(index as usize).cloned();
        }
    }
    None
}

fn quicklook_items(
    root: &Path,
    id: &str,
) -> Result<Vec<(PathBuf, String, QlItem)>, String> {
    let rec = record_dir(root, id)?;
    let meta = read_json(&settings::metadata_path(&rec));
    let payloads = output_paths(&rec, &meta)?
        .into_iter()
        .map(canonical_db_file)
        .collect::<Result<Vec<_>, _>>()?;
    if let Some(preview) = preview_path(&rec, &meta) {
        return Ok(vec![(
            preview,
            display_name(&meta, id),
            QlItem { payloads },
        )]);
    }
    Ok(payloads
        .into_iter()
        .map(|payload| {
            let name = payload
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or(id)
                .to_string();
            (
                payload.clone(),
                name,
                QlItem { payloads: vec![payload] },
            )
        })
        .collect())
}

fn record_paths(ids: &[String]) -> Result<Vec<PathBuf>, String> {
    let root = PathBuf::from(db_root()?);
    ids.iter()
        .map(|id| record_dir(&root, id).and_then(canonical_db_file))
        .collect()
}

fn copy_paths_to_clipboard(paths: &[PathBuf]) -> Result<(), String> {
    let text = paths
        .iter()
        .map(|path| path.to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("\n");
    let mut child = Command::new("pbcopy")
        .env("LANG", "en_US.UTF-8")
        .env("LC_CTYPE", "UTF-8")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|err| format!("failed to copy paths: {err}"))?;
    child
        .stdin
        .take()
        .ok_or("failed to open pbcopy stdin")?
        .write_all(text.as_bytes())
        .map_err(|err| format!("failed to write paths: {err}"))?;
    child.wait().map_err(|err| format!("failed to copy paths: {err}"))?;
    Ok(())
}

fn copy_paths_relative_to_db_root(paths: &[PathBuf]) -> Result<(), String> {
    let root = PathBuf::from(db_root()?)
        .canonicalize()
        .map_err(|err| format!("failed to resolve DB root: {err}"))?;
    let relative = paths
        .iter()
        .map(|path| {
            let path = path
                .canonicalize()
                .map_err(|err| format!("failed to resolve path: {err}"))?;
            path.strip_prefix(&root)
                .map(|value| value.to_path_buf())
                .map_err(|_| format!("path is outside DB root: {}", path.display()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    copy_paths_to_clipboard(&relative)
}

fn copy_record_paths(kind: String, ids: Vec<String>) -> Result<(), String> {
    require_folder(&kind)?;
    copy_paths_to_clipboard(&record_paths(&ids)?)
}

fn next_record_id(root: &Path) -> Result<String, String> {
    let mut highest = 0u64;
    for entry in fs::read_dir(root).map_err(|err| format!("failed to read DB root: {err}"))? {
        let entry = entry.map_err(|err| format!("failed to read DB root: {err}"))?;
        if !entry.path().is_dir() {
            continue;
        }
        if let Some(value) = entry.file_name().to_str().and_then(|name| name.parse::<u64>().ok()) {
            highest = highest.max(value);
        }
    }
    Ok(format!("{:06}", highest + 1))
}

fn unique_payload_path(dir: &Path, name: &std::ffi::OsStr) -> PathBuf {
    let original = Path::new(name);
    let stem = original.file_stem().unwrap_or(name).to_string_lossy();
    let extension = original.extension().map(|value| format!(".{}", value.to_string_lossy())).unwrap_or_default();
    let mut index = 1usize;
    loop {
        let filename = if index == 1 { format!("{stem}{extension}") } else { format!("{stem}-{index}{extension}") };
        let candidate = dir.join(filename);
        if !candidate.exists() {
            return candidate;
        }
        index += 1;
    }
}

fn create_record(category: &str, display_name: &str, source_paths: Vec<String>) -> Result<String, String> {
    require_folder(category)?;
    let display_name = display_name.trim();
    if display_name.is_empty() {
        return Err("display name is empty".to_string());
    }
    if source_paths.is_empty() {
        return Err("no payload files were dropped".to_string());
    }
    let sources = source_paths
        .into_iter()
        .map(|value| {
            let path = PathBuf::from(value).canonicalize().map_err(|err| format!("failed to resolve payload: {err}"))?;
            if path.is_file() { Ok(path) } else { Err(format!("payload is not a file: {}", path.display())) }
        })
        .collect::<Result<Vec<_>, _>>()?;
    let root = PathBuf::from(db_root()?);
    if !root.is_dir() {
        return Err(format!("DB root not found: {}", root.display()));
    }

    let (id, record) = loop {
        let id = next_record_id(&root)?;
        let record = root.join(&id);
        match fs::create_dir(&record) {
            Ok(()) => break (id, record),
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(format!("failed to create record: {err}")),
        }
    };
    let result = (|| -> Result<(), String> {
        let payload_dir = record.join("payload");
        fs::create_dir(&payload_dir).map_err(|err| format!("failed to create payload directory: {err}"))?;
        let mut payloads = Vec::with_capacity(sources.len());
        for source in sources {
            let filename = source.file_name().ok_or("payload filename is missing")?;
            let destination = unique_payload_path(&payload_dir, filename);
            fs::copy(&source, &destination).map_err(|err| format!("failed to copy payload: {err}"))?;
            payloads.push(format!("payload/{}", destination.file_name().unwrap().to_string_lossy()));
        }
        let metadata = serde_json::json!({
            "category": category,
            "display_name": display_name,
            "payload": payloads,
        });
        let mut text = serde_json::to_string_pretty(&metadata).map_err(|err| format!("failed to serialize metadata: {err}"))?;
        text.push('\n');
        fs::write(settings::metadata_path(&record), text).map_err(|err| format!("failed to write metadata: {err}"))
    })();
    if let Err(err) = result {
        let _ = fs::remove_dir_all(&record);
        return Err(err);
    }
    Ok(id)
}

// Native AppKit shell boundary.  JSON keeps this deliberately small while the
// data model remains owned by Rust; Objective-C only renders and forwards UI
// intent.
fn native_ids(raw: *const c_char) -> Vec<String> {
    if raw.is_null() {
        return Vec::new();
    }
    unsafe { CStr::from_ptr(raw) }
        .to_str()
        .ok()
        .and_then(|text| serde_json::from_str(text).ok())
        .unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn finder_native_catalog_json() -> *mut c_char {
    let text = list_catalog()
        .and_then(|catalog| serde_json::to_string(&catalog).map_err(|err| err.to_string()))
        .unwrap_or_else(|err| serde_json::json!({ "error": err }).to_string());
    CString::new(text).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn finder_native_db_root() -> *mut c_char {
    let root = db_root().unwrap_or_default();
    CString::new(root).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn finder_native_related_json(ids: *const c_char, direct_only: bool) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let ids = native_ids(ids);
        if ids.is_empty() {
            return Err("missing related seed".to_string());
        }
        let related = list_related(ids, direct_only)?;
        serde_json::to_string(&related).map_err(|err| err.to_string())
    })();
    CString::new(result.unwrap_or_else(|err| serde_json::json!({ "error": err }).to_string())).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn finder_native_payloads_json(kind: *const c_char, ids: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        if kind.is_null() {
            return Err("missing payload kind".to_string());
        }
        let kind = unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned();
        require_folder(&kind)?;
        let root = PathBuf::from(db_root()?);
        let paths = native_ids(ids)
            .iter()
            .map(|id| find_payloads(&root, id))
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .map(|path| path.to_string_lossy().to_string())
            .collect::<Vec<_>>();
        serde_json::to_string(&paths).map_err(|err| err.to_string())
    })();
    if let Err(err) = &result {
        eprintln!("[finder-finder-native] payload drag: {err}");
    }
    CString::new(result.unwrap_or_else(|_| "[]".to_string())).unwrap().into_raw()
}

/// Absolute payload file paths to place on the clipboard for a Copy (Cmd-C).
/// When Quick Look is showing, the previewed item's payloads win (matches how
/// `reveal` / `copy` behave); otherwise every payload of every given record id.
#[no_mangle]
pub extern "C" fn finder_native_clipboard_files_json(ids: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let paths: Vec<String> = if let Some(item) = active_ql_item() {
            item.payloads.iter().map(|path| path.to_string_lossy().to_string()).collect()
        } else {
            let root = PathBuf::from(db_root()?);
            native_ids(ids)
                .iter()
                .map(|id| find_payloads(&root, id))
                .collect::<Result<Vec<_>, _>>()?
                .into_iter()
                .flatten()
                .map(|path| path.to_string_lossy().to_string())
                .collect()
        };
        serde_json::to_string(&paths).map_err(|err| err.to_string())
    })();
    if let Err(err) = &result {
        eprintln!("[finder-finder-native] copy files: {err}");
    }
    CString::new(result.unwrap_or_else(|_| "[]".to_string())).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn finder_native_create_record(category: *const c_char, name: *const c_char, paths: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        if category.is_null() || name.is_null() {
            return Err("missing record value".to_string());
        }
        let category = unsafe { CStr::from_ptr(category) }.to_string_lossy().into_owned();
        let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().into_owned();
        let id = create_record(&category, &name, native_ids(paths))?;
        Ok(serde_json::json!({ "id": id }).to_string())
    })();
    CString::new(result.unwrap_or_else(|err| serde_json::json!({ "error": err }).to_string())).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn finder_native_rename(kind: *const c_char, id: *const c_char, name: *const c_char) -> bool {
    let result = (|| -> Result<(), String> {
        if kind.is_null() || id.is_null() || name.is_null() { return Err("missing rename value".to_string()); }
        let kind = unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned();
        let id = unsafe { CStr::from_ptr(id) }.to_string_lossy().into_owned();
        let name = unsafe { CStr::from_ptr(name) }.to_string_lossy().trim().to_string();
        if name.is_empty() { return Err("display name is empty".to_string()); }
        require_folder(&kind)?;
        let path = settings::metadata_path(&record_dir(&PathBuf::from(db_root()?), &id)?);
        let text = fs::read_to_string(&path).map_err(|err| format!("metadata not found: {err}"))?;
        let mut value: Value = serde_json::from_str(&text).map_err(|err| format!("invalid metadata: {err}"))?;
        value.as_object_mut().ok_or("metadata is not a JSON object")?.insert("display_name".to_string(), Value::String(name));
        let mut out = serde_json::to_string_pretty(&value).map_err(|err| format!("serialize failed: {err}"))?;
        out.push('\n'); fs::write(path, out).map_err(|err| format!("failed to write metadata: {err}"))
    })();
    if let Err(err) = result { eprintln!("[finder-finder-native] rename: {err}"); false } else { true }
}

#[no_mangle]
pub unsafe extern "C" fn finder_native_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

fn native_action(kind: *const c_char, ids: *const c_char, action: &str) {
    let kind = if kind.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned()
    };
    let ids = native_ids(ids);
    let result = (|| -> Result<(), String> {
        require_folder(&kind)?;
        let root = PathBuf::from(db_root()?);
        match action {
            "open" => open_files(&ids.iter().map(|id| find_payloads(&root, id)).collect::<Result<Vec<_>, _>>()?.into_iter().flatten().collect::<Vec<_>>()),
            "metadata" => open_files(&ids.iter().map(|id| record_metadata_path(&root, id).and_then(canonical_db_file)).collect::<Result<Vec<_>, _>>()?),
            "reveal" => {
                if let Some(item) = active_ql_item() {
                    reveal_files(&item.payloads)
                } else {
                    reveal_files(&ids.iter().map(|id| record_metadata_path(&root, id).and_then(canonical_db_file)).collect::<Result<Vec<_>, _>>()?)
                }
            }
            "open-ql" => {
                if let Some(item) = active_ql_item() {
                    open_files(&item.payloads)
                } else {
                    Ok(())
                }
            }
            "quicklook" => {
                LAST_QL.lock().unwrap().clear();
                let mut paths = Vec::new();
                let mut items = Vec::new();
                for id in &ids {
                    for (path, name, item) in quicklook_items(&root, id)? {
                        paths.push((path, name));
                        items.push(item);
                    }
                }
                LAST_QL.lock().unwrap().extend(items);
                quicklook_files_native(&paths)
            }
            "copy" => {
                if let Some(item) = active_ql_item() {
                    copy_paths_to_clipboard(&item.payloads)
                } else {
                    copy_record_paths(kind, ids)
                }
            }
            "copy-relative" => {
                if let Some(item) = active_ql_item() {
                    copy_paths_relative_to_db_root(&item.payloads)
                } else {
                    require_folder(&kind)?;
                    copy_paths_relative_to_db_root(&record_paths(&ids)?)
                }
            }
            _ => Ok(()),
        }
    })();
    if let Err(err) = result { eprintln!("[finder-finder-native] {err}"); }
}

#[no_mangle]
pub extern "C" fn finder_native_action(kind: *const c_char, ids: *const c_char, action: *const c_char) {
    if action.is_null() { return; }
    let action = unsafe { CStr::from_ptr(action) }.to_string_lossy();
    native_action(kind, ids, &action);
}

#[cfg(test)]
mod tests {
    use super::{provenance_distances, PROVENANCE_HOPS};
    use std::collections::HashMap;

    fn edges(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }
    fn cats(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, c)| (k.to_string(), c.to_string())).collect()
    }

    #[test]
    fn related_view_may_stay_in_a_category_but_not_return_to_it() {
        // b0(build) - b1(build) - an(analysis) - b2(build)
        let e = edges(&[("b0", "b1"), ("b1", "an"), ("an", "b2")]);
        let c = cats(&[("b0", "build"), ("b1", "build"), ("an", "analysis"), ("b2", "build")]);
        let r = provenance_distances(&"b0".to_string(), &e, &c);
        assert_eq!(r.get("b1"), Some(&1)); // Build -> Build is fine
        assert_eq!(r.get("an"), Some(&2)); // ... -> Analysis is fine
        assert!(!r.contains_key("b2")); // ... -> Build again: returning is not
    }

    #[test]
    fn related_view_cuts_a_fold_back() {
        // d0(data) - r(rawdata) - d1(data)
        let e = edges(&[("d0", "r"), ("r", "d1")]);
        let c = cats(&[("d0", "data"), ("r", "rawdata"), ("d1", "data")]);
        let r = provenance_distances(&"d0".to_string(), &e, &c);
        assert_eq!(r.get("r"), Some(&1));
        assert!(!r.contains_key("d1"));
    }

    #[test]
    fn related_view_keeps_a_direct_reference_of_the_seed_category() {
        // seed and its direct link share a category -> still shown (hop 1)
        let e = edges(&[("s", "x")]);
        let c = cats(&[("s", "build"), ("x", "build")]);
        let r = provenance_distances(&"s".to_string(), &e, &c);
        assert_eq!(r.get("x"), Some(&1));
    }

    #[test]
    fn one_branch_pruning_a_category_does_not_constrain_another() {
        // build -> an_a, an_b ; an_a -> dat ; an_b -> dat -> deeper
        let e = edges(&[
            ("build", "an_a"),
            ("build", "an_b"),
            ("an_a", "dat"),
            ("an_b", "dat"),
            ("dat", "deeper"),
        ]);
        let c = cats(&[
            ("build", "build"),
            ("an_a", "analysis"),
            ("an_b", "analysis"),
            ("dat", "data"),
            ("deeper", "rawdata"),
        ]);
        let r = provenance_distances(&"build".to_string(), &e, &c);
        // dat is reached from both analyses; it is not dropped because one
        // branch already used it
        assert_eq!(r.get("dat"), Some(&2));
        assert_eq!(r.get("deeper"), Some(&3));
    }

    #[test]
    fn related_view_stops_at_the_hop_limit() {
        assert_eq!(PROVENANCE_HOPS, 3);
        let e = edges(&[("a", "b"), ("b", "c"), ("c", "d"), ("d", "z")]);
        let c = cats(&[("a", "0"), ("b", "1"), ("c", "2"), ("d", "3"), ("z", "4")]);
        let r = provenance_distances(&"a".to_string(), &e, &c);
        assert_eq!(r.get("d"), Some(&3));
        assert!(!r.contains_key("z"));
    }
}
