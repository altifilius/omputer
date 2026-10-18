use crate::{archive, runtime::App};
use anyhow::{Context, Result, bail};
use fs2::FileExt;
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Component, Path, PathBuf},
    sync::OnceLock,
};

const MAX_FILES: usize = 20_000;
const MAX_FILE: u64 = 1024 * 1024 * 1024;
const MAX_TOTAL: u64 = 8 * 1024 * 1024 * 1024;
const IDENTITY_POLICY: &str = "Same computer only: server ID and TLS fingerprint must match. TLS keys, certificates and bridge token are never backed up or replaced. Restore retains current device authorization/revocations, removes pairing challenges, and never replays commands. Source journals are restored as private copies; original journals are never overwritten.";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
    bytes: u64,
    sha256: String,
    source: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: u32,
    id: String,
    created_at: String,
    server_id: String,
    fingerprint: String,
    entries: Vec<Entry>,
}

fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    let info = fs::symlink_metadata(path)?;
    if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } {
        bail!("Backup directory must be an owned directory, not a symlink");
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}
fn open(path: &Path, maximum_bytes: u64) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let info = file.metadata()?;
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.len() > maximum_bytes {
        bail!("Backup input must be a bounded owned regular file");
    }
    Ok(file)
}
fn private_read(path: &Path, bound: u64) -> Result<Vec<u8>> {
    let file = open(path, bound)?;
    if file.metadata()?.mode() & 0o077 != 0 || file.metadata()?.len() > bound {
        bail!("Backup metadata must be private and bounded");
    }
    let mut bytes = Vec::new();
    file.take(bound + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > bound {
        bail!("Backup metadata changed while reading");
    }
    Ok(bytes)
}
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
fn atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("Missing parent")?;
    let temporary = parent.join(format!(".backup-write-{}", uuid::Uuid::new_v4()));
    write_new(&temporary, bytes)?;
    fs::rename(&temporary, path)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}
