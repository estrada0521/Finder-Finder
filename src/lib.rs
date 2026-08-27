mod settings;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn lab_quicklook_open(paths: *const *const std::ffi::c_char, count: usize);
    fn lab_quicklook_current_index() -> std::os::raw::c_long;
}

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::{c_char, CStr, CString};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

#[derive(Clone, Serialize, Deserialize)]
struct QlItem {
    filename: String,
    record_id: String,
    kind: String,
    payload: PathBuf,
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

fn entry_for(dir: &Path) -> RecordEntry {
    let id = dir.file_name().unwrap().to_string_lossy().to_string();
    let meta = read_json(&settings::metadata_path(dir));
    RecordEntry {
        id: id.clone(),
        title: display_name(&meta, &id),
        payload: output_paths(dir, &meta)
            .ok()
            .and_then(|paths| paths.first().map(|path| path.to_string_lossy().to_string())),
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

fn quicklook_files_native(paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let paths = paths
            .iter()
            .filter_map(|path| CString::new(path.as_os_str().as_encoded_bytes()).ok())
            .collect::<Vec<_>>();
        let ptrs = paths.iter().map(|path| path.as_ptr()).collect::<Vec<_>>();
        // Called from an AppKit action, hence already on the main thread.
        unsafe { lab_quicklook_open(ptrs.as_ptr(), ptrs.len()) };
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Command::new("qlmanage")
            .arg("-p")
            .args(paths)
            .spawn()
            .map_err(|err| format!("failed to quick look files: {err}"))?;
        Ok(())
    }
}

fn stage_named(preview_dir: &Path, stem: &str, src: &Path) -> Result<PathBuf, String> {
    let ext = src.extension().and_then(|ext| ext.to_str()).unwrap_or("");
    let dest = preview_dir.join(if ext.is_empty() {
        stem.to_string()
    } else {
        format!("{stem}.{ext}")
    });
    if fs::hard_link(src, &dest).is_err() {
        fs::copy(src, &dest).map_err(|err| format!("failed to stage preview: {err}"))?;
    }
    Ok(dest)
}

fn preview_dir() -> PathBuf {
    std::env::temp_dir().join("lab-browser-ql")
}

fn preview_filename_stem(display_name: &str, used: &mut HashSet<String>) -> String {
    let base: String = display_name
        .trim()
        .chars()
        .map(|ch| if matches!(ch, '/' | ':' | '\\' | '\0') { '_' } else { ch })
        .collect();
    let base = if base.is_empty() { "Preview".to_string() } else { base };
    let mut stem = base.clone();
    let mut suffix = 2;
    while !used.insert(stem.clone()) {
        stem = format!("{base}-{suffix}");
        suffix += 1;
    }
    stem
}

fn active_ql_item() -> Option<QlItem> {
    let items = LAST_QL.lock().unwrap().clone();
    #[cfg(target_os = "macos")]
    {
        let index = unsafe { lab_quicklook_current_index() };
        if index >= 0 {
            return items.get(index as usize).cloned();
        }
    }
    None
}

fn is_tabular(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| matches!(ext.to_ascii_lowercase().as_str(), "csv" | "dat" | "txt"))
}

fn parse_csv_columns(path: &Path, x_name: &str, y_name: &str) -> Result<(Vec<f64>, Vec<f64>), String> {
    let text = fs::read_to_string(path).map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let mut lines = text.lines();
    let header = lines.next().ok_or_else(|| format!("empty file: {}", path.display()))?;
    let cols: Vec<&str> = header.split(',').map(|item| item.trim()).collect();
    let x_idx = cols.iter().position(|col| *col == x_name).unwrap_or(0);
    let y_idx = cols
        .iter()
        .position(|col| *col == y_name)
        .or_else(|| if cols.len() > 1 { Some(1) } else { None })
        .ok_or_else(|| format!("no y column in {}", path.display()))?;
    let mut xs = Vec::new();
    let mut ys = Vec::new();
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let cells: Vec<&str> = line.split(',').collect();
        let Some(x) = cells.get(x_idx).and_then(|cell| cell.trim().parse::<f64>().ok()) else {
            continue;
        };
        let Some(y) = cells.get(y_idx).and_then(|cell| cell.trim().parse::<f64>().ok()) else {
            continue;
        };
        if x.is_finite() && y.is_finite() {
            xs.push(x);
            ys.push(y);
        }
    }
    if xs.is_empty() {
        return Err(format!("no numeric rows in {}", path.display()));
    }
    Ok((xs, ys))
}

