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
use std::collections::{HashMap, VecDeque};
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

const RELATED_HOPS: usize = 1;

/// Direct records named in `seed`'s `links` metadata.
fn related_distances(seed: &NodeKey, edges: &[(NodeKey, NodeKey)]) -> HashMap<NodeKey, usize> {
    let mut adj: HashMap<NodeKey, Vec<NodeKey>> = HashMap::new();
    for (from, to) in edges {
        adj.entry(from.clone()).or_default().push(to.clone());
    }
    let mut dist: HashMap<NodeKey, usize> = HashMap::new();
    dist.insert(seed.clone(), 0);
    let mut queue = VecDeque::new();
    queue.push_back(seed.clone());
    while let Some(node) = queue.pop_front() {
        let hop = dist[&node];
        if hop == RELATED_HOPS {
            continue;
        }
        for next in adj.get(&node).into_iter().flatten() {
            if dist.contains_key(next) {
                continue;
            }
            dist.insert(next.clone(), hop + 1);
            queue.push_back(next.clone());
        }
    }
    dist.remove(seed);
    dist
}

/// The regular related view also includes records that directly point at the
/// seed.  These inbound edges are intentionally not expanded further: they
/// are reverse references, not a second graph traversal.
fn related_distances_with_inbound(seed: &NodeKey, edges: &[(NodeKey, NodeKey)]) -> HashMap<NodeKey, usize> {
    let mut dist = related_distances(seed, edges);
    for (from, to) in edges {
        if to == seed && from != seed {
            dist.entry(from.clone())
                .and_modify(|existing| *existing = (*existing).min(1))
                .or_insert(1);
        }
    }
    dist
}

fn list_related(kind: String, id: String) -> Result<RelatedCatalog, String> {
    require_folder(&kind)?;
    let folders = present_folders()?;
    let root = PathBuf::from(db_root()?);
    let (nodes, edges) = build_graph(&root)?;
    let title = nodes
        .get(&id)
        .map(|entry| entry.title.clone())
        .ok_or_else(|| format!("record not found: {id}"))?;

    let distances = related_distances_with_inbound(&id, &edges);
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

    Ok(RelatedCatalog { title, columns })
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

fn copy_record_paths(kind: String, ids: Vec<String>) -> Result<(), String> {
    require_folder(&kind)?;
    copy_paths_to_clipboard(&record_paths(&ids)?)
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
pub extern "C" fn finder_native_related_json(kind: *const c_char, id: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        if kind.is_null() || id.is_null() { return Err("missing related record".to_string()); }
        let kind = unsafe { CStr::from_ptr(kind) }.to_string_lossy().into_owned();
        let id = unsafe { CStr::from_ptr(id) }.to_string_lossy().into_owned();
        let related = list_related(kind, id)?;
        serde_json::to_string(&related).map_err(|err| err.to_string())
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
    use super::related_distances_with_inbound;

    #[test]
    fn related_view_merges_direct_inbound_edges_without_duplicates() {
        let edges = vec![
            ("data".to_string(), "plot".to_string()),
            ("rawdata".to_string(), "data".to_string()),
            ("plot".to_string(), "data".to_string()),
            ("plot".to_string(), "descendant".to_string()),
        ];
        let distances = related_distances_with_inbound(&"data".to_string(), &edges);
        assert_eq!(distances.get("plot"), Some(&1));
        assert_eq!(distances.get("rawdata"), Some(&1));
        assert_eq!(distances.len(), 2);
        assert!(!distances.contains_key("descendant"));
    }
}