fn operation_lock(state: &Path) -> Result<File> {
    let path = state.join("backup.lock");
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if !file.metadata()?.is_file()
        || file.metadata()?.uid() != unsafe { libc::geteuid() }
        || file.metadata()?.mode() & 0o077 != 0
    {
        bail!("Unsafe backup lock");
    }
    file.try_lock_exclusive()
        .context("Another backup or restore is in progress")?;
    Ok(file)
}
fn digest_reader(mut file: File, maximum_bytes: u64) -> Result<(u64, String)> {
    let mut hash = Sha256::new();
    let mut total = 0;
    let mut buffer = [0u8; 128 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > maximum_bytes {
            bail!("Backup file exceeds limit");
        }
        hash.update(&buffer[..n]);
    }
    Ok((total, hex::encode(hash.finalize())))
}
fn copy(source: &Path, destination: &Path, maximum_bytes: u64) -> Result<Entry> {
    let mut input = open(source, maximum_bytes)?;
    let mut output = OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(destination)?;
    let mut hash = Sha256::new();
    let mut bytes = 0;
    let mut buffer = [0u8; 128 * 1024];
    loop {
        let n = input.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        bytes += n as u64;
        if bytes > maximum_bytes {
            bail!("Backup file exceeds limit");
        }
        hash.update(&buffer[..n]);
        output.write_all(&buffer[..n])?;
    }
    output.sync_all()?;
    Ok(Entry {
        path: String::new(),
        bytes,
        sha256: hex::encode(hash.finalize()),
        source: None,
    })
}
fn identity(state: &Path) -> Result<(String, String)> {
    let server = String::from_utf8(private_read(&state.join("server-id"), 128)?)?;
    uuid::Uuid::parse_str(server.trim()).context("Invalid server identity")?;
    let cert = private_read(&state.join("certificate.der"), 128 * 1024)?;
    Ok((server.trim().into(), hex::encode(Sha256::digest(cert))))
}
fn database(path: &Path) -> Result<Connection> {
    // SQLite pages the authoritative database; a package/journal byte cap must
    // not prevent an existing user's database from opening or migrating.
    open(path, u64::MAX)?;
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    db.busy_timeout(std::time::Duration::from_secs(10))?;
    Ok(db)
}
fn integrity(path: &Path) -> Result<()> {
    let db = database(path)?;
    let result: String = db.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    if result != "ok" {
        bail!("Backup SQLite integrity check failed");
    }
    for table in ["objects", "messages", "devices", "commands", "journal"] {
        let exists: i64 = db.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?1",
            [table],
            |r| r.get(0),
        )?;
        if exists != 1 {
            bail!("Backup SQLite schema is missing {table}");
        }
    }
    Ok(())
}
fn id_path(state: &Path, id: &str) -> Result<PathBuf> {
    let parsed = uuid::Uuid::parse_str(id).context("Backup identifier must be a UUID")?;
    if parsed.to_string() != id {
        bail!("Backup identifier must be canonical");
    }
    Ok(state.join("backups").join(id))
}
fn validate(state: &Path, id: &str) -> Result<Manifest> {
    let root = id_path(state, id)?;
    let info = fs::symlink_metadata(&root)?;
    if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Unsafe backup directory");
    }
    let manifest: Manifest = serde_json::from_slice(&private_read(
        &root.join("manifest.json"),
        16 * 1024 * 1024,
    )?)?;
    let (server, fingerprint) = identity(state)?;
    if manifest.format != 1
        || manifest.id != id
        || manifest.server_id != server
        || manifest.fingerprint != fingerprint
    {
        bail!(
            "Backup belongs to a different computer or TLS identity; identity transfer is not permitted"
        );
    }
    if manifest.entries.is_empty() || manifest.entries.len() > MAX_FILES {
        bail!("Invalid backup entry count");
    }
    let mut paths = HashSet::new();
    let mut total = 0;
    for entry in &manifest.entries {
        let path = Path::new(&entry.path);
        if path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
            || path.components().count() != 1
            || !paths.insert(&entry.path)
        {
            bail!("Invalid or duplicate backup path");
        }
        if entry.path != "omputer.sqlite"
            && !(entry.path.starts_with("journal-")
                && entry.path.ends_with(".jsonl")
                && entry
                    .source
                    .as_deref()
                    .is_some_and(|s| Path::new(s).is_absolute()))
        {
            bail!("Unknown backup entry");
        }
        let maximum_bytes = if entry.path == "omputer.sqlite" {
            MAX_TOTAL
        } else {
            MAX_FILE
        };
        let file = open(&root.join(path), maximum_bytes)?;
        if file.metadata()?.mode() & 0o077 != 0 {
            bail!("Backup files must be private");
        }
        let (bytes, sha256) = digest_reader(file, maximum_bytes)?;
        if bytes != entry.bytes || sha256 != entry.sha256 {
            bail!("Backup checksum mismatch: {}", entry.path);
        }
        total += bytes;
        if total > MAX_TOTAL {
            bail!("Backup exceeds total size limit");
        }
    }
    if !paths.contains(&"omputer.sqlite".to_owned()) {
        bail!("Backup database missing");
    }
    integrity(&root.join("omputer.sqlite"))?;
    Ok(manifest)
}

