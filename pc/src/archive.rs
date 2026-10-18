use crate::store::{Store, now};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::{BufRead, BufReader, Read},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

pub fn agent_dir() -> PathBuf {
    std::env::var_os("PI_CODING_AGENT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".omp/agent")
        })
}
pub fn files(root: &Path) -> Result<Vec<PathBuf>> {
    let metadata = fs::symlink_metadata(root)?;
    if metadata.is_file() {
        return Ok(vec![root.canonicalize()?]);
    }
    if !metadata.is_dir() {
        bail!("Session root must be a regular file or directory, not a symlink");
    }
    let mut pending = vec![(root.to_path_buf(), 0usize)];
    let mut paths = Vec::new();
    let mut entries = 0;
    while let Some((directory, depth)) = pending.pop() {
        for item in fs::read_dir(&directory)
            .with_context(|| format!("Cannot read session directory {}", directory.display()))?
        {
            entries += 1;
            if entries > 20_000 {
                bail!("Session scan exceeds 20,000 entries; select a narrower OMP storage root");
            }
            let item = item?;
            let ty = item.file_type()?;
            if ty.is_dir() && depth < 6 {
                pending.push((item.path(), depth + 1));
            } else if ty.is_file() && item.path().extension().is_some_and(|e| e == "jsonl") {
                paths.push(item.path());
            }
        }
    }
    paths.sort();
    Ok(paths)
}
pub fn load(path: &Path) -> Result<(Value, Vec<Value>)> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.len() > 64 * 1024 * 1024 {
        bail!("Session source must be a regular file of at most 64 MiB");
    }
    // The byte cap also applies while an active writer is growing the source.
    let mut reader = BufReader::new(file.take(64 * 1024 * 1024 + 1));
    let mut header = None;
    let mut records = Vec::new();
    let mut title = String::new();
    let mut total = 0usize;
    loop {
        let mut line = Vec::new();
        let terminated = loop {
            let buffer = reader.fill_buf()?;
            if buffer.is_empty() {
                break false;
            }
            let count = buffer
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(buffer.len(), |index| index + 1);
            if line.len() + count > 4 * 1024 * 1024 {
                bail!("Session JSONL record exceeds 4 MiB");
            }
            line.extend_from_slice(&buffer[..count]);
            let ended = buffer[count - 1] == b'\n';
            reader.consume(count);
            if ended {
                break true;
            }
        };
        if line.is_empty() {
            break;
        }
        total += line.len();
        if total > 64 * 1024 * 1024 || records.len() >= 200_000 {
            bail!("Session source exceeds bounded import capacity");
        }
        let value: Value = match serde_json::from_slice(&line) {
            Ok(value) => value,
            Err(_) if line.iter().all(u8::is_ascii_whitespace) => continue,
            // An active append's partial final record must not prevent the
            // already durable prefix from appearing. Never rewrite its source.
            Err(_) if !terminated => break,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("Invalid completed JSONL record in {}", path.display())
                });
            }
        };
        if value["type"] == "session" {
            header = Some(value.clone());
        }
        if value["type"] == "title" {
            title = value["title"].as_str().unwrap_or_default().to_owned();
        }
        records.push(value);
    }
    let mut header = header.context("File is not an OMP session: no session header")?;
    header["name"] = json!(title);
    Ok((header, records))
}
pub fn message_view(message: &Value, id: &str, timestamp: &Value) -> Value {
    let content = if let Some(s) = message["content"].as_str() {
        json!([{"type":"text","text":s}])
    } else if message["content"].is_array() {
        crate::runtime::public_event(&message["content"])
    } else if message["output"].is_string() {
        json!([{"type":"text","text":message["output"]}])
    } else {
        json!([])
    };
    let timestamp = if let Some(n) = message["timestamp"].as_i64() {
        chrono::DateTime::from_timestamp_millis(n)
            .map(|t| t.to_rfc3339())
            .unwrap_or_else(now)
    } else {
        timestamp.as_str().unwrap_or_default().to_string()
    };
    let mut view = json!({"id":id,"role":message["role"],"content":content,"timestamp":timestamp});
    for key in ["toolCallId", "toolName", "isError", "usage", "stopReason"] {
        if let Some(value) = message.get(key) {
            view[key] = value.clone();
        }
    }
    view
}
pub fn import(store: &Store, path: &Path) -> Result<String> {
    if !fs::symlink_metadata(path)?.is_file() {
        bail!("Session source must not be a symlink or special file");
    }
    let path = path.canonicalize()?;
    let (header, records) = load(&path)?;
    let native_id = header["id"].as_str().context("Session header missing id")?;
    let sessions = store.list("session")?;
    let same_source: Vec<_> = sessions
        .iter()
        .filter(|session| {
            session["sessionFile"]
                .as_str()
                .and_then(|file| Path::new(file).canonicalize().ok())
                .as_deref()
                == Some(path.as_path())
        })
        .collect();
    if let Some(existing) = same_source.iter().find(|session| {
        session["transport"] != "archive"
            && (session["writerConnected"] == true
                || !matches!(
                    session["status"].as_str(),
                    Some("disconnected" | "closed" | "failed")
                ))
    }) {
        return Ok(existing["id"]
            .as_str()
            .context("Live session id missing")?
            .to_owned());
    }
    // Native RPC uses a daemon-owned visible id. Re-importing its saved file
    // must refresh that same session, not create a second native-header row.
    let previous = same_source
        .iter()
        .find(|session| session["transport"] != "archive")
        .copied()
        .or_else(|| same_source.first().copied());
    let id = previous
        .and_then(|session| session["id"].as_str())
        .unwrap_or(native_id);
    if let Some(conflict) = sessions.iter().find(|session| session["id"] == id)
        && !same_source
            .iter()
            .any(|session| session["id"] == conflict["id"])
    {
        bail!(
            "Session id is already associated with another source; refusing to replace its history"
        );
    }
    if previous.is_some_and(|session| {
        session["journalId"]
            .as_str()
            .is_some_and(|expected| expected != native_id)
    }) {
        bail!("Saved source changed native session identity; refusing to replace its history");
    }
    let root = PathBuf::from(
        header["cwd"]
            .as_str()
            .context("Session header missing cwd")?,
    );
    let project = store.register_project(&root, None)?;
    let active = ensure_inactive(store, native_id, &path).is_err();
    let mut session = json!({"id":id,"journalId":native_id,"providerSessionId":null,"bindingRevision":null,"writerConnected":false,"workState":"disconnected","turnError":null,"projectId":project["id"],"name":header["name"],"cwd":project["path"],"transport":"archive","status":if active {"active-unbridged"} else {"closed"},"updatedAt":header["timestamp"],"sessionFile":path,"todos":[],"subagents":[],"capabilities":if active {json!([])} else {json!(["session.resume"])}});
    if let Some(previous) = previous {
        for key in ["model", "thinkingLevel", "lastError"] {
            if !previous[key].is_null() {
                session[key] = previous[key].clone();
            }
        }
        if session["name"].as_str().is_none_or(str::is_empty) {
            session["name"] = previous["name"].clone();
        }
    }
    let mut nodes = HashMap::new();
    let mut leaf = None;
    for record in &records {
        if let Some(rid) = record["id"].as_str() {
            nodes.insert(rid.to_owned(), record);
            leaf = Some(rid.to_owned());
        }
        match record["type"].as_str().unwrap_or_default() {
            "session_info" => {
                if let Some(name) = record["name"].as_str() {
                    session["name"] = json!(name);
                }
            }
            "model_change" => {
                if let Some(model) = record["model"].as_str()
                    && let Some((provider, id)) = model.split_once('/')
                {
                    session["model"] = json!({"provider":provider,"id":id,"name":id});
                }
            }
            "thinking_level_change" => session["thinkingLevel"] = record["thinkingLevel"].clone(),
            _ => {}
        }
        if record["timestamp"].is_string() {
            session["updatedAt"] = record["timestamp"].clone();
        }
    }
    let mut branch = Vec::new();
    let mut seen = std::collections::HashSet::new();
    while let Some(id) = leaf {
        if !seen.insert(id.clone()) {
            bail!("Cyclic session parent graph");
        }
        let Some(node) = nodes.get(&id) else {
            break;
        };
        branch.push(*node);
        leaf = node["parentId"].as_str().map(str::to_owned);
    }
    branch.reverse();
    let mut messages = Vec::new();
    for node in branch {
        if node["type"] == "message" {
            let message = &node["message"];
            let mid = node["id"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| crate::runtime::message_id(id, message));
            let msg = message_view(message, &mid, &node["timestamp"]);
            messages.push(msg);
            if message["role"] == "user"
                && message["synthetic"] != true
                && message["attribution"] != "agent"
            {
                let text = assistant_text(message);
                if !text.trim().is_empty() && !text.trim_start().starts_with('/') {
                    session["lastUserMessage"] = json!(text);
                    session["activityUpdatedAt"] = node["timestamp"].clone();
                }
            }
            if message["role"] == "assistant" && message["stopReason"] == "stop" {
                session["lastAssistantText"] = json!(assistant_text(message));
                session["activityUpdatedAt"] = node["timestamp"].clone();
            }
        }
    }
    store.import_archive(&session, &messages)
}
pub fn assistant_text(message: &Value) -> String {
    if let Some(text) = message["content"].as_str() {
        return text.to_owned();
    }
    message["content"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|b| {
                    if b["type"] == "text" {
                        b["text"].as_str()
                    } else {
                        None
                    }
                })
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Probe the exact Linux abstract lease used by OMP 18.10.2. The runtime
/// acquires this same lease again when resuming, closing the probe/spawn race.
pub fn ensure_inactive(store: &Store, id: &str, path: &Path) -> Result<()> {
    if store.list("session")?.iter().any(|s| {
        s["transport"] != "archive"
            && (s["writerConnected"] == true
                || !matches!(
                    s["status"].as_str(),
                    Some("disconnected" | "closed" | "failed")
                ))
            && (s["id"] == id
                || s["sessionFile"]
                    .as_str()
                    .and_then(|p| Path::new(p).canonicalize().ok())
                    .as_deref()
                    == Some(path))
    }) {
        bail!("Session is already live in Omputer");
    }
    ensure_source_inactive(id, path)
}
pub fn ensure_source_inactive(id: &str, path: &Path) -> Result<()> {
    lease_source(id, path).map(|_| ())
}
pub fn lease_source(id: &str, path: &Path) -> Result<std::os::unix::net::UnixDatagram> {
    if id.is_empty()
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        || id.len() > 128
    {
        bail!("Cannot safely identify this session's native OMP lease; refusing ambiguous resume");
    }
    let home = PathBuf::from(
        std::env::var_os("HOME")
            .context("HOME is needed to inspect native OMP session ownership")?,
    );
    let owners = session_owners_dir(
        &home,
        std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .as_deref(),
        std::env::var_os("PI_CONFIG_DIR").as_deref(),
        std::env::var_os("PI_TEST_SESSION_OWNERS_DIR").map(PathBuf::from),
    );
    let key = owners
        .join(format!("{id}.lock"))
        .to_string_lossy()
        .to_string();
    let high = xxhash_rust::xxh64::xxh64(key.as_bytes(), 0x4f4d_502d_4c4f_434b);
    let low = xxhash_rust::xxh64::xxh64(key.as_bytes(), 0x5049_2d46_494c_454c);
    use std::os::linux::net::SocketAddrExt;
    let addr = std::os::unix::net::SocketAddr::from_abstract_name(format!(
        "omp-file-lock-{high:016x}{low:016x}"
    ))?;
    let probe=std::os::unix::net::UnixDatagram::bind_addr(&addr).context("OMP owns this session's native lease, or its ownership cannot be determined. Do not resume a session already open in a terminal")?;
    // Legacy installations may not use the ownership lease. Active tty crumbs
    // are conservative evidence; a stale crumb is ignored only if its tty is gone.
    let mut terminals = vec![agent_dir().join("terminal-sessions")];
    if let Some(root) = path.parent().and_then(Path::parent) {
        terminals.push(root.join("terminal-sessions"));
    }
    if let Some(state) = std::env::var_os("XDG_STATE_HOME") {
        terminals.push(PathBuf::from(state).join("omp/terminal-sessions"));
    }
    for terminal in terminals {
        if !terminal.is_dir() {
            continue;
        }
        for (index, entry) in fs::read_dir(terminal)?.enumerate() {
            if index >= 512 {
                bail!("Too many terminal ownership records to establish safe resume");
            }
            let entry = entry?;
            let metadata = fs::symlink_metadata(entry.path())?;
            if !metadata.is_file() || metadata.len() > 16 * 1024 {
                bail!("Cannot safely inspect terminal ownership record");
            }
            let name = entry.file_name().to_string_lossy().to_string();
            let tty = PathBuf::from("/dev").join(name.replacen("pts-", "pts/", 1));
            if !tty.exists() {
                continue;
            }
            let file = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(entry.path())?;
            let mut text = String::new();
            file.take(16 * 1024 + 1)
                .read_to_string(&mut text)
                .context("Cannot inspect terminal session ownership")?;
            if text.len() > 16 * 1024 {
                bail!("Terminal ownership record changed while reading");
            }
            if text
                .lines()
                .nth(1)
                .and_then(|p| Path::new(p).canonicalize().ok())
                .as_deref()
                == Some(path)
            {
                bail!(
                    "This session is associated with an existing terminal; close that OMP session before resuming"
                );
            }
        }
    }
    Ok(probe)
}
fn session_owners_dir(
    home: &Path,
    xdg: Option<&Path>,
    config: Option<&std::ffi::OsStr>,
    test: Option<PathBuf>,
) -> PathBuf {
    if let Some(path) = test.filter(|path| !path.as_os_str().is_empty()) {
        return path;
    }
    if let Some(root) = xdg
        .filter(|path| !path.as_os_str().is_empty())
        .map(|path| path.join("omp"))
        .filter(|path| path.exists())
    {
        return root.join("run/session-owners");
    }
    // node:path.join treats an absolute subsequent segment as a joined segment,
    // unlike PathBuf::join; native PI_CONFIG_DIR is explicitly relative to HOME.
    let name = config
        .filter(|name| !name.is_empty())
        .unwrap_or(std::ffi::OsStr::new(".omp"));
    home.join(Path::new(name).strip_prefix("/").unwrap_or(Path::new(name)))
        .join("run/session-owners")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn saved_managed_session_import_keeps_visible_id_and_rejects_identity_replacement() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("source.jsonl");
        let native = uuid::Uuid::new_v4().to_string();
        let header = json!({"type":"session","id":native,"cwd":temporary.path(),"timestamp":"2026-10-17T10:00:00Z"});
        let message = json!({"type":"message","id":"a","parentId":null,"timestamp":"2026-10-17T10:00:01Z","message":{"role":"user","content":"Saved request"}});
        fs::write(&source, format!("{header}\n{message}\n")).unwrap();
        let store = Store::open(Path::new(":memory:"), "PC".into()).unwrap();
        store.put("session", "managed", &json!({"id":"managed","runtimeSessionId":native,"transport":"rpc","status":"disconnected","sessionFile":source,"name":"My session"}), None).unwrap();
        assert_eq!(import(&store, &source).unwrap(), "managed");
        assert_eq!(store.list("session").unwrap().len(), 1);
        let saved = store.get("session", "managed").unwrap();
        assert_eq!(saved["journalId"], native);
        assert_eq!(saved["name"], "My session");
        assert_eq!(saved["transport"], "archive");
        assert_eq!(
            store.messages("managed", i64::MAX, 50).unwrap()["messages"][0]["id"],
            "a"
        );
        let replacement = json!({"type":"session","id":uuid::Uuid::new_v4(),"cwd":temporary.path(),"timestamp":"2026-10-17T10:00:00Z"});
        fs::write(&source, format!("{replacement}\n")).unwrap();
        assert!(import(&store, &source).is_err());
        assert_eq!(
            store.messages("managed", i64::MAX, 50).unwrap()["messages"][0]["id"],
            "a"
        );
    }
    #[test]
    fn automatic_import_replaces_branch_and_preserves_partial_source() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("source.jsonl");
        let id = uuid::Uuid::new_v4().to_string();
        let header = json!({"type":"session","id":id,"cwd":temporary.path(),"timestamp":"2026-10-17T10:00:00Z"});
        let first = json!({"type":"message","id":"a","parentId":null,"timestamp":"2026-10-17T10:00:01Z","message":{"role":"user","content":"First request","timestamp":1}});
        let removed = json!({"type":"message","id":"b","parentId":"a","timestamp":"2026-10-17T10:00:02Z","message":{"role":"assistant","content":"Removed answer","timestamp":2,"stopReason":"stop"}});
        let initial = format!("{header}\n{first}\n{removed}\n");
        fs::write(&source, &initial).unwrap();
        let store = Store::open(Path::new(":memory:"), "PC".into()).unwrap();
        import(&store, &source).unwrap();
        assert_eq!(
            store.messages(&id, i64::MAX, 50).unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        let replacement = json!({"type":"message","id":"c","parentId":"a","timestamp":"2026-10-17T10:00:03Z","message":{"role":"assistant","content":"Replacement answer","timestamp":3,"stopReason":"stop"}});
        let rewritten = format!("{header}\n{first}\n{replacement}\n{{\"type\":\"message\"");
        fs::write(&source, &rewritten).unwrap();
        import(&store, &source).unwrap();
        let messages = store.messages(&id, i64::MAX, 50).unwrap();
        assert_eq!(messages["messages"].as_array().unwrap().len(), 2);
        assert_eq!(messages["messages"][1]["id"], "c");
        assert!(!messages.to_string().contains("Removed answer"));
        assert_eq!(fs::read_to_string(&source).unwrap(), rewritten);
        assert_eq!(store.list("project").unwrap().len(), 1);
    }
    #[test]
    fn completed_corruption_and_symlink_sources_are_rejected() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("bad.jsonl");
        fs::write(&source, "{broken}\n").unwrap();
        assert!(load(&source).is_err());
        let link = temporary.path().join("linked.jsonl");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        assert!(load(&link).is_err());
    }
    #[test]
    fn session_lease_uses_migrated_xdg_state_even_with_config_override() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let state = tmp.path().join("state");
        fs::create_dir_all(state.join("omp")).unwrap();
        let owners = session_owners_dir(
            &home,
            Some(&state),
            Some(std::ffi::OsStr::new("custom")),
            None,
        );
        assert_eq!(owners, state.join("omp/run/session-owners"));
        use std::os::linux::net::SocketAddrExt;
        let key = owners.join("active.lock").to_string_lossy().to_string();
        let high = xxhash_rust::xxh64::xxh64(key.as_bytes(), 0x4f4d_502d_4c4f_434b);
        let low = xxhash_rust::xxh64::xxh64(key.as_bytes(), 0x5049_2d46_494c_454c);
        let address = std::os::unix::net::SocketAddr::from_abstract_name(format!(
            "omp-file-lock-{high:016x}{low:016x}"
        ))
        .unwrap();
        let lease = std::os::unix::net::UnixDatagram::bind_addr(&address).unwrap();
        assert!(std::os::unix::net::UnixDatagram::bind_addr(&address).is_err());
        drop(lease);
        assert_eq!(
            session_owners_dir(&home, None, Some(std::ffi::OsStr::new("custom")), None),
            home.join("custom/run/session-owners")
        );
    }
}
