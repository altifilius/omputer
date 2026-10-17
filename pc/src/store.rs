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
            CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,hash TEXT UNIQUE NOT NULL,name TEXT NOT NULL,created TEXT NOT NULL,revoked TEXT);
            CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY,request_hash TEXT NOT NULL,result TEXT);
            CREATE TABLE IF NOT EXISTS claims(id TEXT PRIMARY KEY,command_id TEXT NOT NULL);")?;
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
        event["sequence"] = json!(db.last_insert_rowid());
        Ok(event)
    }
    pub fn event(
        &self,
        ty: &str,
        session: Option<&str>,
        project: Option<&str>,
        data: &Value,
    ) -> Result<Value> {
        Self::append(&self.db.lock(), ty, session, project, data)
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
        let project = json!({"id":id,"name":name.unwrap_or_else(||root.file_name().unwrap_or_default().to_string_lossy().to_string()),"path":text,"goal":"","summary":"","nextStep":"","decisions":[],"updatedAt":now(),"sessionCount":0,"pendingCount":0});
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
        let fields = data
            .as_object()
            .context("Checkpoint data must be an object")?;
        if fields.is_empty() {
            bail!("Checkpoint must deliberately supply at least one memory field");
        }
        for (key, value) in fields {
            match key.as_str() {
                "goal" | "summary" | "nextStep" if value.is_string() => {}
                "decisions"
                    if value
                        .as_array()
                        .is_some_and(|a| a.iter().all(Value::is_string)) => {}
                _ => bail!("Invalid checkpoint field {key}"),
            }
        }
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
        let raw: String = tx.query_row(
            "SELECT body FROM objects WHERE kind='project' AND id=?1",
            [project_id],
            |r| r.get(0),
        )?;
        let mut project: Value = serde_json::from_str(&raw)?;
        if session["cwd"] != project["path"] {
            bail!("Checkpoint session does not belong to its registered project root");
        }
        for (key, value) in fields {
            project[key] = value.clone();
        }
        project["sourceSessionId"] = json!(session_id);
        project["memoryOrigin"] = json!("agent");
        project["updatedAt"] = json!(now());
        project["memoryUpdatedAt"] = project["updatedAt"].clone();
        tx.execute(
            "UPDATE objects SET body=?2 WHERE kind='project' AND id=?1",
            params![project_id, project.to_string()],
        )?;
        Self::append(
            &tx,
            "project.updated",
            Some(session_id),
            Some(project_id),
            &project,
        )?;
        tx.commit()?;
        Ok(project)
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
        let db = self.db.lock();
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
        let existing: Option<(i64, i64, String)> = tx
            .query_row(
                "SELECT sequence,revision,body FROM messages WHERE session_id=?1 AND id=?2",
                params![session, id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((sequence, revision, body)) = &existing
            && body == &message.to_string()
        {
            let mut value = message.clone();
            value["sequence"] = json!(sequence);
            value["revision"] = json!(revision);
            return Ok(value);
        }
        tx.execute("INSERT INTO messages(session_id,id,body,revision) VALUES(?1,?2,?3,1) ON CONFLICT(session_id,id) DO UPDATE SET body=excluded.body,revision=messages.revision+1",params![session,id,message.to_string()])?;
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
        let mut statement =
            tx.prepare("SELECT id,body FROM messages WHERE session_id=?1 ORDER BY sequence")?;
        let previous = statement
            .query_map([session], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
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
        if previous.len() == messages.len()
            && previous
                .iter()
                .zip(messages)
                .all(|((_, body), message)| body == &message.to_string())
        {
            return Ok(());
        }
        tx.execute("DELETE FROM messages WHERE session_id=?1", [session])?;
        Self::append(
            &tx,
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
            Self::append(&tx, "message.upsert", Some(session), None, &view)?;
        }
        tx.commit()?;
        Ok(())
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
        Ok(self
            .db
            .lock()
            .query_row(
                "SELECT id FROM devices WHERE hash=?1 AND revoked IS NULL",
                [security::hash(token)],
                |r| r.get(0),
            )
            .optional()?)
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
            db.prepare("SELECT id,name,created,revoked FROM devices ORDER BY created")?;
        let rows=stmt.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"createdAt":r.get::<_,String>(2)?,"lastSeenAt":null,"revokedAt":r.get::<_,Option<String>>(3)?})))?;
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
        let hash = security::hash(&request.to_string());
        let db = self.db.lock();
        let inserted = db.execute(
            "INSERT OR IGNORE INTO commands(id,request_hash) VALUES(?1,?2)",
            params![id, hash],
        )?;
        if inserted == 1 {
            return Ok(None);
        }
        let (existing, result): (String, Option<String>) = db.query_row(
            "SELECT request_hash,result FROM commands WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if existing != hash {
            bail!("Command UUID was already used with a different request");
        }
        Ok(Some(match result {
            Some(s) => serde_json::from_str(&s)?,
            None => {
                json!({"id":id,"success":false,"error":{"code":"outcome_unknown","message":"This command was already accepted and may still be executing. Refresh state; it will never be executed twice."}})
            }
        }))
    }
    pub fn finish_command(&self, id: &str, result: &Value) -> Result<()> {
        self.db.lock().execute(
            "UPDATE commands SET result=?2 WHERE id=?1",
            params![id, result.to_string()],
        )?;
        Ok(())
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
            s.begin_command(&id, &q).unwrap().unwrap()["error"]["code"],
            "outcome_unknown"
        );
        let response = json!({"id":id,"success":true});
        s.finish_command(&id, &response).unwrap();
        assert_eq!(s.begin_command(&id, &q).unwrap(), Some(response));
        assert!(
            s.begin_command(&id, &json!({"action":"session.abort"}))
                .is_err()
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
            .checkpoint("s", &json!({"nextStep":"agent-supplied next"}))
            .unwrap();
        assert_eq!(project["goal"], "manual");
        assert_eq!(project["summary"], "manual fact");
        assert_eq!(project["decisions"], json!(["keep"]));
        assert_eq!(project["sourceSessionId"], "s");
        assert_eq!(project["memoryOrigin"], "agent");
        assert!(store.checkpoint("s", &json!({"goal":1})).is_err());
        assert!(
            store
                .checkpoint("s", &json!({"decisions":["valid",false]}))
                .is_err()
        );
        assert!(
            store
                .checkpoint("s", &json!({"sourceSessionId":"other"}))
                .is_err()
        );
        let mut session = store.get("session", "s").unwrap();
        session["cwd"] = json!("/other");
        store.put("session", "s", &session, None).unwrap();
        assert!(
            store
                .checkpoint("s", &json!({"goal":"wrong root"}))
                .is_err()
        );
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