/// Caller reserves runtime admission with prepare_update; native journal leases
/// remain held throughout the consistent online SQLite snapshot and journal copy.
pub fn create(app: &App) -> Result<Value> {
    let state = &app.config.state_dir;
    let _lock = operation_lock(state)?;
    let sessions = app.store.list("session")?;
    let mut sources = BTreeMap::new();
    let mut leases = Vec::new();
    let mut lease_ids = HashSet::new();
    for session in sessions {
        let Some(path) = session["sessionFile"].as_str() else {
            continue;
        };
        let path = PathBuf::from(path)
            .canonicalize()
            .context("A saved journal is missing; backup was not created")?;
        if sources.contains_key(&path) {
            continue;
        }
        if sources.len() >= MAX_FILES - 1 {
            bail!("Too many journals for one backup");
        }
        let (header, _) = archive::load(&path)?;
        let id = header["id"]
            .as_str()
            .context("Journal has no native identity")?;
        if lease_ids.insert(id.to_owned()) {
            leases.push(archive::lease_source(id, &path)?);
        }
        sources.insert(path, id.to_owned());
    }
    let id = uuid::Uuid::new_v4().to_string();
    let root = id_path(state, &id)?;
    private_dir(&state.join("backups"))?;
    let stage = state.join("backups").join(format!(".stage-{id}"));
    private_dir(&stage)?;
    let result = (|| -> Result<Value> {
        let target = stage.join("omputer.sqlite");
        let db = database(&state.join("omputer.sqlite"))?;
        db.execute(
            "VACUUM INTO ?1",
            [target.to_str().context("Backup path must be UTF-8")?],
        )?;
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))?;
        File::open(&target)?.sync_all()?;
        integrity(&target)?;
        let (bytes, sha256) = digest_reader(open(&target, MAX_TOTAL)?, MAX_TOTAL)?;
        let mut entries = vec![Entry {
            path: "omputer.sqlite".into(),
            bytes,
            sha256,
            source: None,
        }];
        let mut total = bytes;
        for (index, (source, _)) in sources.iter().enumerate() {
            let name = format!("journal-{index:06}.jsonl");
            let mut entry = copy(source, &stage.join(&name), MAX_FILE)?;
            entry.path = name;
            entry.source = Some(
                source
                    .to_str()
                    .context("Journal path must be UTF-8")?
                    .into(),
            );
            total += entry.bytes;
            if total > MAX_TOTAL {
                bail!("Backup exceeds total size limit");
            }
            entries.push(entry);
        }
        let (server_id, fingerprint) = identity(state)?;
        let manifest = Manifest {
            format: 1,
            id: id.clone(),
            created_at: crate::store::now(),
            server_id,
            fingerprint,
            entries,
        };
        write_new(
            &stage.join("manifest.json"),
            &serde_json::to_vec_pretty(&manifest)?,
        )?;
        File::open(&stage)?.sync_all()?;
        fs::rename(&stage, &root)?;
        File::open(state.join("backups"))?.sync_all()?;
        Ok(
            json!({"id":id,"createdAt":manifest.created_at,"bytes":total,"journals":sources.len(),"identityPolicy":IDENTITY_POLICY}),
        )
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&stage);
    }
    drop(leases);
    result
}
pub fn list(state: &Path) -> Result<Value> {
    let root = state.join("backups");
    let mut items = Vec::new();
    if !root.exists() {
        return Ok(json!({"items":items,"identityPolicy":IDENTITY_POLICY}));
    }
    let info = fs::symlink_metadata(&root)?;
    if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Unsafe backups directory");
    }
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let id = entry.file_name().to_string_lossy().into_owned();
        if uuid::Uuid::parse_str(&id).is_err() {
            continue;
        }
        if items.len() >= 500 {
            bail!("Backup list exceeds 500 entries; archive old backups explicitly");
        }
        let metadata = fs::symlink_metadata(entry.path())?;
        if !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            items.push(json!({"id":id,"valid":false,"error":"Unsafe backup directory"}));
            continue;
        }
        let parsed = private_read(&entry.path().join("manifest.json"), 16 * 1024 * 1024)
            .and_then(|bytes| serde_json::from_slice::<Manifest>(&bytes).map_err(Into::into));
        match parsed {
            Ok(manifest) if manifest.entries.len()<=MAX_FILES => items.push(json!({"id":id,"createdAt":manifest.created_at,"bytes":manifest.entries.iter().fold(0u64,|total,e|total.saturating_add(e.bytes)),"journals":manifest.entries.len().saturating_sub(1),"validation":"Checksums are verified before restore"})),
            _=>items.push(json!({"id":id,"valid":false,"error":"Unreadable or invalid backup manifest"})),
        }
    }
    items.sort_by(|a, b| b["createdAt"].as_str().cmp(&a["createdAt"].as_str()));
    Ok(json!({"items":items,"identityPolicy":IDENTITY_POLICY}))
}
pub fn schedule_restore(state: &Path, id: &str) -> Result<Value> {
    let _lock = operation_lock(state)?;
    validate(state, id)?;
    if state.join("restore-error").exists() {
        fs::remove_file(state.join("restore-error"))?;
    }
    atomic(&state.join("restore.request"), id.as_bytes())?;
    Ok(json!({"scheduled":true,"id":id,"requiresRestart":true,"identityPolicy":IDENTITY_POLICY}))
}

