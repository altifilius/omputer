use crate::{
    archive, security,
    store::{Store, now},
};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::{
    collections::{BTreeSet, HashMap},
    fs,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant, UNIX_EPOCH},
};

const MAX_ENTRIES: usize = 20_000;
const MAX_FILES: usize = 10_000;
const MAX_FILE_BYTES: u64 = 64 * 1024 * 1024;
const IMPORTS_PER_PASS: usize = 32;
const BYTES_PER_PASS: u64 = 256 * 1024 * 1024;

/// Source locations only: no repository crawl, cwd walk, shell execution or
/// provider initialization. Reading .env here never evaluates shell syntax.
/// Only directory-affecting literals are inspected; credentials are not kept.
fn directory_env(root: &Path, target: &mut HashMap<String, String>) {
    let path = root.join(".env");
    let Ok(metadata) = fs::symlink_metadata(&path) else {
        return;
    };
    if !metadata.is_file() || metadata.len() > 64 * 1024 {
        return;
    }
    let Ok(file) = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    else {
        return;
    };
    let mut text = String::new();
    if file.take(64 * 1024 + 1).read_to_string(&mut text).is_err() || text.len() > 64 * 1024 {
        return;
    }
    for line in text.lines() {
        let line = line.trim().strip_prefix("export ").unwrap_or(line.trim());
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if !matches!(
            key,
            "XDG_DATA_HOME" | "XDG_STATE_HOME" | "PI_CODING_AGENT_DIR"
        ) || target.contains_key(key)
        {
            continue;
        }
        let value = value.trim();
        let value = if value.len() >= 2
            && (value.starts_with('"') && value.ends_with('"')
                || value.starts_with('\'') && value.ends_with('\''))
        {
            &value[1..value.len() - 1]
        } else {
            value
        };
        if value.is_empty() || value.contains(['$', '`', '\0']) {
            continue;
        }
        target.insert(key.to_owned(), value.to_owned());
    }
}
fn profile_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && (name.as_bytes()[0].is_ascii_lowercase() || name.as_bytes()[0].is_ascii_digit())
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
        && !name.ends_with('.')
}
fn child_profiles(root: &Path, profiles: &mut BTreeSet<String>) {
    let Ok(entries) = fs::read_dir(root.join("profiles")) else {
        return;
    };
    for entry in entries.take(128).flatten() {
        if entry.file_type().is_ok_and(|ty| ty.is_dir()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if profile_name(&name) {
                profiles.insert(name);
            }
        }
    }
}
pub fn agent_directories() -> Vec<PathBuf> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
    let config = std::env::var_os("PI_CONFIG_DIR")
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| ".omp".into());
    let base = home.join(
        Path::new(&config)
            .strip_prefix("/")
            .unwrap_or(Path::new(&config)),
    );
    let exported = ["XDG_DATA_HOME", "XDG_STATE_HOME", "PI_CODING_AGENT_DIR"]
        .into_iter()
        .filter_map(|key| {
            std::env::var(key)
                .ok()
                .filter(|value| !value.is_empty())
                .map(|value| (key.to_owned(), value))
        })
        .collect();
    resolve_agent_directories(&home, &base, exported)
}

fn absolute_agent(home: &Path, value: &str) -> PathBuf {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        path
    } else {
        home.join(path)
    }
}

fn resolve_agent_directories(
    home: &Path,
    base: &Path,
    mut default_env: HashMap<String, String>,
) -> Vec<PathBuf> {
    let exported = default_env.clone();
    directory_env(base, &mut default_env);
    let default_agent = default_env
        .get("PI_CODING_AGENT_DIR")
        .map(|value| absolute_agent(home, value))
        .unwrap_or_else(|| base.join("agent"));
    directory_env(&default_agent, &mut default_env);
    let default_agent = default_env
        .get("PI_CODING_AGENT_DIR")
        .map(|value| absolute_agent(home, value))
        .unwrap_or_else(|| base.join("agent"));
    let mut roots = BTreeSet::new();
    roots.insert(default_agent.clone());
    let mut profiles = BTreeSet::new();
    child_profiles(base, &mut profiles);
    if let Some(xdg) = default_env.get("XDG_DATA_HOME") {
        let root = PathBuf::from(xdg).join("omp");
        if default_agent == base.join("agent") && root.is_dir() {
            roots.insert(root.clone());
        }
        child_profiles(&root, &mut profiles);
    }
    if let Some(name) = std::env::var("OMP_PROFILE")
        .ok()
        .or_else(|| std::env::var("PI_PROFILE").ok())
        .filter(|name| profile_name(name) && name != "default")
    {
        profiles.insert(name);
    }
    for name in profiles.into_iter().take(128) {
        let root = base.join("profiles").join(&name);
        let mut env = HashMap::new();
        for key in ["XDG_DATA_HOME", "XDG_STATE_HOME"] {
            if let Some(value) = exported.get(key) {
                env.insert(key.into(), value.clone());
            }
        }
        directory_env(&root, &mut env);
        directory_env(&root.join("agent"), &mut env);
        let configured = env
            .get("PI_CODING_AGENT_DIR")
            .map(|value| absolute_agent(home, value))
            .unwrap_or_else(|| root.join("agent"));
        directory_env(&configured, &mut env);
        let configured = env
            .get("PI_CODING_AGENT_DIR")
            .map(|value| absolute_agent(home, value))
            .unwrap_or_else(|| root.join("agent"));
        roots.insert(configured);
        if let Some(xdg) = env.get("XDG_DATA_HOME") {
            let xdg = PathBuf::from(xdg).join("omp/profiles").join(&name);
            if xdg.is_dir() {
                roots.insert(xdg);
            }
        }
    }
    roots.into_iter().take(260).collect()
}