fn downsample(xs: &[f64], ys: &[f64], max_n: usize) -> (Vec<f64>, Vec<f64>) {
    if xs.len() <= max_n {
        return (xs.to_vec(), ys.to_vec());
    }
    let last = xs.len() - 1;
    (0..max_n)
        .map(|i| {
            let j = i * last / (max_n - 1);
            (xs[j], ys[j])
        })
        .unzip()
}

const PREVIEW_W: usize = 960;
const PREVIEW_H: usize = 720;
const PREVIEW_TICKS: usize = 5;

fn format_tick(value: f64, span: f64) -> String {
    let magnitude = value.abs().max(span.abs());
    if magnitude >= 10_000.0 || (magnitude > 0.0 && magnitude < 0.001) {
        return format!("{value:.2e}");
    }
    let step = (span.abs() / (PREVIEW_TICKS - 1) as f64).max(f64::MIN_POSITIVE);
    let decimals = (-step.log10().floor() as i32 + 1).clamp(0, 5) as usize;
    format!("{value:.decimals$}")
}

fn draw_preview_text(ctx: &core_graphics::context::CGContext, text: &str, x: f64, y: f64, size: f64) {
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use core_graphics::sys::CGContextRef;
    use foreign_types::ForeignType;
    use std::ffi::c_void;

    #[link(name = "CoreText", kind = "framework")]
    extern "C" {
        fn CTFontCreateUIFontForLanguage(
            ui_type: u32,
            size: f64,
            language: CFStringRef,
        ) -> *const c_void;
        fn CTLineCreateWithAttributedString(attr: *const c_void) -> *const c_void;
        fn CTLineDraw(line: *const c_void, context: CGContextRef);
        fn CTLineGetTypographicBounds(
            line: *const c_void,
            ascent: *mut f64,
            descent: *mut f64,
            leading: *mut f64,
        ) -> f64;
        static kCTFontAttributeName: CFStringRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFAttributedStringCreate(
            alloc: *const c_void,
            string: CFStringRef,
            attributes: *const c_void,
        ) -> *const c_void;
    }

    const SYSTEM_FONT: u32 = 2;
    let font_ptr = unsafe { CTFontCreateUIFontForLanguage(SYSTEM_FONT, size, std::ptr::null()) };
    if font_ptr.is_null() {
        return;
    }
    let font = unsafe { CFType::wrap_under_create_rule(font_ptr as _) };
    let key = unsafe { CFString::wrap_under_get_rule(kCTFontAttributeName) };
    let attrs = CFDictionary::from_CFType_pairs(&[(key, font)]);
    let cf_text = CFString::new(text);
    let attr = unsafe {
        CFAttributedStringCreate(
            std::ptr::null(),
            cf_text.as_concrete_TypeRef(),
            attrs.as_concrete_TypeRef() as *const c_void,
        )
    };
    if attr.is_null() {
        return;
    }
    let attr = unsafe { CFType::wrap_under_create_rule(attr) };
    let line = unsafe { CTLineCreateWithAttributedString(attr.as_CFTypeRef() as *const c_void) };
    if line.is_null() {
        return;
    }
    let width = unsafe { CTLineGetTypographicBounds(line, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) };
    ctx.set_text_position(x - width / 2.0, y);
    unsafe { CTLineDraw(line, ctx.as_ptr()) };
    drop(unsafe { CFType::wrap_under_create_rule(line as _) });
}