/// Recovery is intentionally conservative: an interrupted cutover rolls back,
/// preserving the attempted database for diagnosis rather than guessing commit.
pub fn recover_interrupted_restore(state: &Path) -> Result<()> {
    if !state.join("restore.cutover").exists() {
        return Ok(());
    }
    let _lock = operation_lock(state)?;
    if state.join("restore.previous.sqlite").exists() {
        if state.join("omputer.sqlite").exists() {
            finish_restore(state, false)?;
        } else {
            fs::rename(
                state.join("restore.previous.sqlite"),
                state.join("omputer.sqlite"),
            )?;
        }
    }
    if state.join("restore.request").exists() {
        fs::rename(
            state.join("restore.request"),
            state.join(format!(
                "restore-interrupted-{}.request",
                uuid::Uuid::new_v4()
            )),
        )?;
    }
    fs::remove_file(state.join("restore.cutover"))?;
    File::open(state)?.sync_all()?;
    Ok(())
}

/// Must run with exclusive daemon.lock, before any Store or server is opened.
/// The request survives failed validation. Original journals and identity stay put.
pub fn apply_pending_restore(state: &Path) -> Result<bool> {
    if !state.join("restore.request").exists() {
        return Ok(false);
    }
    let _lock = operation_lock(state)?;
    let id = String::from_utf8(private_read(&state.join("restore.request"), 128)?)?;
    let manifest = validate(state, &id)?;
    let root = id_path(state, &id)?;
    let current = state.join("omputer.sqlite");
    let current_db = database(&current)?;
    let sessions: Vec<String> = current_db
        .prepare("SELECT body FROM objects WHERE kind='session'")?
        .query_map([], |r| r.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let mut leases = Vec::new();
    let mut source_paths = HashSet::new();
    let mut lease_ids = HashSet::new();
    for body in sessions {
        let session: Value = serde_json::from_str(&body)?;
        if let Some(path) = session["sessionFile"].as_str() {
            let path = PathBuf::from(path);
            if !path.exists() {
                continue;
            }
            let path = path.canonicalize()?;
            if source_paths.insert(path.clone()) {
                let (header, _) = archive::load(&path)?;
                let native = header["id"].as_str().context("Missing journal ID")?;
                if lease_ids.insert(native.to_owned()) {
                    leases.push(archive::lease_source(native, &path)?);
                }
            }
        }
    }
    // Reserve identities present in the backup but absent from current state.
    for entry in &manifest.entries {
        if let Some(source) = &entry.source {
            let path = PathBuf::from(source);
            let (header, _) = archive::load(&root.join(&entry.path))?;
            let lease_id = header["id"]
                .as_str()
                .context("Backup journal has no identity")?;
            if source_paths.insert(path.clone()) && lease_ids.insert(lease_id.to_owned()) {
                leases.push(archive::lease_source(lease_id, &path)?);
            }
        }
    }
    drop(current_db);
    let copies_root = state.join("restored-journals");
    private_dir(&copies_root)?;
    let journals = copies_root.join(format!("{}-{}", id, uuid::Uuid::new_v4()));
    private_dir(&journals)?;
    let staged = state.join(format!(".restore-{}.sqlite", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        copy(&root.join("omputer.sqlite"), &staged, MAX_TOTAL)?;
        let mut db = Connection::open(&staged)?;
        let tx = db.transaction()?;
        for entry in &manifest.entries {
            if let Some(source) = &entry.source {
                let destination = journals.join(&entry.path);
                copy(&root.join(&entry.path), &destination, MAX_FILE)?;
                tx.execute("UPDATE objects SET body=json_set(body,'$.sessionFile',?1,'$.status','disconnected','$.writerConnected',json('false')) WHERE kind='session' AND json_extract(body,'$.sessionFile')=?2", params![destination.to_str().context("Journal path must be UTF-8")?,source])?;
            }
        }
        tx.execute("DELETE FROM devices", [])?;
        let live = database(&current)?;
        let mut statement =
            live.prepare("SELECT id,hash,name,created,revoked,last_seen FROM devices")?;
        let rows = statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, Option<String>>(5)?,
            ))
        })?;
        for row in rows {
            let (id, hash, name, created, revoked, seen) = row?;
            tx.execute("INSERT INTO devices(id,hash,name,created,revoked,last_seen) VALUES(?1,?2,?3,?4,?5,?6)",params![id,hash,name,created,revoked,seen])?;
        }
        drop(statement);
        drop(live);
        tx.execute("DELETE FROM pairs", [])?;
        tx.commit()?;
        db.execute_batch("PRAGMA journal_mode=DELETE;")?;
        drop(db);
        integrity(&staged)?;
        File::open(&staged)?.sync_all()?;
        File::open(&journals)?.sync_all()?;
        // Consolidate current WAL before retaining the rollback image; no Store
        // is open and daemon.lock excludes a second process in this state.
        let live = Connection::open(&current)?;
        live.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")?;
        drop(live);
        let previous = state.join("restore.previous.sqlite");
        if previous.exists() {
            bail!(
                "A previous restore awaits migration confirmation; refusing to overwrite rollback data"
            );
        }
        atomic(&state.join("restore.cutover"), id.as_bytes())?;
        fs::rename(&current, &previous)?;
        if let Err(error) = fs::rename(&staged, &current) {
            fs::rename(&previous, &current)?;
            return Err(error.into());
        }
        File::open(state)?.sync_all()?;
        fs::rename(state.join("restore.request"), state.join("restore.applied"))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&staged);
        if state.join("restore.previous.sqlite").exists() && current.exists() {
            finish_restore(state, false)?;
        }
        let _ = fs::remove_dir_all(&journals);
    }
    drop(leases);
    result?;
    Ok(true)
}
pub fn finish_restore(state: &Path, migration_succeeded: bool) -> Result<()> {
    let previous = state.join("restore.previous.sqlite");
    if !previous.exists() {
        return Ok(());
    }
    if migration_succeeded {
        // Keep the rollback image until the next explicit restore; do not erase userdata.
        fs::rename(
            previous,
            state.join(format!("restore-rollback-{}.sqlite", uuid::Uuid::new_v4())),
        )?;
    } else {
        let failed = state.join(format!("restore-failed-{}.sqlite", uuid::Uuid::new_v4()));
        fs::rename(state.join("omputer.sqlite"), failed)?;
        for suffix in ["omputer.sqlite-wal", "omputer.sqlite-shm"] {
            if state.join(suffix).exists() {
                fs::rename(
                    state.join(suffix),
                    state.join(format!("restore-failed-{}-{suffix}", uuid::Uuid::new_v4())),
                )?;
            }
        }
        fs::rename(previous, state.join("omputer.sqlite"))?;
    }
    if state.join("restore.cutover").exists() {
        fs::remove_file(state.join("restore.cutover"))?;
    }
    File::open(state)?.sync_all()?;
    Ok(())
}

