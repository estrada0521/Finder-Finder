use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::RwLock;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    pub db_root: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            db_root: std::env::var("LAB_BROWSER_DB_ROOT").unwrap_or_else(|_| {
                PathBuf::from(std::env::var("HOME").unwrap_or_default())
                    .join("Documents/Records")
                    .to_string_lossy()
                    .into_owned()
            }),
        }
    }
}

static CACHE: RwLock<Option<AppSettings>> = RwLock::new(None);

pub fn config_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".lab-browser")
}

pub fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Result<AppSettings, String> {
    if let Some(cached) = CACHE.read().unwrap().clone() {
        return Ok(cached);
    }
    let settings = if settings_path().is_file() {
        parse_file(&settings_path())?
    } else {
        let settings = initial_settings();
        save(settings.clone())?;
        settings
    };
    *CACHE.write().unwrap() = Some(settings.clone());
    Ok(settings)
}

pub fn save(mut settings: AppSettings) -> Result<AppSettings, String> {
    normalize(&mut settings)?;
    let dir = config_dir();
    fs::create_dir_all(&dir).map_err(|err| format!("failed to create {}: {err}", dir.display()))?;
    let mut out = serde_json::to_string_pretty(&settings)
        .map_err(|err| format!("failed to serialize settings: {err}"))?;
    out.push('\n');
    fs::write(settings_path(), out).map_err(|err| format!("failed to write settings: {err}"))?;
    *CACHE.write().unwrap() = Some(settings.clone());
    Ok(settings)
}

pub fn folder_label(dir: &str) -> String {
    let mut chars = dir.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => dir.to_string(),
    }
}

pub fn records_dir(root: &Path) -> PathBuf {
    root.to_path_buf()
}

pub fn is_record_id(name: &str) -> bool {
    is_folder_name(name)
}

pub fn metadata_path(dir: &Path) -> PathBuf {
    let metadata = dir.join("metadata.json");
    if metadata.is_file() {
        return metadata;
    }
    let mut jsons = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            if path.is_file()
                && path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .is_some_and(|ext| ext.eq_ignore_ascii_case("json"))
            {
                jsons.push(path);
            }
        }
    }
    jsons.sort();
    jsons.into_iter().next().unwrap_or(metadata)
}

pub fn present_categories() -> Result<Vec<String>, String> {
    let settings = load()?;
    let root = PathBuf::from(&settings.db_root);
    let mut present: BTreeSet<String> = BTreeSet::new();
    let records = records_dir(&root);
    if records.is_dir() {
        let entries = fs::read_dir(&records)
            .map_err(|err| format!("failed to read records dir: {err}"))?;
        for entry in entries {
            let entry = entry.map_err(|err| format!("failed to read records dir: {err}"))?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let meta_path = metadata_path(&path);
            if !meta_path.is_file() {
                continue;
            }
            let text = fs::read_to_string(&meta_path)
                .map_err(|err| format!("failed to read {}: {err}", meta_path.display()))?;
            let value: serde_json::Value = serde_json::from_str(&text)
                .map_err(|err| format!("invalid {}: {err}", meta_path.display()))?;
            if let Some(category) = value.get("category").and_then(|item| item.as_str()) {
                let category = category.trim();
                if is_folder_name(category) {
                    present.insert(category.to_string());
                }
            }
        }
    }
    Ok(present.into_iter().collect())
}

fn parse_file(path: &Path) -> Result<AppSettings, String> {
    let text = fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?;
    let mut settings: AppSettings = serde_json::from_str(&text)
        .map_err(|err| format!("invalid {}: {err}", path.display()))?;
    normalize(&mut settings)?;
    Ok(settings)
}

fn initial_settings() -> AppSettings {
    AppSettings::default()
}

fn normalize(settings: &mut AppSettings) -> Result<(), String> {
    settings.db_root = settings.db_root.trim().to_string();
    if settings.db_root.is_empty() {
        return Err("dbRoot is empty".to_string());
    }
    Ok(())
}

fn is_folder_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && !name.contains('/')
        && !name.contains('\\')
        && name != "."
        && name != ".."
}