fn write_csv_preview(
    dir: &Path,
    meta: &Value,
    record_id: &str,
    stem: &str,
    csv: &Path,
) -> Result<PathBuf, String> {
    use core_graphics::base::kCGImageAlphaPremultipliedLast;
    use core_graphics::color_space::CGColorSpace;
    use core_graphics::context::{CGContext, CGLineCap, CGLineJoin};
    use core_graphics::geometry::{CGPoint, CGRect, CGSize};

    let x_name = text(meta.get("default_x"));
    let y_name = text(meta.get("default_y"));
    let (xs, ys) = parse_csv_columns(
        csv,
        if x_name.is_empty() { "field_t" } else { &x_name },
        if y_name.is_empty() { "" } else { &y_name },
    )?;
    let (xs, ys) = downsample(&xs, &ys, 1500);
    let x_min = xs.iter().copied().fold(f64::INFINITY, f64::min);
    let x_max = xs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let y_min = ys.iter().copied().fold(f64::INFINITY, f64::min);
    let y_max = ys.iter().copied().fold(f64::NEG_INFINITY, f64::max);
    let map = |v: f64, lo: f64, hi: f64, a: f64, b: f64| {
        if (hi - lo).abs() < 1e-18 {
            (a + b) / 2.0
        } else {
            a + (v - lo) / (hi - lo) * (b - a)
        }
    };
    let w = PREVIEW_W;
    let h = PREVIEW_H;
    let scale = w as f64 / 640.0;
    let left = 90.0 * scale;
    let right = 616.0 * scale;
    let top = 52.0 * scale;
    let bottom = 404.0 * scale;
    let to_cg = |x: f64, y: f64| (x, h as f64 - y);

    let space = CGColorSpace::create_device_rgb();
    let mut ctx = CGContext::create_bitmap_context(
        None,
        w,
        h,
        8,
        0,
        &space,
        kCGImageAlphaPremultipliedLast,
    );
    ctx.set_rgb_fill_color(1.0, 1.0, 1.0, 1.0);
    ctx.fill_rect(CGRect::new(
        &CGPoint::new(0.0, 0.0),
        &CGSize::new(w as f64, h as f64),
    ));

    let (fx, fy) = to_cg(left, bottom);
    ctx.set_rgb_stroke_color(0.73, 0.73, 0.73, 1.0);
    ctx.set_line_width(1.5 * scale);
    ctx.stroke_rect(CGRect::new(
        &CGPoint::new(fx, fy),
        &CGSize::new(right - left, bottom - top),
    ));

    // Five major ticks make a small preview quantitatively useful without
    // turning it into a full plotting application.
    ctx.set_rgb_stroke_color(0.28, 0.28, 0.28, 1.0);
    ctx.set_line_width(1.2 * scale);
    ctx.set_rgb_fill_color(0.12, 0.12, 0.12, 1.0);
    for i in 0..PREVIEW_TICKS {
        let t = i as f64 / (PREVIEW_TICKS - 1) as f64;
        let x = left + (right - left) * t;
        let y = bottom - (bottom - top) * t;
        let x_value = x_min + (x_max - x_min) * t;
        let y_value = y_min + (y_max - y_min) * t;
        let (tick_x, tick_y) = to_cg(x, bottom);
        ctx.begin_path();
        ctx.move_to_point(tick_x, tick_y);
        ctx.add_line_to_point(tick_x, tick_y - 6.0 * scale);
        ctx.stroke_path();
        draw_preview_text(
            &ctx,
            &format_tick(x_value, x_max - x_min),
            x,
            tick_y - 27.0 * scale,
            20.0 * scale,
        );

        let (tick_x, tick_y) = to_cg(left, y);
        ctx.begin_path();
        ctx.move_to_point(tick_x, tick_y);
        ctx.add_line_to_point(tick_x + 6.0 * scale, tick_y);
        ctx.stroke_path();
        draw_preview_text(
            &ctx,
            &format_tick(y_value, y_max - y_min),
            left - 30.0 * scale,
            tick_y - 6.0 * scale,
            20.0 * scale,
        );
    }

    ctx.set_rgb_stroke_color(0.1, 0.1, 0.1, 1.0);
    ctx.set_line_width(3.2 * scale);
    ctx.set_line_join(CGLineJoin::CGLineJoinRound);
    ctx.set_line_cap(CGLineCap::CGLineCapRound);
    ctx.begin_path();
    for (i, (x, y)) in xs.iter().zip(ys.iter()).enumerate() {
        let (px, py) = to_cg(
            map(*x, x_min, x_max, left, right),
            map(*y, y_min, y_max, bottom, top),
        );
        if i == 0 {
            ctx.move_to_point(px, py);
        } else {
            ctx.add_line_to_point(px, py);
        }
    }
    ctx.stroke_path();

    ctx.set_rgb_fill_color(0.1, 0.1, 0.1, 1.0);
    let (mx, my) = downsample(&xs, &ys, 80.min(xs.len()).max(2));
    for (x, y) in mx.iter().zip(my.iter()) {
        let (px, py) = to_cg(
            map(*x, x_min, x_max, left, right),
            map(*y, y_min, y_max, bottom, top),
        );
        ctx.fill_ellipse_in_rect(CGRect::new(
            &CGPoint::new(px - 4.2 * scale, py - 4.2 * scale),
            &CGSize::new(8.4 * scale, 8.4 * scale),
        ));
    }

    ctx.set_rgb_fill_color(0.07, 0.07, 0.07, 1.0);
    let title = display_name(meta, record_id);
    let xlabel = if x_name.is_empty() { "x" } else { x_name.as_str() };
    let ylabel = if y_name.is_empty() { "y" } else { y_name.as_str() };
    draw_preview_text(&ctx, &title, 320.0 * scale, h as f64 - 34.0 * scale, 20.0 * scale);
    draw_preview_text(&ctx, xlabel, 353.0 * scale, 4.0 * scale, 20.0 * scale);
    ctx.save();
    ctx.translate(16.0 * scale, h as f64 - 228.0 * scale);
    ctx.rotate(std::f64::consts::FRAC_PI_2);
    draw_preview_text(&ctx, ylabel, 0.0, 0.0, 20.0 * scale);
    ctx.restore();

    let bpr = ctx.bytes_per_row();
    let src = ctx.data();
    let mut rgba = vec![0u8; w * h * 4];
    for row in 0..h {
        let s = row * bpr;
        rgba[row * w * 4..(row + 1) * w * 4].copy_from_slice(&src[s..s + w * 4]);
    }
    let out = dir.join(format!("{stem}.png"));
    let file = fs::File::create(&out).map_err(|err| format!("failed to write preview: {err}"))?;
    let mut encoder = png::Encoder::new(file, w as u32, h as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder
        .write_header()
        .and_then(|mut writer| writer.write_image_data(&rgba))
        .map_err(|err| format!("failed to encode preview: {err}"))?;
    Ok(out)
}

fn quicklook_payloads(
    root: &Path,
    id: &str,
    preview_dir: &Path,
    used_stems: &mut HashSet<String>,
) -> Result<Vec<PathBuf>, String> {
    let rec = record_dir(root, id)?;
    let meta = read_json(&settings::metadata_path(&rec));
    let kind = text(meta.get("category"));
    let mut out = Vec::new();
    let mut items = Vec::new();
    for path in output_paths(&rec, &meta)? {
        let path = canonical_db_file(path)?;
        let stem = preview_filename_stem(&display_name(&meta, id), used_stems);
        let preview = if is_tabular(&path) {
            match write_csv_preview(preview_dir, &meta, id, &stem, &path) {
                Ok(preview) => preview,
                Err(_) => stage_named(preview_dir, &stem, &path)?,
            }
        } else {
            stage_named(preview_dir, &stem, &path)?
        };
        let filename = preview
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("")
            .to_string();
        items.push(QlItem {
            filename,
            record_id: id.to_string(),
            kind: kind.clone(),
            payload: path,
        });
        out.push(preview);
    }
    LAST_QL.lock().unwrap().extend(items);
    Ok(out)
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
pub extern "C" fn lab_native_catalog_json() -> *mut c_char {
    let text = list_catalog()
        .and_then(|catalog| serde_json::to_string(&catalog).map_err(|err| err.to_string()))
        .unwrap_or_else(|err| serde_json::json!({ "error": err }).to_string());
    CString::new(text).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn lab_native_related_json(kind: *const c_char, id: *const c_char) -> *mut c_char {
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
pub extern "C" fn lab_native_rename(kind: *const c_char, id: *const c_char, name: *const c_char) -> bool {
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
    if let Err(err) = result { eprintln!("[lab-browser-native] rename: {err}"); false } else { true }
}

#[no_mangle]
pub unsafe extern "C" fn lab_native_free_string(value: *mut c_char) {
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
                    reveal_files(&[item.payload])
                } else {
                    reveal_files(&ids.iter().map(|id| record_metadata_path(&root, id).and_then(canonical_db_file)).collect::<Result<Vec<_>, _>>()?)
                }
            }
            "open-ql" => {
                if let Some(item) = active_ql_item() {
                    open_files(&[item.payload])
                } else {
                    Ok(())
                }
            }
            "quicklook" => {
                LAST_QL.lock().unwrap().clear();
                let dir = preview_dir();
                let _ = fs::remove_dir_all(&dir);
                fs::create_dir_all(&dir).map_err(|err| format!("failed to create preview dir: {err}"))?;
                let mut used = HashSet::new();
                let mut paths = Vec::new();
                for id in &ids { paths.extend(quicklook_payloads(&root, id, &dir, &mut used)?); }
                quicklook_files_native(&paths)
            }
            "copy" => {
                if let Some(item) = active_ql_item() {
                    copy_paths_to_clipboard(&[item.payload])
                } else {
                    copy_record_paths(kind, ids)
                }
            }
            _ => Ok(()),
        }
    })();
    if let Err(err) = result { eprintln!("[lab-browser-native] {err}"); }
}

#[no_mangle]
pub extern "C" fn lab_native_action(kind: *const c_char, ids: *const c_char, action: *const c_char) {
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