fn component(path: &Path, version: Value) -> Value {
    match File::open(path).and_then(|f| f.metadata().map(|m| (f, m))) {
        Ok((file, metadata)) if metadata.is_file() => match digest_reader(file, MAX_FILE) {
            Ok((bytes, sha256)) => json!({"version":version,"sha256":sha256,"bytes":bytes}),
            Err(_) => json!({"version":version,"available":false}),
        },
        _ => json!({"version":version,"available":false}),
    }
}
fn bridge_digest(root: &Path) -> Result<String> {
    fn visit(root: &Path, dir: &Path, hash: &mut Sha256, count: &mut usize) -> Result<()> {
        let mut entries = fs::read_dir(dir)?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            *count += 1;
            if *count > MAX_FILES {
                bail!("Bridge tree exceeds bound");
            }
            let info = fs::symlink_metadata(entry.path())?;
            if info.is_dir() {
                visit(root, &entry.path(), hash, count)?;
            } else if info.is_file() {
                hash.update(
                    entry
                        .path()
                        .strip_prefix(root)?
                        .as_os_str()
                        .as_encoded_bytes(),
                );
                hash.update([0]);
                let (bytes, digest) = digest_reader(open(&entry.path(), MAX_FILE)?, MAX_FILE)?;
                hash.update(bytes.to_le_bytes());
                hash.update(digest.as_bytes());
            } else {
                bail!("Bridge tree has unsupported entry");
            }
        }
        Ok(())
    }
    let mut hash = Sha256::new();
    visit(root, root, &mut hash, &mut 0)?;
    Ok(hex::encode(hash.finalize()))
}
fn versions(resources: &Path) -> Value {
    fs::read(resources.join("component-versions.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(json!({}))
}
fn resolved_omp(path: &Path) -> PathBuf {
    if path.components().count() > 1 {
        return path.to_owned();
    }
    std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .map(|p| p.join(path))
        .find(|p| p.is_file())
        .unwrap_or_else(|| path.to_owned())
}
/// Upgrade recovery snapshots SQLite online before Store migrations. A failed
/// migration keeps its failed image and restores the exact pre-open database.
pub fn open_store_recovering(state: &Path, name: String) -> Result<crate::store::Store> {
    let path = state.join("omputer.sqlite");
    if !path.exists() {
        return crate::store::Store::open(&path, name);
    }
    let migration_marker = state.join("database-version");
    if fs::read_to_string(&migration_marker).ok().as_deref() == Some(env!("CARGO_PKG_VERSION")) {
        return crate::store::Store::open(&path, name);
    }
    let recovery = state.join(format!(
        "migration-before-{}-{}.sqlite",
        env!("CARGO_PKG_VERSION"),
        uuid::Uuid::new_v4()
    ));
    let db = database(&path)?;
    db.execute(
        "VACUUM INTO ?1",
        [recovery.to_str().context("Recovery path must be UTF-8")?],
    )?;
    drop(db);
    fs::set_permissions(&recovery, fs::Permissions::from_mode(0o600))?;
    File::open(&recovery)?.sync_all()?;
    match crate::store::Store::open(&path, name) {
        Ok(store) => {
            atomic(&migration_marker, env!("CARGO_PKG_VERSION").as_bytes())?;
            Ok(store)
        }
        Err(error) => {
            fs::rename(
                &path,
                state.join(format!("migration-failed-{}.sqlite", uuid::Uuid::new_v4())),
            )?;
            for suffix in ["omputer.sqlite-wal", "omputer.sqlite-shm"] {
                if state.join(suffix).exists() {
                    fs::rename(
                        state.join(suffix),
                        state.join(format!(
                            "migration-failed-{}-{suffix}",
                            uuid::Uuid::new_v4()
                        )),
                    )?;
                }
            }
            fs::rename(&recovery, &path)?;
            File::open(state)?.sync_all()?;
            Err(error).context(
                "Database migration failed; original database restored and failed image retained",
            )
        }
    }
}

pub fn components(app: &App) -> Value {
    static RUNNING: OnceLock<Value> = OnceLock::new();
    let running = RUNNING.get_or_init(|| {
        let executable=std::env::current_exe().unwrap_or_default(); let resources=app.config.bridge.parent().and_then(Path::parent).unwrap_or(Path::new(""));let v=versions(resources);
        json!({"native":component(&executable,json!(env!("CARGO_PKG_VERSION"))),"omp":component(&resolved_omp(&app.config.omp),v["omp"].clone()),"bridge":{"version":v["bridge"],"sha256":app.config.bridge.parent().and_then(|p|bridge_digest(p).ok()),"loading":"Existing terminal bridges retain the version loaded at their own startup."}})
    }).clone();
    let current = app.config.state_dir.join("app/current");
    // Installed resource location is derived from the running release, not from a caller-supplied path.
    let current = app
        .config
        .bridge
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .and_then(Path::parent)
        .and_then(Path::parent)
        .map(|p| p.join("current"))
        .filter(|p| p.exists())
        .unwrap_or(current);
    let resources = current.join("resources");
    let v = versions(&resources);
    static INSTALLED: std::sync::LazyLock<parking_lot::Mutex<Option<(PathBuf, Value)>>> =
        std::sync::LazyLock::new(|| parking_lot::Mutex::new(None));
    let pinned = current.canonicalize().unwrap_or(current.clone());
    let mut cache = INSTALLED.lock();
    if cache.as_ref().is_none_or(|(path, _)| path != &pinned) {
        *cache = Some((
            pinned,
            json!({"native":component(&current.join("omputer"),v["native"].clone()),"omp":component(&resources.join("omp-runtime"),v["omp"].clone()),"bridge":{"version":v["bridge"],"sha256":bridge_digest(&resources.join("bridge")).ok()}}),
        ));
    }
    json!({"running":running,"installed":cache.as_ref().map(|(_,value)|value),"protocol":1})
}
pub async fn diagnosis(app: &App) -> Result<Value> {
    let update = app.update_blockers().await?;
    let blockers = update["blockers"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .map(|b| json!({"kind":b["kind"],"sessionId":b["sessionId"],"reason":b["reason"]}))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(
        json!({"format":1,"createdAt":crate::store::now(),"components":components(app),"update":{"blockers":blockers,"managedRpcSessions":update["managedRpcSessions"],"admittedCommands":update["admittedCommands"],"inflightResponses":update["inflightResponses"],"updatePending":update["updatePending"]},"backups":list(&app.config.state_dir)?,"identityPolicy":IDENTITY_POLICY,"redaction":"No transcript, project content, paths, host environment, bearer tokens, API keys, device names or private certificates are included."}),
    )
}
pub fn export_diagnosis(state: &Path, diagnosis: &Value) -> Result<Value> {
    let root = state.join("diagnostics");
    private_dir(&root)?;
    let path = root.join(format!("diagnosis-{}.json", uuid::Uuid::new_v4()));
    write_new(&path, &serde_json::to_vec_pretty(diagnosis)?)?;
    Ok(json!({"exported":true,"path":path,"redacted":true}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (tempfile::TempDir, std::sync::Arc<App>) {
        let temp = tempfile::tempdir().unwrap();
        let state = temp.path();
        crate::security::initialize(state, &[]).unwrap();
        write_new(
            &state.join("server-id"),
            uuid::Uuid::new_v4().to_string().as_bytes(),
        )
        .unwrap();
        let store = std::sync::Arc::new(
            crate::store::Store::open(&state.join("omputer.sqlite"), "PC".into()).unwrap(),
        );
        let app = App::new(
            store,
            crate::runtime::RuntimeConfig {
                state_dir: state.into(),
                omp: "missing-omp".into(),
                bridge: "missing-bridge".into(),
            },
        );
        (temp, app)
    }
    #[test]
    fn migration_opens_large_sparse_database_without_loading_or_discarding_its_pages() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("omputer.sqlite");
        let store = crate::store::Store::open(&path, "PC".into()).unwrap();
        store
            .put(
                "project",
                "preserved",
                &json!({"id":"preserved","summary":"Existing durable work"}),
                None,
            )
            .unwrap();
        drop(store);
        fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(MAX_FILE + 4096)
            .unwrap();
        let migrated = open_store_recovering(temp.path(), "PC".into()).unwrap();
        assert_eq!(
            migrated.get("project", "preserved").unwrap()["summary"],
            "Existing durable work"
        );
        assert_eq!(
            fs::read_to_string(temp.path().join("database-version")).unwrap(),
            env!("CARGO_PKG_VERSION")
        );
        assert_eq!(
            database(&path)
                .unwrap()
                .query_row("PRAGMA quick_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
    }
    #[test]
    fn snapshot_checksums_detect_tampering_and_identity_mismatch() {
        let (temp, app) = fixture();
        let value = create(&app).unwrap();
        let id = value["id"].as_str().unwrap();
        assert!(validate(temp.path(), id).is_ok());
        let original_id = fs::read(temp.path().join("server-id")).unwrap();
        fs::write(
            temp.path().join("server-id"),
            uuid::Uuid::new_v4().to_string(),
        )
        .unwrap();
        assert!(schedule_restore(temp.path(), id).is_err());
        fs::write(temp.path().join("server-id"), original_id).unwrap();
        fs::write(
            temp.path().join("backups").join(id).join("omputer.sqlite"),
            b"corrupt",
        )
        .unwrap();
        assert!(schedule_restore(temp.path(), id).is_err());
        assert!(!temp.path().join("restore.request").exists());
        assert!(id_path(temp.path(), "../escape").is_err());
    }
    #[test]
    fn restore_preserves_identity_current_revocation_and_original_journal() {
        let (temp, app) = fixture();
        let before = fs::read(temp.path().join("bridge.token")).unwrap();
        let device = app.store.issue_device("test").unwrap();
        let value = create(&app).unwrap();
        let id = value["id"].as_str().unwrap();
        app.store
            .revoke(device["deviceId"].as_str().unwrap())
            .unwrap();
        drop(app);
        schedule_restore(temp.path(), id).unwrap();
        assert!(apply_pending_restore(temp.path()).unwrap());
        finish_restore(temp.path(), true).unwrap();
        assert_eq!(fs::read(temp.path().join("bridge.token")).unwrap(), before);
        let db = database(&temp.path().join("omputer.sqlite")).unwrap();
        let revoked: Option<String> = db
            .query_row("SELECT revoked FROM devices", [], |r| r.get(0))
            .unwrap();
        assert!(revoked.is_some());
    }
    #[test]
    fn rollback_after_failed_migration_retains_both_databases() {
        let (temp, app) = fixture();
        let value = create(&app).unwrap();
        drop(app);
        schedule_restore(temp.path(), value["id"].as_str().unwrap()).unwrap();
        apply_pending_restore(temp.path()).unwrap();
        finish_restore(temp.path(), false).unwrap();
        assert!(integrity(&temp.path().join("omputer.sqlite")).is_ok());
        assert!(!temp.path().join("restore.previous.sqlite").exists());
    }
    #[test]
    fn interrupted_cutover_recovers_original_without_replaying_request() {
        let (temp, app) = fixture();
        let value = create(&app).unwrap();
        drop(app);
        schedule_restore(temp.path(), value["id"].as_str().unwrap()).unwrap();
        atomic(&temp.path().join("restore.cutover"), b"intent").unwrap();
        fs::rename(
            temp.path().join("omputer.sqlite"),
            temp.path().join("restore.previous.sqlite"),
        )
        .unwrap();
        recover_interrupted_restore(temp.path()).unwrap();
        assert!(integrity(&temp.path().join("omputer.sqlite")).is_ok());
        assert!(!temp.path().join("restore.request").exists());
    }
    #[test]
    fn restore_clones_saved_journals_without_overwriting_sources() {
        let (temp, app) = fixture();
        let source = temp.path().join("original.jsonl");
        let native = uuid::Uuid::new_v4().to_string();
        let header = json!({"type":"session","id":native,"cwd":temp.path(),"timestamp":"2026-10-18T00:00:00Z"});
        let original = format!("{header}\n");
        fs::write(&source, &original).unwrap();
        app.store.put("session","saved",&json!({"id":"saved","journalId":native,"sessionFile":source,"transport":"archive","status":"closed"}),None).unwrap();
        let value = create(&app).unwrap();
        drop(app);
        fs::write(&source, format!("{original}\n")).unwrap();
        schedule_restore(temp.path(), value["id"].as_str().unwrap()).unwrap();
        apply_pending_restore(temp.path()).unwrap();
        finish_restore(temp.path(), true).unwrap();
        assert_eq!(
            fs::read_to_string(&source).unwrap(),
            format!("{original}\n")
        );
        let db = database(&temp.path().join("omputer.sqlite")).unwrap();
        let restored:String=db.query_row("SELECT json_extract(body,'$.sessionFile') FROM objects WHERE kind='session' AND id='saved'",[],|r|r.get(0)).unwrap();
        assert_ne!(Path::new(&restored), source);
        assert_eq!(fs::read_to_string(restored).unwrap(), original);
    }
    #[test]
    fn backup_refuses_a_live_native_journal_writer() {
        let (temp, app) = fixture();
        let source = temp.path().join("live.jsonl");
        let native = uuid::Uuid::new_v4().to_string();
        let header = json!({"type":"session","id":native,"cwd":temp.path(),"timestamp":"2026-10-18T00:00:00Z"});
        fs::write(&source, format!("{header}\n")).unwrap();
        app.store.put("session","live",&json!({"id":"live","journalId":native,"sessionFile":source,"transport":"archive","status":"closed"}),None).unwrap();
        let lease = archive::lease_source(&native, &source).unwrap();
        assert!(create(&app).is_err());
        drop(lease);
        assert!(
            list(temp.path()).unwrap()["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
}
