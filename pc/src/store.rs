use crate::security;
use anyhow::{Context, Result, bail};
use chrono::{Duration, Utc};
use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::path::Path;
use uuid::Uuid;

pub fn now() -> String {
    Utc::now().to_rfc3339()
}
fn utf8_prefix(text: &str, bound: usize) -> &str {
    let mut end = text.len().min(bound);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}
fn message_text(value: &Value) -> String {
    if let Some(text) = value.as_str() {
        return text.to_owned();
    }
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter(|v| v["type"] == "text")
                .filter_map(|v| v["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}
fn redact_export(text: &str) -> String {
    let mut private_key = false;
    text.lines()
        .map(|line| {
            let lower = line.to_ascii_lowercase();
            if lower.contains("-----begin") && lower.contains("private key") {
                private_key = true;
            }
            let sensitive = private_key
                || [
                    "bearer ",
                    "api_key",
                    "api-key",
                    "apikey",
                    "access_token",
                    "refresh_token",
                    "password",
                    "passwd",
                    "secret",
                    "authorization:",
                    "sk-",
                    "/home/",
                    "/users/",
                ]
                .iter()
                .any(|needle| lower.contains(needle));
            if lower.contains("-----end") && lower.contains("private key") {
                private_key = false;
            }
            if sensitive { "[REDACTED]" } else { line }
        })
        .collect::<Vec<_>>()
        .join("\n")
}
#[derive(Debug)]
pub struct MemoryConflict;
impl std::fmt::Display for MemoryConflict {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("memory_conflict: project memory changed; reload before editing")
    }
}
impl std::error::Error for MemoryConflict {}
pub struct Store {
    db: Mutex<Connection>,
    pub server_name: String,
}
impl Store {
    pub fn open(path: &Path, name: String) -> Result<Self> {
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(10))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS objects(kind TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(kind,id));
            CREATE TABLE IF NOT EXISTS journal(sequence INTEGER PRIMARY KEY AUTOINCREMENT,body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS messages(sequence INTEGER PRIMARY KEY AUTOINCREMENT,session_id TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,UNIQUE(session_id,id));
            CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id,sequence);
            CREATE TABLE IF NOT EXISTS pairs(hash TEXT PRIMARY KEY,expires TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,hash TEXT UNIQUE NOT NULL,name TEXT NOT NULL,created TEXT NOT NULL,revoked TEXT,last_seen TEXT);
            CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,result TEXT);
            CREATE TABLE IF NOT EXISTS claims(id TEXT PRIMARY KEY,command_id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS journal_messages(session_id TEXT NOT NULL,id TEXT NOT NULL,sequence INTEGER NOT NULL,PRIMARY KEY(session_id,id));
            CREATE TABLE IF NOT EXISTS journal_scan(id INTEGER PRIMARY KEY CHECK(id=1),sequence INTEGER NOT NULL);
            INSERT OR IGNORE INTO journal_scan(id,sequence) VALUES(1,0);")?;
        let has_revision = db
            .prepare("PRAGMA table_info(messages)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|column| column == "revision");
        if !has_revision {
            db.execute(
                "ALTER TABLE messages ADD COLUMN revision INTEGER NOT NULL DEFAULT 0",
                [],
            )?;
        }
        let has_last_seen = db
            .prepare("PRAGMA table_info(devices)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|column| column == "last_seen");
        if !has_last_seen {
            db.execute("ALTER TABLE devices ADD COLUMN last_seen TEXT", [])?;
        }
        let columns = db
            .prepare("PRAGMA table_info(commands)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (name, declaration) in [
            ("request", "TEXT"),
            ("session_id", "TEXT"),
            ("action", "TEXT"),
            ("status", "TEXT NOT NULL DEFAULT 'unknown'"),
            ("created_at", "TEXT"),
            ("updated_at", "TEXT"),
        ] {
            if !columns.iter().any(|column| column == name) {
                db.execute_batch(&format!(
                    "ALTER TABLE commands ADD COLUMN {name} {declaration}"
                ))?;
            }
        }
        db.execute_batch("CREATE INDEX IF NOT EXISTS commands_session ON commands(session_id,created_at);
            CREATE TABLE IF NOT EXISTS command_output(sequence INTEGER PRIMARY KEY AUTOINCREMENT,command_id TEXT NOT NULL REFERENCES commands(id),kind TEXT NOT NULL,text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS command_output_id ON command_output(command_id,sequence);
            CREATE TABLE IF NOT EXISTS command_output_limits(command_id TEXT PRIMARY KEY REFERENCES commands(id),bytes INTEGER NOT NULL DEFAULT 0,items INTEGER NOT NULL DEFAULT 0,truncated INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS command_output_ids(command_id TEXT NOT NULL REFERENCES commands(id),output_id TEXT NOT NULL,PRIMARY KEY(command_id,output_id));
            CREATE TABLE IF NOT EXISTS memory_history(sequence INTEGER PRIMARY KEY AUTOINCREMENT,project_id TEXT NOT NULL,revision INTEGER NOT NULL,origin TEXT NOT NULL,source_session TEXT,created_at TEXT NOT NULL,body TEXT NOT NULL,UNIQUE(project_id,revision));
            CREATE INDEX IF NOT EXISTS memory_history_project ON memory_history(project_id,sequence);
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_search USING fts5(text,tokenize='unicode61');
            CREATE TRIGGER IF NOT EXISTS transcript_search_insert AFTER INSERT ON messages BEGIN INSERT INTO transcript_search(rowid,text) VALUES(new.sequence,new.body); END;
            CREATE TRIGGER IF NOT EXISTS transcript_search_delete AFTER DELETE ON messages BEGIN DELETE FROM transcript_search WHERE rowid=old.sequence; END;
            CREATE TRIGGER IF NOT EXISTS transcript_search_update AFTER UPDATE OF body ON messages BEGIN DELETE FROM transcript_search WHERE rowid=old.sequence; INSERT INTO transcript_search(rowid,text) VALUES(new.sequence,new.body); END;
            CREATE TABLE IF NOT EXISTS store_migrations(name TEXT PRIMARY KEY);
            UPDATE objects SET body=json_set(body,'$.memoryRevision',0) WHERE kind='project' AND json_type(body,'$.memoryRevision') IS NULL;")?;
        // Upgrade existing transcripts once; all later writes maintain the FTS index transactionally.
        if db.query_row(
            "SELECT count(*) FROM store_migrations WHERE name='transcript_search_v1'",
            [],
            |r| r.get::<_, i64>(0),
        )? == 0
        {
            db.execute_batch("BEGIN IMMEDIATE; DELETE FROM transcript_search; INSERT INTO transcript_search(rowid,text) SELECT sequence,body FROM messages; INSERT INTO store_migrations VALUES('transcript_search_v1'); COMMIT;")?;
        }
        let stamp = now();
        let pending = db
            .prepare("SELECT id FROM commands WHERE status='running'")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        db.execute("UPDATE commands SET status=CASE WHEN result IS NULL THEN 'unknown' WHEN json_extract(result,'$.success')=1 THEN 'succeeded' ELSE 'failed' END,created_at=COALESCE(created_at,?1),updated_at=?1 WHERE status='running' OR created_at IS NULL", [&stamp])?;
        for id in pending {
            let operation = Self::command_status_db(&db, &id)?;
            Self::append(
                &db,
                "operation.updated",
                operation["sessionId"].as_str(),
                None,
                &operation,
            )?;
        }
        Ok(Self {
            db: Mutex::new(db),
            server_name: name,
        })
    }
    pub fn get(&self, kind: &str, id: &str) -> Result<Value> {
        let db = self.db.lock();
        let body: Option<String> = db
            .query_row(
                "SELECT body FROM objects WHERE kind=?1 AND id=?2",
                params![kind, id],
                |r| r.get(0),
            )
            .optional()?;
        serde_json::from_str(&body.context(format!("Unknown {kind} {id}"))?).map_err(Into::into)
    }
    pub fn list(&self, kind: &str) -> Result<Vec<Value>> {
        let db = self.db.lock();
        Self::objects(&db, kind)
    }
    fn objects(db: &Connection, kind: &str) -> Result<Vec<Value>> {
        let mut stmt = db.prepare("SELECT body FROM objects WHERE kind=?1 ORDER BY id")?;
        let rows = stmt.query_map([kind], |r| r.get::<_, String>(0))?;
        rows.map(|s| Ok(serde_json::from_str(&s?)?)).collect()
    }
    fn append(
        db: &Connection,
        ty: &str,
        session: Option<&str>,
        project: Option<&str>,
        data: &Value,
    ) -> Result<Value> {
        let event = json!({"type":ty,"sessionId":session,"projectId":project,"data":data,"createdAt":now()});
        db.execute("INSERT INTO journal(body) VALUES(?1)", [event.to_string()])?;
        let mut event = event;
        let sequence = db.last_insert_rowid();
        if ty == "message.upsert"
            && let (Some(session), Some(id)) = (session, data["id"].as_str())
        {
            Self::retain_message_event(db, session, id, sequence)?;
        }
        event["sequence"] = json!(sequence);
        Ok(event)
    }
    fn retain_message_event(db: &Connection, session: &str, id: &str, sequence: i64) -> Result<()> {
        let previous: Option<i64> = db
            .query_row(
                "SELECT sequence FROM journal_messages WHERE session_id=?1 AND id=?2",
                params![session, id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(previous) = previous {
            // A bounded migration may encounter an older row after a new live
            // write. Always retain the newest sequence, never the last scanned.
            db.execute(
                "DELETE FROM journal WHERE sequence=?1 AND sequence<?2",
                params![previous.min(sequence), previous.max(sequence)],
            )?;
        }
        db.execute("INSERT INTO journal_messages(session_id,id,sequence) VALUES(?1,?2,?3) ON CONFLICT(session_id,id) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)", params![session,id,sequence])?;
        Ok(())
    }
    fn compact_journal(db: &mut Connection, limit: usize) -> Result<()> {
        let tx = db.transaction()?;
        let cursor: i64 =
            tx.query_row("SELECT sequence FROM journal_scan WHERE id=1", [], |row| {
                row.get(0)
            })?;
        let mut statement = tx.prepare("SELECT sequence,json_extract(body,'$.type'),CASE WHEN json_extract(body,'$.type')='message.upsert' AND json_type(body,'$.sessionId')='text' AND json_type(body,'$.data.id')='text' THEN json_extract(body,'$.sessionId') END,CASE WHEN json_extract(body,'$.type')='message.upsert' AND json_type(body,'$.data.id')='text' THEN json_extract(body,'$.data.id') END FROM journal WHERE sequence>?1 ORDER BY sequence LIMIT ?2")?;
        let rows = statement
            .query_map(params![cursor, limit], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        let mut watermark = cursor;
        for (sequence, ty, session, id) in rows {
            if ty == "message.upsert"
                && let (Some(session), Some(id)) = (session, id)
            {
                Self::retain_message_event(&tx, &session, &id, sequence)?;
            }
            watermark = sequence;
        }
        if watermark != cursor {
            tx.execute(
                "UPDATE journal_scan SET sequence=?1 WHERE id=1",
                [watermark],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn event(
        &self,
        ty: &str,
        session: Option<&str>,
        project: Option<&str>,
        data: &Value,
    ) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let event = Self::append(&tx, ty, session, project, data)?;
        tx.commit()?;
        Ok(event)
    }
    pub fn put(&self, kind: &str, id: &str, body: &Value, event_type: Option<&str>) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        tx.execute("INSERT INTO objects(kind,id,body) VALUES(?1,?2,?3) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body", params![kind,id,body.to_string()])?;
        if let Some(ty) = event_type {
            Self::append(
                &tx,
                ty,
                if kind == "session" {
                    Some(id)
                } else {
                    body["sessionId"].as_str()
                },
                if kind == "project" {
                    Some(id)
                } else {
                    body["projectId"].as_str()
                },
                body,
            )?;
        }
        if matches!(kind, "session" | "interaction") {
            Self::refresh_projects(&tx)?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn register_project(&self, path: &Path, name: Option<String>) -> Result<Value> {
        let root = path.canonicalize().context("Project root does not exist")?;
        if !root.is_dir() {
            bail!("Project root must be a directory");
        }
        let text = root.to_string_lossy().to_string();
        if let Some(existing) = self
            .list("project")?
            .into_iter()
            .find(|p| p["path"] == text)
        {
            return Ok(existing);
        }
        let id = Uuid::new_v4().to_string();
        let project = json!({"id":id,"name":name.unwrap_or_else(||root.file_name().unwrap_or_default().to_string_lossy().to_string()),"path":text,"goal":"","summary":"","nextStep":"","decisions":[],"memoryRevision":0,"updatedAt":now(),"sessionCount":0,"pendingCount":0});
        self.put("project", &id, &project, Some("project.updated"))?;
        Ok(project)
    }
    fn refresh_projects(db: &Connection) -> Result<()> {
        let sessions = Self::objects(db, "session")?;
        let interactions = Self::objects(db, "interaction")?;
        for mut project in Self::objects(db, "project")? {
            let before = project.clone();
            project_activity(&mut project, &sessions, &interactions);
            if project != before {
                let id = project["id"].as_str().context("Project id missing")?;
                db.execute(
                    "UPDATE objects SET body=?2 WHERE kind='project' AND id=?1",
                    params![id, project.to_string()],
                )?;
                Self::append(db, "project.updated", None, Some(id), &project)?;
            }
        }
        Ok(())
    }
    pub fn checkpoint(&self, session_id: &str, data: &Value) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let raw: String = tx.query_row(
            "SELECT body FROM objects WHERE kind='session' AND id=?1",
            [session_id],
            |r| r.get(0),
        )?;
        let session: Value = serde_json::from_str(&raw)?;
        let project_id = session["projectId"]
            .as_str()
            .context("Session project missing")?;
        let mut project = Self::project_db(&tx, project_id)?;
        if session["cwd"] != project["path"] {
            bail!("Checkpoint session does not belong to its registered project root");
        }
        Self::apply_memory(&tx, &mut project, data, "agent", Some(session_id))?;
        tx.commit()?;
        Ok(project)
    }
    fn project_db(db: &Connection, id: &str) -> Result<Value> {
        let raw: String = db.query_row(
            "SELECT body FROM objects WHERE kind='project' AND id=?1",
            [id],
            |r| r.get(0),
        )?;
        Ok(serde_json::from_str(&raw)?)
    }
    pub fn edit_memory(&self, id: &str, data: &Value) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let mut project = Self::project_db(&tx, id)?;
        Self::apply_memory(&tx, &mut project, data, "manual", None)?;
        tx.commit()?;
        Ok(project)
    }
    fn apply_memory(
        db: &Connection,
        project: &mut Value,
        data: &Value,
        origin: &str,
        source: Option<&str>,
    ) -> Result<()> {
        let fields = data
            .as_object()
            .context("Project memory must be an object")?;
        let expected = data["expectedMemoryRevision"]
            .as_u64()
            .context("expectedMemoryRevision is required")?;
        let revision = project["memoryRevision"].as_u64().unwrap_or(0);
        if expected != revision {
            return Err(MemoryConflict.into());
        }
        let project_id = project["id"].as_str().context("Project id missing")?;
        let initial = json!({"goal":project["goal"],"summary":project["summary"],"nextStep":project["nextStep"],"decisions":project["decisions"],"sourceSessionId":project["sourceSessionId"],"memoryRevision":revision});
        db.execute("INSERT OR IGNORE INTO memory_history(project_id,revision,origin,source_session,created_at,body) VALUES(?1,?2,?3,?4,?5,?6)",params![project_id,revision,project["memoryOrigin"].as_str().unwrap_or("manual"),project["sourceSessionId"].as_str(),project["memoryUpdatedAt"].as_str().unwrap_or_else(||project["updatedAt"].as_str().unwrap_or("")),initial.to_string()])?;
        let mut changed = false;
        for (key, value) in fields {
            match key.as_str() {
                "expectedMemoryRevision" => continue,
                "goal" | "summary" | "nextStep"
                    if value.is_string() && value.as_str().unwrap().len() <= 256 * 1024 => {}
                "decisions"
                    if value.as_array().is_some_and(|a| {
                        a.len() <= 1000
                            && a.iter()
                                .all(|v| v.as_str().is_some_and(|s| s.len() <= 16 * 1024))
                    }) => {}
                "sourceSessionId"
                    if origin == "manual" && (value.is_null() || value.is_string()) =>
                {
                    if let Some(id) = value.as_str() {
                        let raw: String = db.query_row(
                            "SELECT body FROM objects WHERE kind='session' AND id=?1",
                            [id],
                            |r| r.get(0),
                        )?;
                        let session: Value = serde_json::from_str(&raw)?;
                        if session["projectId"] != project["id"] {
                            bail!("Source session must belong to this project");
                        }
                    }
                }
                _ => bail!("Invalid project memory field {key}"),
            }
            changed = true;
            project[key] = value.clone();
        }
        if !changed {
            bail!("At least one memory field is required");
        }
        if let Some(source) = source {
            project["sourceSessionId"] = json!(source);
        }
        project["memoryRevision"] = json!(
            revision
                .checked_add(1)
                .context("Memory revision overflow")?
        );
        project["memoryOrigin"] = json!(origin);
        project["updatedAt"] = json!(now());
        project["memoryUpdatedAt"] = project["updatedAt"].clone();
        let id = project["id"].as_str().context("Project id missing")?;
        let memory = json!({"goal":project["goal"],"summary":project["summary"],"nextStep":project["nextStep"],"decisions":project["decisions"],"sourceSessionId":project["sourceSessionId"],"memoryRevision":project["memoryRevision"]});
        db.execute("INSERT INTO memory_history(project_id,revision,origin,source_session,created_at,body) VALUES(?1,?2,?3,?4,?5,?6)",params![id,revision+1,origin,project["sourceSessionId"].as_str(),now(),memory.to_string()])?;
        db.execute(
            "UPDATE objects SET body=?2 WHERE kind='project' AND id=?1",
            params![id, project.to_string()],
        )?;
        Self::append(db, "project.updated", source, Some(id), project)?;
        Ok(())
    }
    pub fn memory_history(&self, id: &str, before: i64, limit: usize) -> Result<Value> {
        let db = self.db.lock();
        Self::project_db(&db, id)?;
        let limit = limit.clamp(1, 100);
        let mut stmt=db.prepare("SELECT sequence,revision,origin,source_session,created_at,body FROM memory_history WHERE project_id=?1 AND sequence<?2 ORDER BY sequence DESC LIMIT ?3")?;
        let mut entries=stmt.query_map(params![id,before,limit+1],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,i64>(1)?,r.get::<_,String>(2)?,r.get::<_,Option<String>>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?)))?
            .map(|row|{let(s,r,o,source,t,body)=row?;Ok(json!({"sequence":s,"revision":r,"origin":o,"sourceSessionId":source,"createdAt":t,"memory":serde_json::from_str::<Value>(&body)?}))}).collect::<Result<Vec<_>>>()?;
        let more = entries.len() > limit;
        entries.truncate(limit);
        let cursor = entries.last().map(|entry| entry["sequence"].clone());
        Ok(json!({"entries":entries,"hasMore":more,"nextCursor":if more {cursor}else{None}}))
    }
    pub fn search(
        &self,
        query: &str,
        project: Option<&str>,
        session: Option<&str>,
        cursor: i64,
        limit: usize,
    ) -> Result<Value> {
        if query.trim().is_empty() || query.len() > 256 {
            bail!("Search query must contain 1–256 bytes");
        }
        let terms: Vec<_> = query
            .split_whitespace()
            .take(16)
            .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
            .collect();
        let expression = terms.join(" AND ");
        let db = self.db.lock();
        let limit = limit.clamp(1, 100);
        let mut stmt=db.prepare("SELECT m.sequence,m.id,m.session_id,s.body,m.body FROM transcript_search JOIN messages m ON m.sequence=transcript_search.rowid JOIN objects s ON s.kind='session' AND s.id=m.session_id WHERE transcript_search MATCH ?1 AND m.sequence>?2 AND (?3 IS NULL OR json_extract(s.body,'$.projectId')=?3) AND (?4 IS NULL OR m.session_id=?4) ORDER BY m.sequence LIMIT ?5")?;
        let rows = stmt
            .query_map(
                params![expression, cursor.max(0), project, session, limit + 1],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let more = rows.len() > limit;
        let mut results = Vec::new();
        let mut next = None;
        for (sequence, message_id, session_id, session_body, body) in rows.into_iter().take(limit) {
            let session: Value = serde_json::from_str(&session_body)?;
            let message: Value = serde_json::from_str(&body)?;
            let text = message_text(&message["content"]);
            let position = text
                .to_lowercase()
                .find(&query.to_lowercase())
                .unwrap_or(0)
                .min(text.len());
            let mut start = position.saturating_sub(100);
            while !text.is_char_boundary(start) {
                start -= 1;
            }
            let snippet = utf8_prefix(&text[start..], 400);
            results.push(json!({"sessionId":session_id,"messageId":message_id,"projectId":session["projectId"],"title":session["title"],"snippet":snippet,"sequence":sequence}));
            next = Some(sequence);
        }
        Ok(json!({"results":results,"hasMore":more,"nextCursor":if more{next}else{None}}))
    }
    pub fn export_session(&self, id: &str, format: &str) -> Result<Value> {
        if !matches!(format, "json" | "markdown") {
            bail!("Export format must be json or markdown");
        }
        let session = self.get("session", id)?;
        let db = self.db.lock();
        let mut stmt=db.prepare("SELECT body FROM messages WHERE session_id=?1 AND json_extract(body,'$.role') IN ('user','assistant','system') ORDER BY sequence LIMIT 2001")?;
        let rows = stmt.query_map([id], |r| r.get::<_, String>(0))?;
        let mut messages = Vec::new();
        let mut bytes = 0;
        let mut truncated = false;
        for row in rows {
            let message: Value = serde_json::from_str(&row?)?;
            if !matches!(
                message["role"].as_str(),
                Some("user" | "assistant" | "system")
            ) {
                continue;
            }
            if messages.len() >= 2000 {
                truncated = true;
                break;
            }
            let content = redact_export(&message_text(&message["content"]));
            let bounded = utf8_prefix(&content, 32 * 1024);
            truncated |= bounded.len() < content.len();
            let item = json!({"id":message["id"],"role":message["role"],"content":bounded});
            let size = item.to_string().len();
            if bytes + size > 768 * 1024 {
                truncated = true;
                break;
            }
            bytes += size;
            messages.push(item);
        }
        let title = redact_export(utf8_prefix(
            session["title"].as_str().unwrap_or("Session"),
            512,
        ));
        let text = if format == "json" {
            serde_json::to_string_pretty(
                &json!({"sessionId":id,"title":title,"redacted":true,"truncated":truncated,"omitted":"Attachments, tool payloads, credentials, host paths and runtime metadata are excluded. Suspected credential lines are redacted.","messages":messages}),
            )?
        } else {
            let mut text = format!(
                "# {}\n\nExport is redacted: attachments, tool payloads, credentials, host paths and runtime metadata are omitted. Suspected credential lines are redacted.\n\n",
                utf8_prefix(&title, 512)
            );
            for message in messages {
                text.push_str(&format!(
                    "## {}\n\n{}\n\n",
                    message["role"].as_str().unwrap_or("message"),
                    message["content"].as_str().unwrap_or("")
                ));
            }
            if truncated {
                text.push_str("[Export truncated at local safety limit]\n");
            }
            text
        };
        let safe_id: String = id
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .take(80)
            .collect();
        Ok(
            json!({"filename":format!("session-{safe_id}.{}",if format=="json"{"json"}else{"md"}),"mimeType":if format=="json"{"application/json"}else{"text/markdown"},"text":text,"redacted":true,"truncated":truncated,"messageLimit":2000,"contentByteLimit":768*1024,"messageByteLimit":32*1024}),
        )
    }
    pub fn snapshot(&self) -> Result<Value> {
        let db = self.db.lock();
        let sequence: i64 =
            db.query_row("SELECT COALESCE(MAX(sequence),0) FROM journal", [], |r| {
                r.get(0)
            })?;
        let sessions = Self::objects(&db, "session")?;
        let interactions = Self::objects(&db, "interaction")?;
        let mut projects = Self::objects(&db, "project")?;
        for p in &mut projects {
            project_activity(p, &sessions, &interactions);
        }
        Ok(
            json!({"sequence":sequence,"serverName":self.server_name,"projects":projects,"sessions":sessions,"interactions":interactions,"devices":Self::devices_db(&db)?}),
        )
    }
    pub fn journal(&self, after: i64, limit: usize) -> Result<Vec<Value>> {
        let mut db = self.db.lock();
        // Reuse the replay batch size as a work bound, not a retention window.
        // Existing large journals compact incrementally; startup never scans
        // their complete JSON bodies or VACUUMs the user's database.
        Self::compact_journal(&mut db, limit)?;
        let mut stmt = db.prepare(
            "SELECT sequence,body FROM journal WHERE sequence>?1 ORDER BY sequence LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![after, limit], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?;
        rows.map(|r| {
            let (seq, body) = r?;
            let mut v: Value = serde_json::from_str(&body)?;
            v["sequence"] = json!(seq);
            Ok(v)
        })
        .collect()
    }
    pub fn message(&self, session: &str, id: &str, message: &Value) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let serialized = message.to_string();
        let existing: Option<(i64, i64, String)> = tx
            .query_row(
                "SELECT sequence,revision,body FROM messages WHERE session_id=?1 AND id=?2",
                params![session, id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((sequence, revision, body)) = &existing
            && body == &serialized
        {
            let mut value = message.clone();
            value["sequence"] = json!(sequence);
            value["revision"] = json!(revision);
            return Ok(value);
        }
        tx.execute("INSERT INTO messages(session_id,id,body,revision) VALUES(?1,?2,?3,1) ON CONFLICT(session_id,id) DO UPDATE SET body=excluded.body,revision=messages.revision+1",params![session,id,serialized])?;
        let (seq, revision): (i64, i64) = tx.query_row(
            "SELECT sequence,revision FROM messages WHERE session_id=?1 AND id=?2",
            params![session, id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        let mut message = message.clone();
        message["sequence"] = json!(seq);
        message["revision"] = json!(revision);
        Self::append(&tx, "message.upsert", Some(session), None, &message)?;
        tx.commit()?;
        Ok(message)
    }
    pub fn replace_messages(&self, session: &str, messages: &[Value]) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        Self::replace_messages_db(&tx, session, messages)?;
        tx.commit()?;
        Ok(())
    }
    fn replace_messages_db(tx: &Connection, session: &str, messages: &[Value]) -> Result<()> {
        let mut statement = tx.prepare(
            "SELECT id,body,sequence,revision FROM messages WHERE session_id=?1 ORDER BY sequence",
        )?;
        let previous = statement
            .query_map([session], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        let mut identities = std::collections::HashSet::new();
        for message in messages {
            let id = message["id"]
                .as_str()
                .context("History message id missing")?;
            if !identities.insert(id) {
                bail!("Native history contains duplicate message identities");
            }
        }
        if previous.len() <= messages.len()
            && previous
                .iter()
                .zip(messages)
                .all(|((id, _, _, _), message)| message["id"].as_str() == Some(id.as_str()))
        {
            for (index, message) in messages.iter().enumerate() {
                let body = message.to_string();
                let id = message["id"].as_str().unwrap();
                let (sequence, revision) = if let Some((_, old, sequence, revision)) =
                    previous.get(index)
                {
                    if old == &body {
                        continue;
                    }
                    tx.execute("UPDATE messages SET body=?3,revision=revision+1 WHERE session_id=?1 AND id=?2", params![session,id,body])?;
                    (*sequence, revision + 1)
                } else {
                    tx.execute(
                        "INSERT INTO messages(session_id,id,body,revision) VALUES(?1,?2,?3,1)",
                        params![session, id, body],
                    )?;
                    (tx.last_insert_rowid(), 1)
                };
                let mut view = message.clone();
                view["sequence"] = json!(sequence);
                view["revision"] = json!(revision);
                Self::append(tx, "message.upsert", Some(session), None, &view)?;
            }
            return Ok(());
        }
        tx.execute("DELETE FROM messages WHERE session_id=?1", [session])?;
        Self::append(
            tx,
            "session.event",
            Some(session),
            None,
            &json!({"type":"transcript_reset"}),
        )?;
        for message in messages {
            let id = message["id"].as_str().unwrap();
            tx.execute(
                "INSERT INTO messages(session_id,id,body,revision) VALUES(?1,?2,?3,1)",
                params![session, id, message.to_string()],
            )?;
            let mut view = message.clone();
            view["sequence"] = json!(tx.last_insert_rowid());
            view["revision"] = json!(1);
            Self::append(tx, "message.upsert", Some(session), None, &view)?;
        }
        Ok(())
    }
    pub(crate) fn import_archive(&self, session: &Value, messages: &[Value]) -> Result<String> {
        let id = session["id"]
            .as_str()
            .context("Archive session id missing")?;
        let path = Path::new(
            session["sessionFile"]
                .as_str()
                .context("Archive source missing")?,
        );
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        // A scanner may finish reading after a resume/bridge registration. The
        // ownership check and materialized history update share one transaction,
        // so stale archive bytes can never overwrite a newly live owner.
        if let Some(live) = Self::objects(&tx, "session")?.into_iter().find(|saved| {
            saved["transport"] != "archive"
                && !matches!(
                    saved["status"].as_str(),
                    Some("disconnected" | "closed" | "failed")
                )
                && (saved["id"] == id
                    || saved["sessionFile"]
                        .as_str()
                        .and_then(|file| Path::new(file).canonicalize().ok())
                        .as_deref()
                        == Some(path))
        }) {
            return Ok(live["id"]
                .as_str()
                .context("Live session id missing")?
                .to_owned());
        }
        Self::replace_messages_db(&tx, id, messages)?;
        tx.execute("INSERT INTO objects(kind,id,body) VALUES('session',?1,?2) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body", params![id,session.to_string()])?;
        Self::append(
            &tx,
            "session.updated",
            Some(id),
            session["projectId"].as_str(),
            session,
        )?;
        Self::refresh_projects(&tx)?;
        tx.commit()?;
        Ok(id.to_owned())
    }
    pub fn messages(&self, session: &str, before: i64, limit: usize) -> Result<Value> {
        let db = self.db.lock();
        let mut stmt=db.prepare("SELECT sequence,revision,body FROM messages WHERE session_id=?1 AND sequence<?2 ORDER BY sequence DESC LIMIT ?3")?;
        let rows = stmt.query_map(params![session, before, limit + 1], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        let mut messages = Vec::new();
        for row in rows {
            let (sequence, revision, body) = row?;
            let mut v: Value = serde_json::from_str(&body)?;
            v["sequence"] = json!(sequence);
            v["revision"] = json!(revision);
            messages.push(v);
        }
        let more = messages.len() > limit;
        messages.truncate(limit);
        messages.reverse();
        Ok(json!({"messages":messages,"hasMore":more}))
    }
    pub fn create_pair(&self) -> Result<(String, String)> {
        let code = security::secret();
        let expires = (Utc::now() + Duration::minutes(10)).to_rfc3339();
        self.db.lock().execute(
            "INSERT INTO pairs(hash,expires) VALUES(?1,?2)",
            params![security::hash(&code), expires],
        )?;
        Ok((code, expires))
    }
    pub fn consume_pair(&self, code: &str, name: &str) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let removed = tx.execute(
            "DELETE FROM pairs WHERE hash=?1 AND expires>?2",
            params![security::hash(code), now()],
        )?;
        if removed != 1 {
            bail!(
                "Pairing code is invalid, expired, or already used. Generate another with omputer pair --url https://HOST:PORT"
            );
        }
        let id = Uuid::new_v4().to_string();
        let token = security::secret();
        tx.execute(
            "INSERT INTO devices(id,hash,name,created) VALUES(?1,?2,?3,?4)",
            params![id, security::hash(&token), name, now()],
        )?;
        tx.commit()?;
        Ok(json!({"deviceId":id,"token":token,"serverName":self.server_name}))
    }
    /// Only the local PC-approved pairing queue calls this. Public requests
    /// cannot supply an approval flag or bypass the one-use claim operation.
    pub(crate) fn issue_device(&self, name: &str) -> Result<Value> {
        let id = Uuid::new_v4().to_string();
        let token = security::secret();
        self.db.lock().execute(
            "INSERT INTO devices(id,hash,name,created) VALUES(?1,?2,?3,?4)",
            params![id, security::hash(&token), name, now()],
        )?;
        Ok(json!({"deviceId":id,"token":token,"serverName":self.server_name}))
    }
    pub fn authenticate(&self, token: &str) -> Result<Option<String>> {
        let db = self.db.lock();
        let current = Utc::now();
        let device: Option<(String, Option<String>)> = db
            .query_row(
                "SELECT id,last_seen FROM devices WHERE hash=?1 AND revoked IS NULL",
                [security::hash(token)],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((id, last_seen)) = device else {
            return Ok(None);
        };
        // Device status is minute-resolution, not a journal event per HTTP
        // request. A newly authenticated device is always recorded immediately.
        if last_seen
            .as_deref()
            .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
            .is_none_or(|seen| current.signed_duration_since(seen) >= Duration::minutes(1))
        {
            db.execute(
                "UPDATE devices SET last_seen=?2 WHERE id=?1 AND revoked IS NULL",
                params![id, current.to_rfc3339()],
            )?;
        }
        Ok(Some(id))
    }
    pub fn device_active(&self, id: &str) -> bool {
        self.db
            .lock()
            .query_row(
                "SELECT 1 FROM devices WHERE id=?1 AND revoked IS NULL",
                [id],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .ok()
            .flatten()
            .is_some()
    }
    fn devices_db(db: &Connection) -> Result<Vec<Value>> {
        let mut stmt =
            db.prepare("SELECT id,name,created,revoked,last_seen FROM devices ORDER BY created")?;
        let rows=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"createdAt":r.get::<_,String>(2)?,"lastSeenAt":r.get::<_,Option<String>>(4)?,"revokedAt":r.get::<_,Option<String>>(3)?})))?;
        rows.collect::<rusqlite::Result<_>>().map_err(Into::into)
    }
    pub fn devices(&self) -> Result<Vec<Value>> {
        Self::devices_db(&self.db.lock())
    }
    pub fn revoke(&self, id: &str) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        if tx.execute(
            "UPDATE devices SET revoked=?1 WHERE id=?2 AND revoked IS NULL",
            params![now(), id],
        )? != 1
        {
            bail!("Device not found or already revoked");
        }
        Self::append(&tx, "device.revoked", None, None, &json!({"id":id}))?;
        tx.commit()?;
        Ok(())
    }
    pub fn begin_command(&self, id: &str, request: &Value) -> Result<Option<Value>> {
        Uuid::parse_str(id).context("Command id must be a UUID")?;
        let action = request["action"]
            .as_str()
            .context("Command action is required")?;
        let hash = security::hash(&request.to_string());
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let stamp = now();
        let inserted = tx.execute(
            "INSERT OR IGNORE INTO commands(id,request_hash,request,session_id,action,status,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,'running',?6,?6)",
            params![id, hash, request.to_string(), request["sessionId"].as_str(), action, stamp],
        )?;
        if inserted == 1 {
            Self::append(
                &tx,
                "operation.updated",
                request["sessionId"].as_str(),
                None,
                &Self::command_status_db(&tx, id)?,
            )?;
            tx.commit()?;
            return Ok(None);
        }
        let (existing, result, status): (String, Option<String>, String) = tx.query_row(
            "SELECT request_hash,result,status FROM commands WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        if existing != hash {
            bail!("Command UUID was already used with a different request");
        }
        Ok(Some(match result {
            Some(s) => serde_json::from_str(&s)?,
            None if status == "running" => {
                json!({"id":id,"success":true,"accepted":true,"status":"running"})
            }
            None => {
                json!({"id":id,"success":false,"status":"unknown","error":{"code":"outcome_unknown","message":"The daemon restarted before the final result was recorded. This request will never be executed again."}})
            }
        }))
    }
    pub fn finish_command(&self, id: &str, result: &Value) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let mut result = result.clone();
        let status = if result["success"] == true {
            "succeeded"
        } else {
            "failed"
        };
        result["status"] = json!(status);
        if tx.execute(
            "UPDATE commands SET result=?2,status=?3,updated_at=?4 WHERE id=?1 AND result IS NULL",
            params![id, result.to_string(), status, now()],
        )? == 1
        {
            let operation = Self::command_status_db(&tx, id)?;
            Self::append(
                &tx,
                "operation.updated",
                operation["sessionId"].as_str(),
                None,
                &operation,
            )?;
        }
        tx.commit()?;
        Ok(())
    }
    pub fn command_unknown(&self, id: &str, message: &str) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        if tx.execute(
            "UPDATE commands SET status='unknown',updated_at=?2 WHERE id=?1 AND result IS NULL",
            params![id, now()],
        )? == 1
        {
            let mut operation = Self::command_status_db(&tx, id)?;
            operation["error"] = json!({"code":"outcome_unknown","message":message});
            Self::append(
                &tx,
                "operation.updated",
                operation["sessionId"].as_str(),
                None,
                &operation,
            )?;
        }
        tx.commit()?;
        Ok(())
    }
    fn command_status_db(db: &Connection, id: &str) -> Result<Value> {
        let (session,action,status,created,updated,result): (Option<String>,Option<String>,String,String,String,Option<String>) = db.query_row(
            "SELECT session_id,action,status,created_at,updated_at,result FROM commands WHERE id=?1", [id],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)),
        ).context("Unknown command")?;
        let mut value = json!({"id":id,"sessionId":session,"action":action,"status":status,"createdAt":created,"updatedAt":updated});
        if let Some(raw) = result {
            value["result"] = serde_json::from_str(&raw)?;
        }
        Ok(value)
    }
    pub fn command_status(&self, id: &str) -> Result<Value> {
        Self::command_status_db(&self.db.lock(), id)
    }
    pub fn list_operations(&self, session: &str, before: i64, limit: usize) -> Result<Value> {
        let db = self.db.lock();
        let limit = limit.clamp(1, 200);
        let mut stmt = db.prepare("SELECT rowid,id FROM commands WHERE session_id=?1 AND rowid<?2 ORDER BY rowid DESC LIMIT ?3")?;
        let rows = stmt
            .query_map(params![session, before, limit + 1], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let more = rows.len() > limit;
        let mut operations = Vec::new();
        let mut cursor = None;
        for (sequence, id) in rows.into_iter().take(limit) {
            let mut operation = Self::command_status_db(&db, &id)?;
            operation["sequence"] = json!(sequence);
            cursor = Some(sequence);
            operations.push(operation);
        }
        Ok(
            json!({"operations":operations,"hasMore":more,"nextCursor":if more { cursor } else { None }}),
        )
    }
    pub fn command_output(&self, id: &str, kind: &str, text: &str) -> Result<()> {
        self.command_output_inner(id, None, kind, text)
    }
    pub fn command_output_once(
        &self,
        id: &str,
        output_id: &str,
        kind: &str,
        text: &str,
    ) -> Result<()> {
        if output_id.is_empty() || output_id.len() > 256 {
            bail!("Invalid output identity");
        }
        self.command_output_inner(id, Some(output_id), kind, text)
    }
    fn command_output_inner(
        &self,
        id: &str,
        output_id: Option<&str>,
        kind: &str,
        text: &str,
    ) -> Result<()> {
        if kind.is_empty() || kind.len() > 64 {
            bail!("Invalid output kind");
        }
        if text.is_empty() {
            return Ok(());
        }
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let operation = Self::command_status_db(&tx, id)?;
        tx.execute(
            "INSERT OR IGNORE INTO command_output_limits(command_id) VALUES(?1)",
            [id],
        )?;
        let (used, count): (usize, usize) = tx.query_row(
            "SELECT bytes,items FROM command_output_limits WHERE command_id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if used >= 1024 * 1024 || count >= 10_000 {
            tx.execute(
                "UPDATE command_output_limits SET truncated=1 WHERE command_id=?1",
                [id],
            )?;
            tx.commit()?;
            return Ok(());
        }
        if let Some(output_id) = output_id
            && tx.execute(
                "INSERT OR IGNORE INTO command_output_ids(command_id,output_id) VALUES(?1,?2)",
                params![id, output_id],
            )? == 0
        {
            return Ok(());
        }
        let remaining = (1024 * 1024usize).saturating_sub(used);
        let bounded = utf8_prefix(text, remaining);
        let mut offset = 0;
        let mut items = count;
        while offset < bounded.len() && items < 10_000 {
            let chunk = utf8_prefix(&bounded[offset..], 64 * 1024);
            tx.execute(
                "INSERT INTO command_output(command_id,kind,text) VALUES(?1,?2,?3)",
                params![id, kind, chunk],
            )?;
            let sequence = tx.last_insert_rowid();
            offset += chunk.len();
            items += 1;
            Self::append(
                &tx,
                "operation.output",
                operation["sessionId"].as_str(),
                None,
                &json!({"id":id,"sequence":sequence,"kind":kind,"text":chunk,"truncated":offset==bounded.len()&&bounded.len()<text.len()}),
            )?;
        }
        tx.execute("UPDATE command_output_limits SET bytes=bytes+?2,items=?3,truncated=MAX(truncated,?4) WHERE command_id=?1",params![id,offset,items,offset<text.len()])?;
        tx.execute(
            "UPDATE commands SET updated_at=?2 WHERE id=?1",
            params![id, now()],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn command_output_page(&self, id: &str, after: i64, limit: usize) -> Result<Value> {
        let db = self.db.lock();
        Self::command_status_db(&db, id)?;
        let limit = limit.clamp(1, 100);
        let mut stmt=db.prepare("SELECT sequence,kind,text FROM command_output WHERE command_id=?1 AND sequence>?2 ORDER BY sequence LIMIT ?3")?;
        let mut items=stmt.query_map(params![id,after.max(0),limit+1],|r|Ok(json!({"sequence":r.get::<_,i64>(0)?,"kind":r.get::<_,String>(1)?,"text":r.get::<_,String>(2)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let more = items.len() > limit;
        items.truncate(limit);
        let truncated: bool = db
            .query_row(
                "SELECT truncated FROM command_output_limits WHERE command_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(false);
        Ok(
            json!({"items":items,"hasMore":more,"truncated":truncated,"byteLimit":1024*1024,"itemByteLimit":64*1024,"itemLimit":10000}),
        )
    }
    pub fn claim_interaction(&self, id: &str, command: &str) -> Result<Value> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let body: String = tx
            .query_row(
                "SELECT body FROM objects WHERE kind='interaction' AND id=?1",
                [id],
                |r| r.get(0),
            )
            .context("Interaction does not exist")?;
        let interaction: Value = serde_json::from_str(&body)?;
        if interaction["status"] != "pending" {
            bail!("Interaction is already resolved, cancelled, or expired");
        }
        if interaction["expiresAt"]
            .as_str()
            .is_some_and(|s| s <= now().as_str())
        {
            bail!("Interaction has expired");
        }
        if tx.execute(
            "INSERT OR IGNORE INTO claims(id,command_id) VALUES(?1,?2)",
            params![id, command],
        )? != 1
        {
            bail!("Another answer has already claimed this interaction");
        }
        tx.commit()?;
        Ok(interaction)
    }
    pub fn release_interaction_claim(&self, id: &str, command: &str) -> Result<()> {
        self.db.lock().execute(
            "DELETE FROM claims WHERE id=?1 AND command_id=?2",
            params![id, command],
        )?;
        Ok(())
    }
    pub fn reconcile_pending_replay(&self, id: &str, session: &str) -> Result<()> {
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let body: Option<String> = tx
            .query_row(
                "SELECT body FROM objects WHERE kind='interaction' AND id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(body) = body {
            let interaction: Value = serde_json::from_str(&body)?;
            if interaction["sessionId"] == session
                && interaction["cancellationReason"] == "disconnect"
            {
                tx.execute("DELETE FROM claims WHERE id=?1", [id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
    pub fn end_interaction(&self, id: &str, status: &str) -> Result<()> {
        if !matches!(status, "resolved" | "cancelled" | "expired") {
            bail!("Invalid interaction outcome");
        }
        let mut db = self.db.lock();
        let tx = db.transaction()?;
        let body: Option<String> = tx
            .query_row(
                "SELECT body FROM objects WHERE kind='interaction' AND id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(body) = body {
            let mut value: Value = serde_json::from_str(&body)?;
            if value["status"] == "pending" {
                value["status"] = json!(status);
                tx.execute(
                    "UPDATE objects SET body=?2 WHERE kind='interaction' AND id=?1",
                    params![id, value.to_string()],
                )?;
                Self::append(
                    &tx,
                    "interaction.resolved",
                    value["sessionId"].as_str(),
                    value["projectId"].as_str(),
                    &value,
                )?;
            }
        }
        Self::refresh_projects(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub fn cancel_session_interactions(&self, session: &str) -> Result<()> {
        for mut i in self.list("interaction")? {
            if i["sessionId"] == session && i["status"] == "pending" {
                i["status"] = json!("cancelled");
                i["cancellationReason"] = json!("disconnect");
                let id = i["id"].as_str().unwrap_or_default();
                self.put("interaction", id, &i, Some("interaction.resolved"))?;
            }
        }
        Ok(())
    }
    pub fn expire_interactions(&self) -> Result<()> {
        for i in self.list("interaction")? {
            if i["status"] == "pending"
                && i["expiresAt"].as_str().is_some_and(|s| s <= now().as_str())
            {
                self.end_interaction(i["id"].as_str().unwrap_or_default(), "expired")?;
            }
        }
        Ok(())
    }
}
fn project_activity(project: &mut Value, sessions: &[Value], interactions: &[Value]) {
    let owned: Vec<&Value> = sessions
        .iter()
        .filter(|s| s["projectId"] == project["id"])
        .collect();
    project["sessionCount"] = json!(owned.len());
    project["pendingCount"] = json!(
        interactions
            .iter()
            .filter(|i| i["projectId"] == project["id"] && i["status"] == "pending")
            .count()
    );
    let stamp = |s: &Value| {
        s["activityUpdatedAt"]
            .as_str()
            .or(s["updatedAt"].as_str())
            .unwrap_or_default()
            .to_owned()
    };
    let relevant = |session: &&Value| {
        ["lastUserMessage", "lastAssistantText"]
            .iter()
            .any(|key| session[*key].as_str().is_some_and(|text| !text.is_empty()))
            || session["todos"]
                .as_array()
                .is_some_and(|phases| !phases.is_empty())
            || interactions.iter().any(|request| {
                request["sessionId"] == session["id"] && request["status"] == "pending"
            })
    };
    if let Some(session) = owned.into_iter().filter(relevant).max_by_key(|s| stamp(s)) {
        let todos = session["todos"].as_array().cloned().unwrap_or_default();
        let mut next = "";
        for status in ["in_progress", "pending"] {
            for phase in &todos {
                if let Some(tasks) = phase["tasks"].as_array()
                    && let Some(task) = tasks
                        .iter()
                        .find(|t| t["status"] == status && t["content"].is_string())
                {
                    next = task["content"].as_str().unwrap_or_default();
                    break;
                }
            }
            if !next.is_empty() {
                break;
            }
        }
        let updated = stamp(session);
        project["activity"] = json!({"sessionId":session["id"],"updatedAt":updated,"goal":session["lastUserMessage"].as_str().unwrap_or_default(),"lastAssistantText":session["lastAssistantText"].as_str().unwrap_or_default(),"nextStep":next,"todos":todos,"pendingCount":interactions.iter().filter(|i|i["sessionId"]==session["id"]&&i["status"]=="pending").count()});
        if let (Ok(activity), Some(memory)) = (
            chrono::DateTime::parse_from_rfc3339(&updated),
            project["updatedAt"]
                .as_str()
                .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()),
        ) && activity > memory
        {
            project["updatedAt"] = json!(updated);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn store() -> Store {
        Store::open(Path::new(":memory:"), "test".into()).unwrap()
    }
    #[test]
    fn streaming_revision_changes_without_moving_history_position() {
        let store = store();
        let partial =
            json!({"id":"message","role":"assistant","content":[{"type":"text","text":"part"}]});
        let first = store.message("session", "message", &partial).unwrap();
        let complete = json!({"id":"message","role":"assistant","content":[{"type":"text","text":"complete"}]});
        let second = store.message("session", "message", &complete).unwrap();
        assert_eq!(first["sequence"], second["sequence"]);
        assert!(second["revision"].as_i64().unwrap() > first["revision"].as_i64().unwrap());
        let page = store.messages("session", i64::MAX, 50).unwrap();
        assert_eq!(page["messages"][0]["revision"], second["revision"]);
        assert_eq!(page["messages"][0]["content"][0]["text"], "complete");
        assert_eq!(
            store.message("session", "message", &complete).unwrap()["revision"],
            second["revision"]
        );
    }
    #[test]
    fn pairing_is_single_use_and_revocation_is_effective() {
        let s = store();
        let (code, _) = s.create_pair().unwrap();
        let d = s.consume_pair(&code, "phone").unwrap();
        assert!(s.consume_pair(&code, "other").is_err());
        assert!(
            s.authenticate(d["token"].as_str().unwrap())
                .unwrap()
                .is_some()
        );
        s.revoke(d["deviceId"].as_str().unwrap()).unwrap();
        assert!(
            s.authenticate(d["token"].as_str().unwrap())
                .unwrap()
                .is_none()
        );
        s.db.lock()
            .execute(
                "INSERT INTO pairs VALUES(?1,?2)",
                params![security::hash("expired"), "2000-01-01T00:00:00Z"],
            )
            .unwrap();
        assert!(s.consume_pair("expired", "phone").is_err());
    }
    #[test]
    fn interaction_first_answer_and_stale_answer_are_fenced() {
        let s = store();
        let i = json!({"id":"question","sessionId":"session","status":"pending"});
        s.put("interaction", "question", &i, None).unwrap();
        s.claim_interaction("question", "a").unwrap();
        assert!(s.claim_interaction("question", "b").is_err());
        s.end_interaction("question", "resolved").unwrap();
        assert!(s.claim_interaction("question", "c").is_err());
        s.put(
            "interaction",
            "expired",
            &json!({"id":"expired","status":"pending","expiresAt":"2000-01-01T00:00:00Z"}),
            None,
        )
        .unwrap();
        assert!(s.claim_interaction("expired", "d").is_err());
    }
    #[test]
    fn commands_deduplicate_even_before_completion() {
        let s = store();
        let id = Uuid::new_v4().to_string();
        let q = json!({"action":"session.bash"});
        assert!(s.begin_command(&id, &q).unwrap().is_none());
        assert_eq!(
            s.begin_command(&id, &q).unwrap().unwrap()["status"],
            "running"
        );
        let response = json!({"id":id,"success":true,"status":"succeeded"});
        s.finish_command(&id, &response).unwrap();
        assert_eq!(s.begin_command(&id, &q).unwrap(), Some(response));
        assert!(
            s.begin_command(&id, &json!({"action":"session.abort"}))
                .is_err()
        );
    }
    #[test]
    fn last_seen_is_persisted_without_an_event_per_request() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("store.sqlite");
        let store = Store::open(&path, "test".into()).unwrap();
        let device = store.issue_device("phone").unwrap();
        let token = device["token"].as_str().unwrap();
        assert!(store.devices().unwrap()[0]["lastSeenAt"].is_null());
        store.authenticate(token).unwrap().unwrap();
        let seen = store.devices().unwrap()[0]["lastSeenAt"].clone();
        assert!(seen.is_string());
        store.authenticate(token).unwrap().unwrap();
        assert_eq!(store.devices().unwrap()[0]["lastSeenAt"], seen);
        assert_eq!(store.snapshot().unwrap()["sequence"], 0);
        store
            .db
            .lock()
            .execute("UPDATE devices SET last_seen='2000-01-01T00:00:00Z'", [])
            .unwrap();
        store.authenticate(token).unwrap().unwrap();
        assert_ne!(
            store.devices().unwrap()[0]["lastSeenAt"],
            "2000-01-01T00:00:00Z"
        );
        drop(store);
        let reopened = Store::open(&path, "test".into()).unwrap();
        assert!(reopened.devices().unwrap()[0]["lastSeenAt"].is_string());
        reopened
            .revoke(device["deviceId"].as_str().unwrap())
            .unwrap();
        let revoked_seen = reopened.devices().unwrap()[0]["lastSeenAt"].clone();
        assert!(reopened.authenticate(token).unwrap().is_none());
        assert_eq!(reopened.devices().unwrap()[0]["lastSeenAt"], revoked_seen);
    }

    #[test]
    fn coalesced_message_replay_preserves_every_cursor_and_branch_reset() {
        let store = store();
        let first = json!({"id":"same","role":"assistant","content":"part"});
        store.message("s", "same", &first).unwrap();
        let before_update = store.snapshot().unwrap()["sequence"].as_i64().unwrap();
        let notice = store
            .event(
                "notification",
                Some("s"),
                None,
                &json!({"id":"n","kind":"turn_done"}),
            )
            .unwrap();
        let between = notice["sequence"].as_i64().unwrap();
        let complete = json!({"id":"same","role":"assistant","content":"complete"});
        store.message("s", "same", &complete).unwrap();
        let after_update = store.snapshot().unwrap()["sequence"].as_i64().unwrap();
        for cursor in [0, before_update, between] {
            let events = store.journal(cursor, 100).unwrap();
            let updates: Vec<_> = events
                .iter()
                .filter(|event| event["type"] == "message.upsert")
                .collect();
            assert_eq!(updates.len(), 1);
            assert_eq!(updates[0]["data"]["content"], "complete");
            assert_eq!(updates[0]["data"]["revision"], 2);
        }
        assert!(store.journal(after_update, 100).unwrap().is_empty());
        store
            .message(
                "s",
                "removed",
                &json!({"id":"removed","role":"user","content":"retired"}),
            )
            .unwrap();
        store.replace_messages("s", &[first]).unwrap();
        let replay = store.journal(0, 100).unwrap();
        let reset = replay
            .iter()
            .position(|event| {
                event["type"] == "session.event" && event["data"]["type"] == "transcript_reset"
            })
            .unwrap();
        let mut history = std::collections::HashMap::new();
        for event in &replay {
            if event["type"] == "session.event" && event["data"]["type"] == "transcript_reset" {
                history.clear();
            }
            if event["type"] == "message.upsert" {
                history.insert(event["data"]["id"].as_str().unwrap(), event["data"].clone());
            }
        }
        assert!(
            replay[..reset]
                .iter()
                .any(|event| event["type"] == "notification")
        );
        assert_eq!(history.len(), 1);
        assert_eq!(history["same"]["content"], "part");
        assert_eq!(history["same"]["revision"], 1);
        assert!(
            replay
                .windows(2)
                .all(|pair| pair[0]["sequence"].as_i64() < pair[1]["sequence"].as_i64())
        );
    }

    #[test]
    fn existing_journal_compacts_in_persistent_batches_without_losing_live_writes() {
        let temporary = tempfile::tempdir().unwrap();
        let path = temporary.path().join("store.sqlite");
        let store = Store::open(&path, "test".into()).unwrap();
        for text in ["one", "two", "three"] {
            store.db.lock().execute("INSERT INTO journal(body) VALUES(?1)", [json!({"type":"message.upsert","sessionId":"s","data":{"id":"m","content":text},"createdAt":now()}).to_string()]).unwrap();
        }
        let count = || {
            store
                .db
                .lock()
                .query_row("SELECT count(*) FROM journal", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap()
        };
        assert_eq!(count(), 3);
        store.journal(0, 1).unwrap();
        assert_eq!(count(), 3);
        store
            .message("s", "m", &json!({"id":"m","content":"new live revision"}))
            .unwrap();
        store
            .event("notification", Some("s"), None, &json!({"id":"unique"}))
            .unwrap();
        drop(store);
        let store = Store::open(&path, "test".into()).unwrap();
        for _ in 0..5 {
            store.journal(0, 1).unwrap();
        }
        let events = store.journal(0, 100).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["data"]["content"], "new live revision");
        assert_eq!(events[1]["data"]["id"], "unique");
        assert_eq!(store.snapshot().unwrap()["sequence"], events[1]["sequence"]);
    }

    #[test]
    fn archive_import_cannot_overwrite_a_new_live_owner() {
        let temporary = tempfile::tempdir().unwrap();
        let source = temporary.path().join("session.jsonl");
        std::fs::write(&source, "saved bytes").unwrap();
        let source = source.canonicalize().unwrap();
        let store = store();
        let live =
            json!({"id":"managed","transport":"rpc","status":"running","sessionFile":source});
        store.put("session", "managed", &live, None).unwrap();
        store
            .message(
                "managed",
                "live",
                &json!({"id":"live","content":"authoritative"}),
            )
            .unwrap();
        let archive =
            json!({"id":"native","transport":"archive","status":"closed","sessionFile":source});
        assert_eq!(
            store
                .import_archive(&archive, &[json!({"id":"stale","content":"old bytes"})])
                .unwrap(),
            "managed"
        );
        assert_eq!(store.get("session", "managed").unwrap(), live);
        assert!(store.get("session", "native").is_err());
        assert_eq!(
            store.messages("managed", i64::MAX, 50).unwrap()["messages"][0]["id"],
            "live"
        );
    }
}

#[cfg(test)]
mod continuity_tests {
    use super::*;
    fn fixture() -> Store {
        let store = Store::open(Path::new(":memory:"), "test".into()).unwrap();
        store.put("project","p",&json!({"id":"p","path":"/project","goal":"manual","summary":"manual fact","nextStep":"manual next","decisions":["keep"],"updatedAt":"2026-01-01T00:00:00Z"}),None).unwrap();
        store.put("session","s",&json!({"id":"s","projectId":"p","cwd":"/project","updatedAt":"2026-01-02T00:00:00Z","lastUserMessage":"normal prompt","lastAssistantText":"final response","todos":[]}),None).unwrap();
        store
    }
    #[test]
    fn empty_new_session_cannot_replace_meaningful_project_activity() {
        let store = fixture();
        store.put("session", "empty", &json!({"id":"empty","projectId":"p","cwd":"/project","updatedAt":"2099-01-01T00:00:00Z","todos":[]}), None).unwrap();
        let project = store.snapshot().unwrap()["projects"][0].clone();
        assert_eq!(project["activity"]["sessionId"], "s");
        assert_eq!(project["activity"]["goal"], "normal prompt");
    }
    #[test]
    fn explicit_checkpoint_preserves_omitted_facts_and_validates_every_field() {
        let store = fixture();
        let project = store
            .checkpoint(
                "s",
                &json!({"expectedMemoryRevision":0,"nextStep":"agent-supplied next"}),
            )
            .unwrap();
        assert_eq!(project["goal"], "manual");
        assert_eq!(project["summary"], "manual fact");
        assert_eq!(project["decisions"], json!(["keep"]));
        assert_eq!(project["sourceSessionId"], "s");
        assert_eq!(project["memoryOrigin"], "agent");
        assert!(
            store
                .checkpoint("s", &json!({"expectedMemoryRevision":1,"goal":1}))
                .is_err()
        );
        assert!(
            store
                .checkpoint(
                    "s",
                    &json!({"expectedMemoryRevision":1,"decisions":["valid",false]})
                )
                .is_err()
        );
        assert!(
            store
                .checkpoint(
                    "s",
                    &json!({"expectedMemoryRevision":1,"sourceSessionId":"other"})
                )
                .is_err()
        );
        let mut session = store.get("session", "s").unwrap();
        session["cwd"] = json!("/other");
        store.put("session", "s", &session, None).unwrap();
        assert!(
            store
                .checkpoint(
                    "s",
                    &json!({"expectedMemoryRevision":1,"goal":"wrong root"})
                )
                .is_err()
        );
    }
    #[test]
    fn archive_growth_preserves_history_positions_and_emits_only_changed_messages() {
        let store = fixture();
        let first = json!({"id":"first","role":"user","content":"Initial request"});
        let partial = json!({"id":"answer","role":"assistant","content":"Partial"});
        store
            .replace_messages("s", &[first.clone(), partial])
            .unwrap();
        let before = store.messages("s", i64::MAX, 50).unwrap();
        let cursor = store.snapshot().unwrap()["sequence"].as_i64().unwrap();
        let complete = json!({"id":"answer","role":"assistant","content":"Complete answer"});
        let next = json!({"id":"next","role":"user","content":"Next request"});
        store
            .replace_messages("s", &[first, complete, next])
            .unwrap();
        let after = store.messages("s", i64::MAX, 50).unwrap();
        assert_eq!(after["messages"][0], before["messages"][0]);
        assert_eq!(
            after["messages"][1]["sequence"],
            before["messages"][1]["sequence"]
        );
        assert_eq!(after["messages"][1]["revision"], 2);
        assert_eq!(after["messages"][1]["content"], "Complete answer");
        let events = store.journal(cursor, 100).unwrap();
        assert_eq!(
            events
                .iter()
                .map(|event| event["data"]["id"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["answer", "next"]
        );
        assert!(events.iter().all(|event| event["type"] == "message.upsert"));
    }
    #[test]
    fn history_replacement_is_atomic_ordered_and_deduplicated() {
        let store = fixture();
        let first = json!({"id":"first","role":"user","content":[]});
        let second = json!({"id":"second","role":"assistant","content":[]});
        store.message("s", "second", &second).unwrap();
        store
            .replace_messages("s", &[first.clone(), second.clone()])
            .unwrap();
        let messages = store.messages("s", i64::MAX, 50).unwrap();
        assert_eq!(messages["messages"][0]["id"], "first");
        assert_eq!(messages["messages"][1]["id"], "second");
        let sequence = store.snapshot().unwrap()["sequence"].clone();
        store
            .replace_messages("s", &[first.clone(), second.clone()])
            .unwrap();
        assert_eq!(store.snapshot().unwrap()["sequence"], sequence);
        assert!(
            store
                .replace_messages("s", &[first.clone(), first])
                .is_err()
        );
        assert_eq!(
            store.messages("s", i64::MAX, 50).unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        store.replace_messages("s", &[second]).unwrap();
        assert_eq!(
            store.messages("s", i64::MAX, 50).unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(
            store
                .journal(0, 1000)
                .unwrap()
                .iter()
                .any(|event| event["type"] == "session.event"
                    && event["data"]["type"] == "transcript_reset")
        );
    }
}

#[cfg(test)]
mod operation_memory_search_tests {
    use super::*;
    #[test]
    fn restart_marks_running_unknown_and_never_replays_uuid() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("state.sqlite");
        let id = Uuid::new_v4().to_string();
        let request = json!({"id":id,"sessionId":"s","action":"session.bash","payload":{"command":"echo once"}});
        {
            let store = Store::open(&path, "test".into()).unwrap();
            assert!(store.begin_command(&id, &request).unwrap().is_none());
            store
                .command_output_once(&id, "frame-1", "stdout", "persisted")
                .unwrap();
        }
        let store = Store::open(&path, "test".into()).unwrap();
        assert_eq!(store.command_status(&id).unwrap()["status"], "unknown");
        assert_eq!(
            store.begin_command(&id, &request).unwrap().unwrap()["error"]["code"],
            "outcome_unknown"
        );
        store
            .command_output_once(&id, "frame-1", "stdout", "persisted")
            .unwrap();
        assert_eq!(
            store.command_output_page(&id, 0, 100).unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            store.list_operations("s", i64::MAX, 10).unwrap()["operations"][0]["id"],
            id
        );
    }
    #[test]
    fn output_chunks_preserve_utf8_and_persist_truncation_without_deleting_history() {
        let store = Store::open(Path::new(":memory:"), "test".into()).unwrap();
        let id = Uuid::new_v4().to_string();
        store
            .begin_command(&id, &json!({"action":"session.bash"}))
            .unwrap();
        let text = "é".repeat(40_000);
        store
            .command_output_once(&id, "one", "stdout", &text)
            .unwrap();
        let page = store.command_output_page(&id, 0, 100).unwrap();
        assert_eq!(page["items"].as_array().unwrap().len(), 2);
        assert_eq!(
            page["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v["text"].as_str().unwrap())
                .collect::<String>(),
            text
        );
        assert_eq!(page["truncated"], false);
        store
            .command_output(&id, "stdout", &"x".repeat(2 * 1024 * 1024))
            .unwrap();
        assert_eq!(
            store.command_output_page(&id, 0, 100).unwrap()["truncated"],
            true
        );
        assert_eq!(
            store.command_output_page(&id, 0, 1).unwrap()["hasMore"],
            true
        );
        store
            .finish_command(&id, &json!({"id":id,"success":true,"data":{}}))
            .unwrap();
        assert_eq!(
            store.command_status(&id).unwrap()["result"]["status"],
            "succeeded"
        );
    }
    fn fixture() -> Store {
        let store = Store::open(Path::new(":memory:"), "test".into()).unwrap();
        store.put("project","p",&json!({"id":"p","path":"/p","goal":"original","summary":"","decisions":[],"nextStep":""}),None).unwrap();
        store
            .put(
                "session",
                "s",
                &json!({"id":"s","projectId":"p","cwd":"/p","title":"Search title"}),
                None,
            )
            .unwrap();
        store
    }
    #[test]
    fn manual_and_agent_memory_share_atomic_stale_revision_and_history() {
        let store = fixture();
        let first = store
            .edit_memory("p", &json!({"expectedMemoryRevision":0,"summary":"manual"}))
            .unwrap();
        assert_eq!(first["memoryRevision"], 1);
        let stale = store
            .checkpoint("s", &json!({"expectedMemoryRevision":0,"summary":"stale"}))
            .unwrap_err();
        assert!(stale.is::<MemoryConflict>());
        assert_eq!(store.get("project", "p").unwrap()["summary"], "manual");
        store
            .checkpoint("s", &json!({"expectedMemoryRevision":1,"nextStep":"agent"}))
            .unwrap();
        let history = store.memory_history("p", i64::MAX, 1).unwrap();
        assert_eq!(history["entries"][0]["revision"], 2);
        assert_eq!(history["entries"][0]["origin"], "agent");
        assert_eq!(history["hasMore"], true);
        assert_eq!(
            store.memory_history("p", i64::MAX, 100).unwrap()["entries"]
                .as_array()
                .unwrap()
                .len(),
            3
        );
        store
            .put(
                "session",
                "wrong",
                &json!({"id":"wrong","projectId":"other"}),
                None,
            )
            .unwrap();
        assert!(store.edit_memory("p",&json!({"expectedMemoryRevision":2,"summary":"not committed","sourceSessionId":"wrong"})).is_err());
        assert_eq!(store.get("project", "p").unwrap()["memoryRevision"], 2);
    }
    #[test]
    fn indexed_search_updates_branch_replacement_and_exports_redact_secrets() {
        let store = fixture();
        store.message("s","m",&json!({"id":"m","role":"user","content":"needle one\nAuthorization: Bearer private-token\npassword=private"})).unwrap();
        assert_eq!(
            store.search("needle", Some("p"), None, 0, 10).unwrap()["results"][0]["messageId"],
            "m"
        );
        assert_eq!(
            store.search("needle", Some("other"), None, 0, 10).unwrap()["results"],
            json!([])
        );
        let exported = store.export_session("s", "json").unwrap();
        assert!(exported["text"].as_str().unwrap().contains("[REDACTED]"));
        assert!(!exported["text"].as_str().unwrap().contains("private-token"));
        assert_eq!(exported["redacted"], true);
        store
            .replace_messages(
                "s",
                &[json!({"id":"replacement","role":"assistant","content":"different branch"})],
            )
            .unwrap();
        assert_eq!(
            store.search("needle", None, None, 0, 10).unwrap()["results"],
            json!([])
        );
        assert_eq!(
            store.search("different", None, None, 0, 10).unwrap()["results"][0]["messageId"],
            "replacement"
        );
    }
}