pub fn session_roots() -> Vec<PathBuf> {
    agent_directories()
        .into_iter()
        .map(|root| root.join("sessions"))
        .collect()
}

pub struct ArchiveScanner {
    pass: Mutex<()>,
    stamps: Mutex<HashMap<PathBuf, String>>,
    failures: Mutex<HashMap<PathBuf, (String, Instant, String)>>,
}
impl Default for ArchiveScanner {
    fn default() -> Self {
        Self::new()
    }
}
impl ArchiveScanner {
    pub fn new() -> Self {
        Self {
            pass: Mutex::new(()),
            stamps: Mutex::new(HashMap::new()),
            failures: Mutex::new(HashMap::new()),
        }
    }
    pub fn retry_failed(&self) {
        self.failures.lock().clear();
    }
    pub fn scan(&self, store: &Store) -> Value {
        let _pass = self.pass.lock();
        let roots = session_roots();
        let mut pending = Vec::new();
        let mut missing = Vec::new();
        for root in &roots {
            match fs::symlink_metadata(root) {
                Ok(metadata) if metadata.is_dir() => pending.push((root.clone(), 0usize)),
                Ok(_) => missing.push(root.to_string_lossy().into_owned()),
                Err(_) => missing.push(root.to_string_lossy().into_owned()),
            }
        }
        let mut entries_seen = 0;
        let mut files = BTreeSet::new();
        let mut skipped = 0;
        let mut errors = Vec::new();
        while let Some((directory, depth)) = pending.pop() {
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) => {
                    if errors.len() < 20 {
                        errors.push(format!("{}: {error}", directory.display()));
                    }
                    continue;
                }
            };
            for entry in entries {
                entries_seen += 1;
                if entries_seen > MAX_ENTRIES || files.len() >= MAX_FILES {
                    break;
                }
                let Ok(entry) = entry else {
                    skipped += 1;
                    continue;
                };
                let Ok(kind) = entry.file_type() else {
                    skipped += 1;
                    continue;
                };
                if kind.is_dir() && depth < 6 {
                    pending.push((entry.path(), depth + 1));
                } else if kind.is_file()
                    && entry
                        .path()
                        .extension()
                        .is_some_and(|extension| extension == "jsonl")
                {
                    files.insert(entry.path());
                }
            }
            if entries_seen > MAX_ENTRIES || files.len() >= MAX_FILES {
                break;
            }
        }
        let bounded = entries_seen > MAX_ENTRIES || files.len() >= MAX_FILES;
        let mut stamps = self.stamps.lock();
        stamps.retain(|path, _| files.contains(path));
        let mut failures = self.failures.lock();
        failures.retain(|path, _| files.contains(path));
        let mut imported = 0;
        let mut unchanged = 0;
        let mut deferred = 0;
        let mut attempted = 0;
        let mut bytes = 0;
        for path in &files {
            let metadata = match fs::symlink_metadata(path) {
                Ok(metadata) if metadata.is_file() => metadata,
                _ => {
                    skipped += 1;
                    continue;
                }
            };
            if metadata.len() > MAX_FILE_BYTES {
                skipped += 1;
                continue;
            }
            let mtime = metadata
                .modified()
                .ok()
                .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |value| value.as_nanos());
            let signature = format!(
                "{}:{}:{}:{}",
                metadata.dev(),
                metadata.ino(),
                metadata.len(),
                mtime
            );
            let source_id = security::hash(&path.to_string_lossy());
            if failures
                .get(path)
                .is_some_and(|(previous, attempt, message)| {
                    if previous == &signature && attempt.elapsed() < Duration::from_secs(60) {
                        if errors.len() < 20 {
                            errors.push(message.clone());
                        }
                        true
                    } else {
                        false
                    }
                })
            {
                skipped += 1;
                continue;
            }
            let tracked = store.get("archive-source", &source_id).ok();
            if stamps.get(path) == Some(&signature)
                || tracked
                    .as_ref()
                    .is_some_and(|source| source["signature"] == signature)
            {
                stamps.insert(path.clone(), signature);
                if let Some(id) = tracked
                    .as_ref()
                    .and_then(|source| source["sessionId"].as_str())
                    && let Ok(mut session) = store.get("session", id)
                    && session["transport"] == "archive"
                {
                    let active = archive::ensure_source_inactive(id, path).is_err();
                    let status = if active { "active-unbridged" } else { "closed" };
                    if session["status"] != status {
                        session["status"] = json!(status);
                        session["capabilities"] = if active {
                            json!([])
                        } else {
                            json!(["session.resume"])
                        };
                        let _ = store.put("session", id, &session, Some("session.updated"));
                    }
                }
                unchanged += 1;
                continue;
            }
            if attempted >= IMPORTS_PER_PASS || bytes + metadata.len() > BYTES_PER_PASS {
                deferred += 1;
                continue;
            }
            attempted += 1;
            bytes += metadata.len();
            match archive::import(store, path) {
                Ok(session_id) => {
                    failures.remove(path);
                    // Store only if the same bytes are still present. An active
                    // writer's completed prefix may be shown, and changes retry.
                    if fs::symlink_metadata(path).is_ok_and(|after| {
                        after.ino() == metadata.ino()
                            && after.len() == metadata.len()
                            && after.modified().ok() == metadata.modified().ok()
                    }) {
                        let source =
                            json!({"path":path,"signature":signature,"sessionId":session_id});
                        if let Err(error) = store.put("archive-source", &source_id, &source, None) {
                            if errors.len() < 20 {
                                errors.push(error.to_string());
                            }
                        } else {
                            stamps.insert(path.clone(), signature);
                        }
                    }
                    imported += 1;
                }
                Err(error) => {
                    // Missing cwd/temporarily inaccessible source retries after
                    // sixty seconds, even when the JSONL itself did not change.
                    let message = format!("{}: {error}", path.display());
                    failures.insert(path.clone(), (signature, Instant::now(), message.clone()));
                    skipped += 1;
                    if errors.len() < 20 {
                        errors.push(message);
                    }
                }
            }
        }
        let sessions = store.list("session").unwrap_or_default();
        json!({"scannedAt":now(),"roots":roots,"missingRoots":missing,"files":files.len(),"imported":imported,"unchanged":unchanged,"deferred":deferred,"skipped":skipped,"bounded":bounded,"errors":errors,"archived":sessions.iter().filter(|s|s["transport"]=="archive"&&s["status"]!="active-unbridged").count(),"activeUnbridged":sessions.iter().filter(|s|s["status"]=="active-unbridged").count()})
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn profile_names_cannot_escape_config_roots() {
        for name in ["../other", "/tmp", "Upper", "a/b", ".", "a.", ""] {
            assert!(!profile_name(name));
        }
        for name in ["work", "local-2", "work.home"] {
            assert!(profile_name(name));
        }
    }
    #[test]
    fn configured_profile_agent_roots_are_shared_with_extension_installation() {
        let temporary = tempfile::tempdir().unwrap();
        let home = temporary.path();
        let config = home.join("custom");
        let profile = config.join("profiles/work");
        fs::create_dir_all(&profile).unwrap();
        fs::write(profile.join(".env"), "PI_CODING_AGENT_DIR=private-agent\n").unwrap();
        let roots = resolve_agent_directories(home, &config, HashMap::new());
        assert!(roots.contains(&config.join("agent")));
        assert!(roots.contains(&home.join("private-agent")));
        assert!(!roots.contains(&home.join(".omp/agent")));
        let exported = HashMap::from([(
            "PI_CODING_AGENT_DIR".to_owned(),
            home.join("direct-agent").to_string_lossy().into_owned(),
        )]);
        let roots = resolve_agent_directories(home, &config, exported);
        assert!(roots.contains(&home.join("direct-agent")));
        assert!(roots.contains(&home.join("private-agent")));
    }
}
