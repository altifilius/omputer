use crate::store::{Store, now};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
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
const MAX_HEADER_BYTES: u64 = 4 * 1024 * 1024;

/// Resume identity inspection is independent of the full-history import cap.
/// Only the bounded title slot and header are read from a regular non-symlink file.
pub fn source_header(path: &Path) -> Result<Value> {
    let mut reader = BufReader::new(open_source(path)?.take(MAX_HEADER_BYTES + 1));
    read_header(&mut reader).map(|(_, header)| header)
}

fn open_source(path: &Path) -> Result<fs::File> {
    let metadata = fs::symlink_metadata(path).context("Saved session source is missing or inaccessible")?;
    if !metadata.is_file() {
        bail!("Saved session source must be a regular file, not a symlink");
    }
    let file = fs::OpenOptions::new().read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(path)?;
    let opened = file.metadata()?;
    if !opened.is_file() || opened.dev() != metadata.dev() || opened.ino() != metadata.ino() {
        bail!("Saved session source changed while opening");
    }
    Ok(file)
}

fn read_header(reader: &mut impl BufRead) -> Result<(Vec<u8>, Value)> {
    let mut prefix = Vec::new();
    loop {
        let mut line = Vec::new();
        loop {
            let buffer = reader.fill_buf()?;
            if buffer.is_empty() { bail!("Saved session header is incomplete"); }
            let count = buffer.iter().position(|byte| *byte == b'\n').map_or(buffer.len(), |index| index + 1);
            if prefix.len() + line.len() + count > MAX_HEADER_BYTES as usize {
                bail!("Saved session title and header exceed 4 MiB");
            }
            line.extend_from_slice(&buffer[..count]);
            let complete = buffer[count - 1] == b'\n';
            reader.consume(count);
            if complete { break; }
        }
        let header: Value = serde_json::from_slice(&line).context("Saved session header is invalid")?;
        if prefix.is_empty() && header["type"] == "title" {
            prefix = line;
            continue;
        }
        if header["type"] != "session" || header["id"].as_str().is_none_or(str::is_empty)
            || header["cwd"].as_str().is_none_or(str::is_empty) {
            bail!("Saved source has no valid session identity and project header");
        }
        return Ok((prefix, header));
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResumeEligibility {
    pub reason: &'static str,
    pub message: String,
    pub can_relocate: bool,
}
impl ResumeEligibility {
    fn blocked(reason: &'static str, message: impl Into<String>, can_relocate: bool) -> Self {
        Self { reason, message: message.into(), can_relocate }
    }
    pub fn eligible(&self) -> bool { self.reason == "ready" }
    pub fn apply(&self, session: &mut Value) {
        session["resumeEligibility"] = json!({"eligible":self.eligible(),"reason":self.reason,"message":self.message,"canRelocate":self.can_relocate});
        session["capabilities"] = if self.eligible() { json!(["session.resume"]) }
            else if self.can_relocate { json!(["session.relocate"]) } else { json!([]) };
        if session["transport"] == "archive" {
            session["status"] = json!(if self.reason == "active_owner" { "active-unbridged" } else { "closed" });
        }
    }
}

fn identity_source(session: &Value) -> Result<(PathBuf, Value, String)> {
    let path = PathBuf::from(session["sessionFile"].as_str().context("Saved source path missing")?);
    let header = source_header(&path)?;
    let canonical = path.canonicalize()?;
    if path != canonical { bail!("Saved source path is no longer canonical"); }
    let id = header["id"].as_str().context("Saved journal identity missing")?;
    let expected = session["journalId"].as_str().or(session["runtimeSessionId"].as_str())
        .or_else(|| (session["transport"] == "archive").then(|| session["id"].as_str()).flatten())
        .context("Expected journal identity missing")?;
    if expected != id { bail!("Saved session identity changed; refusing ambiguous resume"); }
    let id = id.to_owned();
    Ok((canonical, header, id))
}

pub fn resume_eligibility(store: &Store, session: &Value) -> ResumeEligibility {
    resume_eligibility_inner(store, session, None)
}

/// Runtime cleanup has already removed its link/child, but has not persisted
/// the disconnected snapshot yet. Trust that snapshot for this visible id
/// only; every other live writer and the native lease remain authoritative.
pub fn resume_eligibility_after_disconnect(store: &Store, session: &Value) -> ResumeEligibility {
    if session["writerConnected"] != false || !matches!(session["status"].as_str(), Some("disconnected" | "closed" | "failed")) {
        return ResumeEligibility::blocked("active_owner", "Session has not disconnected", false);
    }
    resume_eligibility_inner(store, session, session["id"].as_str())
}

fn resume_eligibility_inner(store: &Store, session: &Value, disconnected_id: Option<&str>) -> ResumeEligibility {
    let path = session["sessionFile"].as_str().map(Path::new);
    if path.is_none() || path.is_some_and(|path| matches!(fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound)) {
        return ResumeEligibility::blocked("source_missing", "Saved journal is missing; materialized messages cannot safely reconstruct it", false);
    }
    let (path, header, native_id) = match identity_source(session) {
        Ok(source) => source,
        Err(error) => return ResumeEligibility::blocked("identity_invalid", error.to_string(), false),
    };
    if let Err(error) = ensure_inactive_except(store, &native_id, &path, disconnected_id) {
        return ResumeEligibility::blocked("active_owner", error.to_string(), false);
    }
    let project = session["projectId"].as_str().and_then(|id| store.get("project", id).ok());
    let Some(project) = project else {
        return ResumeEligibility::blocked("project_missing", "Registered project is missing; select an existing registered project", true);
    };
    let roots = [session["cwd"].as_str(), project["path"].as_str(), header["cwd"].as_str()];
    let canonical: Option<Vec<PathBuf>> = roots.iter().map(|root| root.and_then(|root| {
        let path = Path::new(root);
        path.canonicalize().ok().filter(|canonical| canonical.is_dir() && canonical == path)
    })).collect();
    match canonical {
        None => ResumeEligibility::blocked("project_missing", "Original project root is missing or changed; select an existing registered project", true),
        Some(roots) if roots[0] != roots[1] || roots[0] != roots[2] => ResumeEligibility::blocked("project_mismatch", "Saved journal root differs from its registered project; explicit relocation is required", true),
        Some(_) => ResumeEligibility { reason: "ready", message: String::new(), can_relocate: true },
    }
}

/// A staged source and its native writer lease. Drop removes only an
/// uncommitted managed copy. The original journal is never written or removed.
pub struct PreparedResume {
    pub file: PathBuf,
    pub journal_id: String,
    pub project: Value,
    pub session: Value,
    original: Value,
    lease: std::os::unix::net::UnixDatagram,
    staged: bool,
    staged_temporary: Option<PathBuf>,
}
impl PreparedResume {
    /// Parent passes this descriptor via pre_exec (clearing CLOEXEC in the
    /// child only). Native OMP must validate and adopt its exact abstract
    /// socket before loading the journal; never drop then reacquire the lease.
    pub fn lease_fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd;
        self.lease.as_raw_fd()
    }
    /// Commit after native startup validates the inherited lease and source.
    /// Does not replace message history. Keep this guard until cutover ends.
    pub fn commit(&mut self, store: &Store) -> Result<()> {
        let header = source_header(&self.file)?;
        if header["id"] != self.journal_id || header["cwd"] != self.project["path"]
            || self.session["journalId"] != self.journal_id || self.session["cwd"] != self.project["path"]
            || self.session["sessionFile"].as_str() != self.file.to_str()
            || self.file.canonicalize()? != self.file {
            bail!("Prepared source identity or project changed before cutover");
        }
        let root = Path::new(self.project["path"].as_str().context("Prepared project path missing")?);
        if !root.is_dir() || root.canonicalize()? != root { bail!("Prepared project root changed before cutover"); }
        store.commit_resume_source(&self.original, &self.session, &self.project)?;
        self.staged = false;
        Ok(())
    }
}
impl Drop for PreparedResume {
    fn drop(&mut self) {
        if self.staged { let _ = fs::remove_file(&self.file); }
        if let Some(path) = &self.staged_temporary { let _ = fs::remove_file(path); }
    }
}

/// `target_project_id` is an explicitly selected registered project, never an
/// inferred same-basename mapping. `None` requires the original canonical root.
/// `managed_root` must be the daemon's private state directory, not user input.
pub fn prepare_resume(store: &Store, session: &Value, target_project_id: Option<&str>, managed_root: &Path) -> Result<PreparedResume> {
    let (source, mut header, journal_id) = identity_source(session)?;
    ensure_inactive(store, &journal_id, &source)?;
    let lease = lease_source(&journal_id, &source)?;
    // Inspect again under the retained lease rather than trusting a probe.
    let (locked_source, locked_header, locked_id) = identity_source(session)?;
    if locked_source != source || locked_header != header || locked_id != journal_id {
        bail!("Saved source changed during lease acquisition");
    }
    let project_id = target_project_id.or(session["projectId"].as_str()).context("Registered target project is required")?;
    let project = store.get("project", project_id)?;
    let root = PathBuf::from(project["path"].as_str().context("Registered project path missing")?);
    if !root.is_absolute() || !root.is_dir() || root.canonicalize()? != root {
        bail!("Target must be an existing canonical registered project directory");
    }
    let root_text = root.to_str().context("Registered project path is not UTF-8")?;
    if target_project_id.is_none() {
        if session["cwd"] != root_text || header["cwd"] != root_text {
            bail!("Original project root changed; explicitly select a registered relocation target");
        }
    }
    let relocate = session["projectId"] != project_id || session["cwd"] != root_text || header["cwd"] != root_text;
    let mut replacement = session.clone();
    replacement["journalId"] = json!(journal_id);
    replacement["projectId"] = project["id"].clone();
    replacement["cwd"] = json!(root_text);
    replacement["writerConnected"] = json!(false);
    replacement["workState"] = json!("disconnected");
    replacement["status"] = json!("closed");
    replacement["capabilities"] = json!([]);
    replacement["resumeEligibility"] = json!({"eligible":false,"reason":"preparing","message":"Native writer handoff is in progress","canRelocate":false});
    let mut prepared = PreparedResume { file: source.clone(), journal_id, project, session: replacement, original: session.clone(), lease, staged: false, staged_temporary: None };
    if relocate {
        let managed_root = managed_root.canonicalize().context("Private managed state directory missing")?;
        let directory = managed_root.join("relocated-sessions");
        match fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => {},
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {},
            Err(error) => return Err(error.into()),
        }
        let metadata = fs::symlink_metadata(&directory)?;
        if !metadata.is_dir() || metadata.mode() & 0o077 != 0 || directory.canonicalize()? != directory {
            bail!("Managed relocation directory must be private and not a symlink");
        }
        let token = uuid::Uuid::new_v4();
        let temporary = directory.join(format!(".{token}.tmp"));
        let destination = directory.join(format!("{token}.jsonl"));
        let mut output = fs::OpenOptions::new().write(true).create_new(true).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW).open(&temporary)?;
        prepared.file = temporary.clone();
        prepared.staged = true;
        prepared.staged_temporary = Some(temporary.clone());
        let input = open_source(&source)?;
        let before = input.metadata()?;
        const MAX_RELOCATION_BYTES: u64 = 1024 * 1024 * 1024;
        if before.len() > MAX_RELOCATION_BYTES { bail!("Saved source exceeds the 1 GiB relocation limit"); }
        let mut reader = BufReader::new(input);
        let (prefix, copied_header) = read_header(&mut reader)?;
        if copied_header != header { bail!("Saved header changed before copying"); }
        output.write_all(&prefix)?;
        header["cwd"] = json!(root_text);
        serde_json::to_writer(&mut output, &header)?;
        output.write_all(b"\n")?;
        let copied = std::io::copy(&mut reader.by_ref().take(MAX_RELOCATION_BYTES + 1), &mut output)?;
        if copied > MAX_RELOCATION_BYTES { bail!("Saved source grew beyond relocation limit"); }
        let after = reader.get_ref().metadata()?;
        let current = fs::symlink_metadata(&source)?;
        if after.len() != before.len() || after.mtime() != before.mtime() || after.mtime_nsec() != before.mtime_nsec()
            || current.dev() != before.dev() || current.ino() != before.ino() {
            bail!("Saved source changed while copying; no relocation was committed");
        }
        output.sync_all()?;
        // link + unlink publishes atomically without ever overwriting a file.
        fs::hard_link(&temporary, &destination)?;
        prepared.file = destination.clone();
        fs::remove_file(&temporary)?;
        prepared.staged_temporary = None;
        fs::File::open(&directory)?.sync_all()?;
        prepared.session["sessionFile"] = json!(destination);
        if prepared.session["originalSessionFile"].is_null() {
            prepared.session["originalSessionFile"] = json!(source);
        }
        let mut references = prepared.session["sourceReferences"].as_array().cloned().unwrap_or_default();
        if !references.contains(&json!(source)) { references.push(json!(source)); }
        prepared.session["sourceReferences"] = json!(references);
    }
    Ok(prepared)
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
            if header.is_some() || records.len() > 1 || records.iter().any(|record: &Value| record["type"] != "title") {
                bail!("Session header must follow only the optional title slot and be the only identity record");
            }
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
    // An immutable original remains discoverable after relocation. It is
    // provenance, not a second archive and must never replace the new source.
    if let Some(existing) = sessions.iter().find(|session| {
        session["journalId"] == native_id && session["sessionFile"].as_str() != path.to_str()
            && (session["originalSessionFile"].as_str() == path.to_str()
                || session["sourceReferences"].as_array().is_some_and(|references| references.iter().any(|reference| reference.as_str() == path.to_str())))
    }) {
        return Ok(existing["id"].as_str().context("Relocated session id missing")?.to_owned());
    }
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
    let project = store.register_archive_project(&root)?;
    let mut session = json!({"id":id,"journalId":native_id,"providerSessionId":null,"bindingRevision":null,"writerConnected":false,"workState":"disconnected","turnError":null,"projectId":project["id"],"name":header["name"],"cwd":project["path"],"transport":"archive","status":"closed","updatedAt":header["timestamp"],"sessionFile":path,"todos":[],"subagents":[],"capabilities":[]});
    resume_eligibility(store, &session).apply(&mut session);
    if let Some(previous) = previous {
        for key in ["model", "thinkingLevel", "lastError", "originalSessionFile", "sourceReferences"] {
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
    ensure_inactive_except(store, id, path, None)
}

fn ensure_inactive_except(store: &Store, id: &str, path: &Path, disconnected_id: Option<&str>) -> Result<()> {
    if store.list("session")?.iter().any(|s| {
        !disconnected_id.is_some_and(|ignored| s["id"] == ignored) && s["transport"] != "archive"
            && (s["writerConnected"] == true
                || !matches!(
                    s["status"].as_str(),
                    Some("disconnected" | "closed" | "failed")
                ))
            && (s["id"] == id || s["journalId"] == id || s["runtimeSessionId"] == id
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
    fn relocation_fixture() -> (tempfile::TempDir, Store, Value, Value, Vec<u8>) {
        let temporary = tempfile::tempdir().unwrap();
        let old = temporary.path().join("old");
        let target = temporary.path().join("new");
        fs::create_dir(&old).unwrap();
        fs::create_dir(&target).unwrap();
        let source = temporary.path().join("source.jsonl");
        let id = uuid::Uuid::new_v4().to_string();
        let header = json!({"type":"session","id":id,"cwd":old,"extra":{"kept":true}});
        let bytes = format!("{header}\n{{\"type\":\"message\",\"id\":\"a\",\"parentId\":null,\"message\":{{\"role\":\"user\",\"content\":\"entire history\"}}}}\n{{\"type\":\"message\"").into_bytes();
        fs::write(&source, &bytes).unwrap();
        let store = Store::open(Path::new(":memory:"), "PC".into()).unwrap();
        import(&store, &source).unwrap();
        let session = store.get("session", &id).unwrap();
        let project = store.register_project(&target, None).unwrap();
        fs::remove_dir(&old).unwrap();
        (temporary, store, session, project, bytes)
    }
    #[test]
    fn disconnected_snapshot_ignores_only_its_own_persisted_owner() {
        let (temporary, store, mut session, _, _) = relocation_fixture();
        fs::create_dir(temporary.path().join("old")).unwrap();
        session["transport"] = json!("rpc");
        session["status"] = json!("running");
        session["writerConnected"] = json!(true);
        let id = session["id"].as_str().unwrap().to_owned();
        store.put("session", &id, &session, None).unwrap();
        assert_eq!(resume_eligibility_after_disconnect(&store, &session).reason, "active_owner");
        session["status"] = json!("disconnected");
        session["writerConnected"] = json!(false);
        assert_eq!(resume_eligibility(&store, &session).reason, "active_owner");
        assert_eq!(resume_eligibility_after_disconnect(&store, &session).reason, "ready");
        let mut other = session.clone();
        other["id"] = json!("other-writer");
        other["status"] = json!("running");
        other["writerConnected"] = json!(true);
        store.put("session", "other-writer", &other, None).unwrap();
        assert_eq!(resume_eligibility_after_disconnect(&store, &session).reason, "active_owner");
    }


    #[test]
    fn moved_project_relocation_preserves_original_and_every_tail_byte() {
        let (temporary, store, session, target, bytes) = relocation_fixture();
        let eligibility = resume_eligibility(&store, &session);
        assert_eq!(eligibility.reason, "project_missing");
        assert!(eligibility.can_relocate);
        assert!(prepare_resume(&store, &session, None, temporary.path()).is_err());
        let mut prepared = prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).unwrap();
        let copied = fs::read(&prepared.file).unwrap();
        let original_tail = bytes.iter().position(|byte| *byte == b'\n').unwrap() + 1;
        let copied_tail = copied.iter().position(|byte| *byte == b'\n').unwrap() + 1;
        assert_eq!(&copied[copied_tail..], &bytes[original_tail..]);
        let mut original_header: Value = serde_json::from_slice(&bytes[..original_tail]).unwrap();
        original_header["cwd"] = target["path"].clone();
        assert_eq!(source_header(&prepared.file).unwrap(), original_header);
        assert_eq!(fs::read(session["sessionFile"].as_str().unwrap()).unwrap(), bytes);
        assert!(lease_source(&prepared.journal_id, &prepared.file).is_err());
        let file = prepared.file.clone();
        prepared.commit(&store).unwrap();
        drop(prepared);
        assert!(file.is_file());
        let saved = store.get("session", session["id"].as_str().unwrap()).unwrap();
        assert_eq!(saved["originalSessionFile"], session["sessionFile"]);
        assert_eq!(saved["projectId"], target["id"]);
        assert_eq!(store.messages(session["id"].as_str().unwrap(), i64::MAX, 50).unwrap()["messages"][0]["id"], "a");
        assert_eq!(resume_eligibility(&store, &saved).reason, "ready");
    }

    #[test]
    fn preparation_rejects_missing_source_changed_identity_and_active_lease() {
        let (temporary, store, session, target, bytes) = relocation_fixture();
        let source = Path::new(session["sessionFile"].as_str().unwrap());
        let lease = lease_source(session["journalId"].as_str().unwrap(), source).unwrap();
        assert_eq!(resume_eligibility(&store, &session).reason, "active_owner");
        assert!(prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).is_err());
        drop(lease);
        let mut header = source_header(source).unwrap();
        header["id"] = json!(uuid::Uuid::new_v4().to_string());
        fs::write(source, format!("{header}\n")).unwrap();
        assert_eq!(resume_eligibility(&store, &session).reason, "identity_invalid");
        assert!(prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).is_err());
        fs::write(source, &bytes).unwrap();
        fs::remove_file(source).unwrap();
        assert_eq!(resume_eligibility(&store, &session).reason, "source_missing");
        assert!(prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).is_err());
    }

    #[test]
    fn abandoned_or_stale_preparation_removes_only_staged_copy() {
        let (temporary, store, session, target, bytes) = relocation_fixture();
        let mut prepared = prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).unwrap();
        let file = prepared.file.clone();
        let mut edited = session.clone();
        edited["name"] = json!("User edit wins");
        store.put("session", session["id"].as_str().unwrap(), &edited, None).unwrap();
        assert!(prepared.commit(&store).is_err());
        drop(prepared);
        assert!(!file.exists());
        assert_eq!(fs::read(session["sessionFile"].as_str().unwrap()).unwrap(), bytes);
        assert_eq!(store.get("session", session["id"].as_str().unwrap()).unwrap(), edited);
    }

    #[test]
    fn header_inspection_and_streaming_copy_are_independent_of_import_limit() {
        let (temporary, store, session, target, _) = relocation_fixture();
        let source = Path::new(session["sessionFile"].as_str().unwrap());
        fs::OpenOptions::new().write(true).open(source).unwrap().set_len(65 * 1024 * 1024).unwrap();
        assert!(source_header(source).is_ok());
        assert!(load(source).is_err());
        let prepared = prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).unwrap();
        assert!(fs::metadata(&prepared.file).unwrap().len() > 64 * 1024 * 1024);
    }

    #[test]
    fn native_title_prefix_is_preserved_and_original_reimport_does_not_undo_relocation() {
        let (temporary, store, session, target, bytes) = relocation_fixture();
        let title = b"{\"type\":\"title\", \"title\":\"Original title\", \"padding\":\"  \"}\n";
        let with_title = [title.as_slice(), bytes.as_slice()].concat();
        let source = Path::new(session["sessionFile"].as_str().unwrap());
        fs::write(source, &with_title).unwrap();
        assert_eq!(source_header(source).unwrap()["id"], session["journalId"]);
        assert!(load(source).is_ok());
        let mut prepared = prepare_resume(&store, &session, target["id"].as_str(), temporary.path()).unwrap();
        assert!(fs::read(&prepared.file).unwrap().starts_with(title));
        assert_eq!(fs::read(source).unwrap(), with_title);
        prepared.commit(&store).unwrap();
        let committed = store.get("session", session["id"].as_str().unwrap()).unwrap();
        assert_eq!(import(&store, source).unwrap(), session["id"].as_str().unwrap());
        assert_eq!(store.get("session", session["id"].as_str().unwrap()).unwrap(), committed);
    }

    #[test]
    fn import_keeps_history_when_original_project_is_already_missing() {
        let (temporary, _, session, _, _) = relocation_fixture();
        let store = Store::open(Path::new(":memory:"), "PC".into()).unwrap();
        let id = import(&store, Path::new(session["sessionFile"].as_str().unwrap())).unwrap();
        let saved = store.get("session", &id).unwrap();
        assert_eq!(saved["resumeEligibility"]["reason"], "project_missing");
        assert_eq!(saved["capabilities"], json!(["session.relocate"]));
        assert_eq!(store.messages(&id, i64::MAX, 50).unwrap()["messages"][0]["id"], "a");
        assert!(temporary.path().is_dir());
    }

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
