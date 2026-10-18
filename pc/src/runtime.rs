use crate::{
    archive, rpc_transport,
    store::{Store, now},
};
use anyhow::{Context, Result, bail};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    process::Command,
    sync::{mpsc, oneshot},
};
use uuid::Uuid;

#[derive(Clone)]
pub struct RuntimeConfig {
    pub state_dir: PathBuf,
    pub omp: PathBuf,
    pub bridge: PathBuf,
}
#[derive(Clone, Default)]
struct Links {
    rpc: Option<mpsc::Sender<Value>>,
    bridge: Option<mpsc::Sender<Value>>,
    bridge_generation: Option<String>,
}
struct PendingResponse {
    session: String,
    bridge: bool,
    tx: oneshot::Sender<Value>,
    control_snapshot: Option<Value>,
}
struct AdmittedCommand<'a>(&'a AtomicUsize);
impl Drop for AdmittedCommand<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
#[derive(Debug)]
pub struct CommandError {
    pub code: String,
    pub message: String,
}
impl std::fmt::Display for CommandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for CommandError {}
fn command_error(code: &str, message: impl Into<String>) -> anyhow::Error {
    CommandError {
        code: code.to_owned(),
        message: message.into(),
    }
    .into()
}
pub fn error_code(error: &anyhow::Error) -> &str {
    error
        .downcast_ref::<CommandError>()
        .map(|e| e.code.as_str())
        .unwrap_or("command_rejected")
}
pub struct App {
    pub store: Arc<Store>,
    pub config: RuntimeConfig,
    pub local: std::sync::OnceLock<Arc<crate::discovery::LocalState>>,
    links: Mutex<HashMap<String, Links>>,
    responses: Mutex<HashMap<String, PendingResponse>>,
    models: Mutex<Vec<Value>>,
    revisions: Mutex<HashMap<String, u64>>,
    notifications: Mutex<HashMap<String, (bool, std::time::Instant)>>,
    starting: tokio::sync::Mutex<()>,
    managed_children: Mutex<HashSet<String>>,
    update_pending: AtomicBool,
    admitted_commands: AtomicUsize,
    child_shutdown: Mutex<HashMap<String, mpsc::UnboundedSender<()>>>,
}
impl App {
    pub fn new(store: Arc<Store>, config: RuntimeConfig) -> Arc<Self> {
        Arc::new(Self {
            store,
            config,
            local: std::sync::OnceLock::new(),
            links: Mutex::new(HashMap::new()),
            responses: Mutex::new(HashMap::new()),
            models: Mutex::new(Vec::new()),
            revisions: Mutex::new(HashMap::new()),
            notifications: Mutex::new(HashMap::new()),
            starting: tokio::sync::Mutex::new(()),
            managed_children: Mutex::new(HashSet::new()),
            update_pending: AtomicBool::new(false),
            admitted_commands: AtomicUsize::new(0),
            child_shutdown: Mutex::new(HashMap::new()),
        })
    }
    pub fn initialize_disconnected(&self) -> Result<()> {
        // Clear stale liveness first, so a duplicate saved object cannot mask an inactive writer.
        for mut session in self.store.list("session")? {
            migrate_identity(&mut session);
            session["writerConnected"] = json!(false);
            session["workState"] = json!("disconnected");
            if session["transport"] == "archive" {
                let id = required(&session, "id")?;
                self.store.put("session", id, &session, None)?;
                continue;
            }
            if !session["activityUpdatedAt"].is_string() {
                session["activityUpdatedAt"] = session["updatedAt"].clone();
            }
            if !matches!(session["status"].as_str(), Some("closed" | "failed")) {
                session["status"] = json!("disconnected");
            }
            session["capabilities"] = json!([]);
            let id = required(&session, "id")?.to_owned();
            self.store
                .put("session", &id, &session, Some("session.updated"))?;
            self.store.cancel_session_interactions(&id)?;
        }
        for mut session in self.store.list("session")? {
            if session["transport"] != "archive" {
                self.set_inactive_capabilities(&mut session);
                self.store.put(
                    "session",
                    required(&session, "id")?,
                    &session,
                    Some("session.updated"),
                )?;
            }
        }
        Ok(())
    }
    fn saved_source(&self, session: &Value) -> Result<(PathBuf, String)> {
        let file = PathBuf::from(required(session, "sessionFile")?).canonicalize()?;
        let (header, _) = archive::load(&file)?;
        let native_id = required(&header, "id")?;
        if session["journalId"]
            .as_str()
            .is_some_and(|id| id != native_id)
        {
            bail!("Saved session identity changed; refusing ambiguous resume");
        }
        let root = PathBuf::from(required(session, "cwd")?).canonicalize()?;
        let project = self.store.get("project", required(session, "projectId")?)?;
        if Path::new(required(&project, "path")?).canonicalize()? != root
            || Path::new(required(&header, "cwd")?).canonicalize()? != root
            || session["cwd"].as_str() != root.to_str()
        {
            bail!("Saved session root differs from its registered project; refusing resume");
        }
        Ok((file, native_id.to_owned()))
    }
    fn set_inactive_capabilities(&self, session: &mut Value) {
        let id = session["id"].as_str().unwrap_or_default().to_owned();
        let connected = self
            .links
            .lock()
            .get(&id)
            .is_some_and(|link| link.rpc.is_some() || link.bridge.is_some());
        session["writerConnected"] = json!(connected);
        if !connected {
            session["workState"] = json!("disconnected");
        }
        let resumable = !connected
            && !self.managed_children.lock().contains(&id)
            && self.saved_source(session).is_ok_and(|(file, native_id)| {
                // This object's persisted status can still be the pre-disconnect snapshot.
                let others_live = self
                    .store
                    .list("session")
                    .map(|sessions| {
                        sessions.iter().any(|other| {
                            other["id"] != id
                                && other["transport"] != "archive"
                                && !matches!(
                                    other["status"].as_str(),
                                    Some("closed" | "failed" | "disconnected")
                                )
                                && (other["id"] == native_id
                                    || other["sessionFile"]
                                        .as_str()
                                        .and_then(|path| Path::new(path).canonicalize().ok())
                                        .as_ref()
                                        == Some(&file))
                        })
                    })
                    .unwrap_or(true);
                !others_live && archive::ensure_source_inactive(&native_id, &file).is_ok()
            });
        session["capabilities"] = if resumable {
            json!(["session.resume"])
        } else {
            json!([])
        };
    }
    pub fn managed_rpc_sessions(&self) -> usize {
        self.managed_children.lock().len()
    }
    pub async fn update_blockers(&self) -> Result<Value> {
        let managed = self.managed_children.lock().clone();
        let mut blockers = Vec::new();
        for (id, link) in self.links.lock().iter() {
            if link.bridge.is_some() && !managed.contains(id) {
                blockers.push(json!({"sessionId":id,"kind":"external_writer","reason":"An external terminal owns this writer; close it explicitly"}));
            }
        }
        for id in &managed {
            let session = self.store.get("session", id)?;
            blockers.push(json!({"sessionId":id,"kind":if session_idle(&session) {"idle_managed"} else {"active_work"},"reason":if session_idle(&session) {"Save and close this idle managed writer before updating"} else {"This managed writer has active or unsettled work"}}));
        }
        let admitted = self.admitted_commands.load(Ordering::SeqCst);
        let inflight = self.responses.lock().len();
        if admitted != 0 || inflight != 0 {
            blockers.push(json!({"kind":"inflight","reason":"A command is still awaiting its actual outcome"}));
        }
        for interaction in self
            .store
            .list("interaction")?
            .iter()
            .filter(|i| i["status"] == "pending")
        {
            blockers.push(json!({"sessionId":interaction["sessionId"],"kind":"human_wait","reason":"A human decision is pending"}));
        }
        Ok(
            json!({"blockers":blockers,"managedRpcSessions":managed.len(),"admittedCommands":admitted,"inflightResponses":inflight,"updatePending":self.update_pending.load(Ordering::SeqCst)}),
        )
    }
    pub async fn close_idle_managed(&self) -> Result<Value> {
        let ids = {
            let _guard = self.starting.lock().await;
            if self.update_pending.load(Ordering::SeqCst)
                || self.admitted_commands.load(Ordering::SeqCst) != 0
                || !self.responses.lock().is_empty()
            {
                return Err(command_error(
                    "session_busy",
                    "An update or acknowledged command is already in flight",
                ));
            }
            let ids = self
                .managed_children
                .lock()
                .iter()
                .cloned()
                .collect::<Vec<_>>();
            if self
                .links
                .lock()
                .iter()
                .any(|(id, link)| link.bridge.is_some() && !ids.contains(id))
            {
                return Err(command_error(
                    "session_busy",
                    "An external terminal owns a writer; no managed writer was closed",
                ));
            }
            for id in &ids {
                let session = self.store.get("session", id)?;
                if !session_idle(&session)
                    || self
                        .store
                        .list("interaction")?
                        .iter()
                        .any(|i| i["sessionId"] == *id && i["status"] == "pending")
                {
                    return Err(command_error(
                        "session_busy",
                        "Managed work or a human decision remains; no writer was closed",
                    ));
                }
                self.bridge_link(id)?;
            }
            self.update_pending.store(true, Ordering::SeqCst);
            ids
        };
        let result: Result<Value> = async {
            for id in &ids {
                self.bridge_command(id, "session.flush", json!({})).await?;
            }
            for id in &ids {
                self.child_shutdown
                    .lock()
                    .get(id)
                    .context("Managed shutdown owner disappeared")?
                    .send(())
                    .context("Managed shutdown channel closed")?;
            }
            tokio::time::timeout(Duration::from_secs(20), async {
                while ids
                    .iter()
                    .any(|id| self.managed_children.lock().contains(id))
                {
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
            })
            .await
            .map_err(|_| {
                command_error(
                    "outcome_unknown",
                    "Managed children have not acknowledged durable shutdown; do not update yet",
                )
            })?;
            for id in &ids {
                self.saved_source(&self.store.get("session", id)?)?;
            }
            Ok(json!({"closed":true,"sessionIds":ids,"savedSessionIds":ids}))
        }
        .await;
        self.update_pending.store(false, Ordering::SeqCst);
        result
    }
    pub async fn prepare_update(&self) -> Result<Value> {
        let _guard = self.starting.lock().await;
        if self
            .links
            .lock()
            .iter()
            .any(|(id, link)| link.bridge.is_some() && !self.managed_children.lock().contains(id))
        {
            return Err(command_error(
                "session_busy",
                "An external terminal still owns a live writer; close it explicitly before updating",
            ));
        }
        if self.managed_rpc_sessions() != 0
            || self.admitted_commands.load(Ordering::SeqCst) != 0
            || !self.responses.lock().is_empty()
        {
            return Err(command_error(
                "session_busy",
                "Finish active managed sessions and acknowledged commands before updating",
            ));
        }
        self.update_pending.store(true, Ordering::SeqCst);
        Ok(json!({"prepared":true,"managedRpcSessions":0}))
    }
    pub async fn cancel_update(&self) -> Value {
        // The reservation excludes both new commands and sessions until local update cancellation.
        let _guard = self.starting.lock().await;
        self.update_pending.store(false, Ordering::SeqCst);
        json!({"prepared":false,"managedRpcSessions":self.managed_rpc_sessions()})
    }
    async fn exchange(
        &self,
        session_id: &str,
        sender: mpsc::Sender<Value>,
        mut frame: Value,
    ) -> Result<Value> {
        let control_snapshot = matches!(
            frame["action"].as_str(),
            Some("session.command" | "session.control")
        )
        .then(|| self.store.get("session", session_id))
        .transpose()?;
        let durable_control = control_snapshot.is_some();
        let id = Uuid::new_v4().to_string();
        let bridge = frame["type"] == "command";
        frame["id"] = json!(id);
        if frame["type"] == "extension_ui_response" {
            frame["id"] = frame["targetId"].take();
            frame.as_object_mut().unwrap().remove("targetId");
            frame["responseId"] = json!(id);
        }
        let (tx, rx) = oneshot::channel();
        self.responses.lock().insert(
            id.clone(),
            PendingResponse {
                session: session_id.to_owned(),
                bridge,
                tx,
                control_snapshot,
            },
        );
        if sender.send(frame).await.is_err() {
            self.responses.lock().remove(&id);
            return Err(command_error(
                "session_disconnected",
                "OMP control connection has closed; reconnect the session",
            ));
        }
        let result = if durable_control {
            rx.await.map_err(|_| command_error("outcome_unknown", "OMP disconnected before acknowledging; outcome unknown. Refresh state before retrying"))
        } else {
            tokio::time::timeout(Duration::from_secs(120),rx).await.map_err(|_| command_error("outcome_unknown","OMP did not acknowledge within 120 seconds. Refresh state before issuing a new command")).and_then(|reply| reply.map_err(|_| command_error("outcome_unknown","OMP disconnected before acknowledging; outcome unknown. Refresh state before retrying")))
        };
        self.responses.lock().remove(&id);
        let reply = result?;
        if reply["success"] != true {
            return Err(command_error(
                reply["code"]
                    .as_str()
                    .or(reply["error"]["code"].as_str())
                    .unwrap_or("command_rejected"),
                reply["error"]["message"]
                    .as_str()
                    .or(reply["error"].as_str())
                    .unwrap_or("OMP rejected the command"),
            ));
        }
        Ok(reply["data"].clone())
    }
    fn cancel_transport_interactions(&self, session: &str, native: bool) -> Result<()> {
        for mut interaction in self.store.list("interaction")? {
            if interaction["sessionId"] == session
                && interaction["status"] == "pending"
                && (interaction["responseTransport"] == "rpc") == native
            {
                interaction["status"] = json!("cancelled");
                interaction["cancellationReason"] = json!("disconnect");
                self.store.put(
                    "interaction",
                    required(&interaction, "id")?,
                    &interaction,
                    Some("interaction.resolved"),
                )?;
            }
        }
        Ok(())
    }
    fn fail_pending(&self, session: &str, bridge: bool) {
        self.responses
            .lock()
            .retain(|_, pending| pending.session != session || pending.bridge != bridge);
    }
    fn rpc_link(&self, id: &str) -> Result<mpsc::Sender<Value>> {
        self.links
            .lock()
            .get(id)
            .and_then(|l| l.rpc.clone())
            .ok_or_else(|| {
                command_error(
                    "session_disconnected",
                    "Session has no connected native RPC runtime; resume or reconnect it",
                )
            })
    }
    fn bridge_link(&self, id: &str) -> Result<mpsc::Sender<Value>> {
        self.links
            .lock()
            .get(id)
            .and_then(|l| l.bridge.clone())
            .ok_or_else(|| {
                command_error(
                    "session_disconnected",
                    "Session bridge is disconnected; reconnect before issuing this command",
                )
            })
    }
    async fn native(&self, id: &str, frame: Value) -> Result<Value> {
        self.exchange(id, self.rpc_link(id)?, frame).await
    }
    async fn bridge_command(&self, id: &str, action: &str, payload: Value) -> Result<Value> {
        self.exchange(
            id,
            self.bridge_link(id)?,
            json!({"type":"command","action":action,"payload":payload}),
        )
        .await
    }
    pub async fn controls(&self, id: &str, view: &str, args: Value) -> Result<Value> {
        if !matches!(
            view,
            "commands"
                | "state"
                | "queue"
                | "tree"
                | "entries"
                | "btw"
                | "plan"
                | "goal"
                | "agents"
                | "agentMessages"
                | "jobs"
                | "models"
                | "effort"
                | "usage"
        ) || !args.is_object()
        {
            return Err(command_error(
                "invalid_command",
                "Unknown control view or malformed arguments",
            ));
        }
        let session = self.store.get("session", id)?;
        if !session["capabilities"]
            .as_array()
            .is_some_and(|caps| caps.iter().any(|cap| cap == "session.controls"))
        {
            return Err(command_error(
                "unsupported",
                "The connected runtime does not provide host controls",
            ));
        }
        let mut data = self
            .bridge_command(
                id,
                "session.controls",
                json!({"view":view,"arguments":args}),
            )
            .await?;
        data.as_object_mut()
            .context("Host control query returned a non-object")?
            .remove("_omputerState");
        Ok(public_event(&data))
    }
    pub async fn models(&self) -> Result<Vec<Value>> {
        let sessions: Vec<(String, bool)> = self
            .links
            .lock()
            .iter()
            .filter(|(_, l)| l.rpc.is_some() || l.bridge.is_some())
            .map(|(id, l)| (id.clone(), l.rpc.is_some()))
            .collect();
        for (id, rpc) in sessions {
            let result = if rpc {
                self.native(&id, json!({"type":"get_available_models"}))
                    .await
            } else {
                self.bridge_command(&id, "session.models", json!({})).await
            };
            if let Ok(data) = result {
                let models = data["models"]
                    .as_array()
                    .map(|a| a.iter().map(public_model).collect())
                    .unwrap_or_default();
                *self.models.lock() = models;
                break;
            }
        }
        Ok(self.models.lock().clone())
    }
    pub async fn command(self: &Arc<Self>, request: &Value) -> Result<Value> {
        let _admitted = {
            let _guard = self.starting.lock().await;
            if self.update_pending.load(Ordering::SeqCst) {
                return Err(command_error(
                    "update_pending",
                    "A local update is prepared; finish or cancel it before sending commands",
                ));
            }
            self.admitted_commands.fetch_add(1, Ordering::SeqCst);
            AdmittedCommand(&self.admitted_commands)
        };
        let action = request["action"]
            .as_str()
            .context("Command action is required")?;
        let payload = &request["payload"];
        if action == "session.start" {
            return self.start(payload, None).await;
        }
        if action == "session.resume" {
            let id = payload["sessionId"]
                .as_str()
                .or(request["sessionId"].as_str())
                .context("sessionId is required")?;
            let session = self.store.get("session", id)?;
            let (file, _) = self.saved_source(&session)?;
            let payload = json!({"projectId":session["projectId"],"name":session["name"]});
            return self.start(&payload, Some((id.to_owned(), file))).await;
        }
        if action == "interaction.respond" {
            let interaction_id = payload["interactionId"]
                .as_str()
                .context("interactionId is required")?;
            let interaction = self.store.get("interaction", interaction_id)?;
            let id = interaction["sessionId"]
                .as_str()
                .context("Interaction has no session")?;
            if request["sessionId"].as_str().is_some_and(|s| s != id) {
                bail!("Interaction belongs to a different session");
            }
            let native = interaction["responseTransport"] == "rpc";
            if native {
                self.rpc_link(id)?;
            } else {
                self.bridge_link(id)?;
            }
            validate_answer(&interaction, payload)?;
            self.store
                .claim_interaction(interaction_id, request["id"].as_str().unwrap_or_default())?;
            let result = if native {
                let mut response =
                    json!({"type":"extension_ui_response","targetId":interaction_id});
                if payload["cancelled"] == true {
                    response["cancelled"] = json!(true);
                } else if interaction["method"] == "ask" {
                    response["answers"] = payload["answer"]["results"].clone();
                } else if matches!(interaction["method"].as_str(), Some("confirm" | "approval")) {
                    response["confirmed"] = payload["confirmed"].clone();
                } else {
                    response["value"] = payload["value"].clone();
                }
                self.native(id, response).await
            } else {
                self.bridge_command(id, action, payload.clone()).await
            };
            match result {
                Ok(data) => {
                    self.store.end_interaction(
                        interaction_id,
                        if payload["cancelled"] == true {
                            "cancelled"
                        } else {
                            "resolved"
                        },
                    )?;
                    return Ok(data);
                }
                Err(e) => {
                    if matches!(
                        error_code(&e),
                        "invalid_answer"
                            | "interaction_not_found"
                            | "stale_interaction"
                            | "command_rejected"
                    ) {
                        self.store.release_interaction_claim(
                            interaction_id,
                            request["id"].as_str().unwrap_or_default(),
                        )?;
                    }
                    return Err(e);
                }
            }
        }
        let id = request["sessionId"]
            .as_str()
            .context("sessionId is required")?;
        let session = self.store.get("session", id)?;
        if session["transport"] == "archive" {
            bail!("Archive is read-only; resume it before issuing commands");
        }
        if matches!(action, "session.command" | "session.control") {
            validate_control_identity(&session, payload)?;
            let mut result = self.exchange(id, self.bridge_link(id)?, json!({"type":"command","action":action,"payload":payload,"operationId":required(request,"id")?})).await?;
            if let Some(data) = result.as_object_mut() {
                data.remove("_omputerState");
                data.remove("_omputerMessages");
                let current = self.store.get("session", id)?;
                for key in ["journalId", "bindingRevision", "leafId"] {
                    data.insert(key.to_owned(), current[key].clone());
                }
            }
            return Ok(public_event(&result));
        }
        if action == "agent.command" {
            return self.bridge_command(id, action, payload.clone()).await;
        }
        if session["transport"] == "bridge" {
            let result = self.bridge_command(id, action, payload.clone()).await?;
            return Ok(result);
        }
        let frame = match action {
            "session.prompt" | "session.steer" | "session.follow_up" => {
                let message = payload["message"].as_str().context("message is required")?;
                json!({"type":action.trim_start_matches("session."),"message":message,"images":payload["images"].as_array().cloned().unwrap_or_default(),"runCommands":payload["runCommands"].as_bool().unwrap_or(false),"expandPromptTemplates":payload["expandPromptTemplates"].as_bool().unwrap_or(false)})
            }
            "session.abort" => json!({"type":"abort"}),
            "session.model" => {
                json!({"type":"set_model","provider":required(payload,"provider")?,"modelId":required(payload,"modelId")?})
            }
            "session.thinking" => {
                json!({"type":"set_thinking_level","level":required(payload,"level")?})
            }
            "session.compact" => {
                json!({"type":"compact","customInstructions":payload["instructions"]})
            }
            "session.rename" => json!({"type":"set_session_name","name":required(payload,"name")?}),
            "session.bash" => json!({"type":"bash","command":required(payload,"command")?}),
            "session.refresh" => {
                self.refresh(id).await?;
                return self.store.get("session", id);
            }
            _ => bail!("Unsupported action {action}"),
        };
        let result = self.native(id, frame).await?;
        if matches!(
            action,
            "session.model" | "session.thinking" | "session.rename" | "session.abort"
        ) {
            let state = self.native(id, json!({"type":"get_state"})).await?;
            self.apply_state(id, &state, false)?;
        }
        Ok(result)
    }
    async fn start(
        self: &Arc<Self>,
        payload: &Value,
        resume: Option<(String, PathBuf)>,
    ) -> Result<Value> {
        let _guard = self.starting.lock().await;
        if self.update_pending.load(Ordering::SeqCst) {
            return Err(command_error(
                "update_pending",
                "A local update is prepared; finish or cancel it before starting a session",
            ));
        }
        let project = self.store.get("project", required(payload, "projectId")?)?;
        let root = PathBuf::from(project["path"].as_str().context("Project root missing")?);
        if root.canonicalize()? != root {
            bail!("Registered project root changed; register its current canonical path locally");
        }
        if !self.config.bridge.is_file() {
            bail!(
                "OMP bridge extension not found at {}. Start daemon with --bridge /absolute/path/to/omputer/bridge/index.ts",
                self.config.bridge.display()
            );
        }
        let id = resume
            .as_ref()
            .map(|(id, _)| id.clone())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        if let Some((_, file)) = &resume {
            let session = self.store.get("session", &id)?;
            let (saved, native_id) = self.saved_source(&session)?;
            if saved != *file {
                bail!("Saved session source changed before resume");
            }
            archive::ensure_inactive(&self.store, &native_id, file)?;
            if self.managed_children.lock().contains(&id) {
                bail!("The previous managed process still owns this session; wait for its exit");
            }
            if self
                .links
                .lock()
                .get(&id)
                .is_some_and(|l| l.rpc.is_some() || l.bridge.is_some())
            {
                bail!("Session is already connected; a second process will not be started");
            }
        }
        let mut command = Command::new(&self.config.omp);
        command
            .args(["--mode", "rpc-ui", "--no-ui", "--no-title"])
            .arg("--cwd")
            .arg(&root)
            .arg("-e")
            .arg(&self.config.bridge)
            .env("OMPUTER_STATE_DIR", &self.config.state_dir)
            .env("OMPUTER_RPC_MANAGED", "1")
            .env("OMPUTER_SESSION_ID", &id)
            .current_dir(&root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(false);
        if let Some((_, file)) = &resume {
            command.arg("--resume").arg(file);
        } else {
            let session_dir = self.config.state_dir.join("sessions").join(&id);
            std::fs::create_dir_all(&session_dir)?;
            command.arg("--session-dir").arg(session_dir);
        }
        if let (Some(provider), Some(model)) = (
            payload["model"]["provider"].as_str(),
            payload["model"]["id"].as_str(),
        ) {
            command.arg("--model").arg(format!("{provider}/{model}"));
        }
        let (tx, rx) = mpsc::channel(256);
        let mut session = if resume.is_some() {
            self.store.get("session", &id)?
        } else {
            json!({"id":id,"projectId":project["id"],"name":payload["name"].as_str().unwrap_or("OMP"),"cwd":root,"todos":[],"subagents":[]})
        };
        if !session["activityUpdatedAt"].is_string() {
            session["activityUpdatedAt"] = json!(now());
        }
        session["transport"] = json!("rpc");
        session["status"] = json!("idle");
        session["updatedAt"] = json!(now());
        session["capabilities"] = json!([]);
        session["writerConnected"] = json!(true);
        session["workState"] = json!("settled");
        session["turnError"] = Value::Null;
        session["lastError"] = Value::Null;
        self.store
            .put("session", &id, &session, Some("session.updated"))?;
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                session["status"] = json!("failed");
                session["lastError"] = json!("Cannot launch the configured local OMP runtime");
                self.set_inactive_capabilities(&mut session);
                self.store
                    .put("session", &id, &session, Some("session.updated"))?;
                return Err(error).with_context(|| {
                    format!("Cannot launch {} --mode rpc-ui", self.config.omp.display())
                });
            }
        };
        let stdin = child.stdin.take().context("OMP stdin unavailable")?;
        let stdout = child.stdout.take().context("OMP stdout unavailable")?;
        let stderr = child.stderr.take().context("OMP stderr unavailable")?;
        self.managed_children.lock().insert(id.clone());
        self.links.lock().entry(id.clone()).or_default().rpc = Some(tx);
        let (ready_tx, ready_rx) = oneshot::channel();
        let (failure_tx, mut failure_rx) = mpsc::unbounded_channel::<()>();
        self.child_shutdown
            .lock()
            .insert(id.clone(), failure_tx.clone());
        let (stdin_close_tx, stdin_close_rx) = oneshot::channel();
        let app = self.clone();
        let sid = id.clone();
        let failed = failure_tx.clone();
        tokio::spawn(async move {
            tokio::select! { _ = write_frames(stdin, rx) => {}, _ = stdin_close_rx => {} }
            app.fail_pending(&sid, false);
            let _ = failed.send(());
        });
        let app = self.clone();
        let sid = id.clone();
        let failed = failure_tx.clone();
        let mut stdout_reader = tokio::spawn(async move {
            let mut reader = BufReader::new(stdout);
            let mut decoder = rpc_transport::Decoder::default();
            let mut ready = Some(ready_tx);
            let result: Result<()> = async {
                while let Some(line) =
                    rpc_transport::line(&mut reader, rpc_transport::FRAME_BYTES).await?
                {
                    let raw: Value =
                        serde_json::from_str(&line).context("Invalid native RPC JSON")?;
                    if let Some(frame) = decoder.push(raw)? {
                        if frame["type"] == "ready" {
                            if let Some(tx) = ready.take() {
                                let _ = tx.send(frame);
                            }
                            continue;
                        }
                        app.frame(&sid, frame, false).await?;
                    }
                }
                decoder.finish()
            }
            .await;
            if let Err(error) = result {
                app.runtime_error(&sid, &format!("Native RPC transport failed: {error}"));
            }
            app.fail_pending(&sid, false);
            let _ = failed.send(());
        });
        // Stderr may contain provider credentials; drain without forwarding to logs/network.
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr);
            let _ = tokio::io::copy(&mut reader, &mut tokio::io::sink()).await;
        });
        let app = self.clone();
        let sid = id.clone();
        tokio::spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status,
                _ = failure_rx.recv() => {
                    // stdin EOF is OMP's durable dispose path. Only our exact spawned child
                    // may be terminated, and only after bounded graceful teardown fails.
                    if let Some(link) = app.links.lock().get_mut(&sid) { link.rpc = None; }
                    app.fail_pending(&sid, false);
                    let _ = stdin_close_tx.send(());
                    match tokio::time::timeout(Duration::from_secs(10), child.wait()).await {
                        Ok(status) => status,
                        Err(_) => { let _ = child.start_kill(); child.wait().await }
                    }
                }
            };
            if tokio::time::timeout(Duration::from_secs(2), &mut stdout_reader)
                .await
                .is_err()
            {
                stdout_reader.abort();
                let _ = stdout_reader.await;
            }
            let _cleanup_guard = app.starting.lock().await;
            app.managed_children.lock().remove(&sid);
            app.child_shutdown.lock().remove(&sid);
            if let Some(link) = app.links.lock().get_mut(&sid) {
                link.rpc = None;
            }
            app.fail_pending(&sid, false);
            if let Ok(mut session) = app.store.get("session", &sid) {
                let failed = status.as_ref().is_err()
                    || status.as_ref().is_ok_and(|s| !s.success())
                    || session["status"] == "failed";
                session["status"] = json!(if failed { "failed" } else { "closed" });
                app.set_inactive_capabilities(&mut session);
                session["updatedAt"] = json!(now());
                if failed {
                    if !session["lastError"].is_string() {
                        session["lastError"] = json!(
                            "OMP process exited unsuccessfully; inspect OMP locally for provider/runtime details"
                        );
                    }
                    let _ = app.notify(&sid, "error", "OMP process failed", None);
                }
                let _ = app
                    .store
                    .put("session", &sid, &session, Some("session.updated"));
                let _ = app.cancel_transport_interactions(&sid, true);
            }
        });
        drop(_guard);
        let ready = match tokio::time::timeout(Duration::from_secs(30), ready_rx).await {
            Ok(Ok(ready)) => ready,
            _ => {
                let _ = failure_tx.send(());
                return Err(command_error(
                    "unsupported_runtime",
                    "OMP disconnected or did not advertise native RPC readiness within 30 seconds",
                ));
            }
        };
        if !ready["supportedProtocolVersions"]
            .as_array()
            .is_some_and(|a| a.iter().any(|v| v == 2))
            || ready["maxFrameBytes"] != rpc_transport::FRAME_BYTES
            || ready["maxReassembledFrameBytes"] != rpc_transport::LOGICAL_BYTES
        {
            let _ = failure_tx.send(());
            return Err(command_error(
                "unsupported_runtime",
                "Native OMP must advertise RPC v2, 1 MiB frames and 64 MiB reassembly; update the local OMP runtime",
            ));
        }
        let negotiated = match self
            .native(
                &id,
                json!({"type":"negotiate_protocol","protocolVersion":2}),
            )
            .await
        {
            Ok(data) => data,
            Err(error) => {
                let _ = failure_tx.send(());
                return Err(error);
            }
        };
        if negotiated["protocolVersion"] != 2 {
            let _ = failure_tx.send(());
            return Err(command_error(
                "unsupported_runtime",
                "OMP failed native RPC v2 negotiation",
            ));
        }
        let setup: Result<Value> = async {
            self.native(&id, json!({"type":"set_ask_dialog","enabled":true}))
                .await?;
            self.native(
                &id,
                json!({"type":"set_subagent_subscription","level":"progress"}),
            )
            .await?;
            if let Some(name) = payload["name"].as_str() {
                self.native(&id, json!({"type":"set_session_name","name":name}))
                    .await?;
            }
            self.refresh(&id).await?;
            if let Some(prompt) = payload["prompt"].as_str().filter(|p| !p.is_empty()) {
                self.native(&id, json!({"type":"prompt","message":prompt}))
                    .await?;
            }
            Ok(json!({"sessionId":id,"session":self.store.get("session",&id)?}))
        }
        .await;
        if setup.is_err() {
            let _ = failure_tx.send(());
        }
        setup
    }
    pub async fn refresh(&self, id: &str) -> Result<()> {
        let revision = *self.revisions.lock().get(id).unwrap_or(&0);
        let state = self.native(id, json!({"type":"get_state"})).await?;
        self.apply_state(id, &state, false)?;
        let subs = self.native(id, json!({"type":"get_subagents"})).await?;
        let mut session = self.store.get("session", id)?;
        session["subagents"] = subs["subagents"]
            .as_array()
            .cloned()
            .map(Value::Array)
            .unwrap_or(json!([]));
        self.store
            .put("session", id, &session, Some("session.updated"))?;
        if state["isStreaming"] == true || state["isCompacting"] == true {
            return Err(command_error(
                "session_busy",
                "History is changing; wait for idle before refreshing history",
            ));
        }
        let mut cursor = None;
        let mut seen = std::collections::HashSet::new();
        let mut total = None;
        let mut messages = Vec::new();
        loop {
            let mut request = json!({"type":"get_messages_page","limit":256});
            if let Some(cursor) = &cursor {
                request["cursor"] = json!(cursor);
            }
            let page = self.native(id, request).await?;
            let count = page["totalMessages"]
                .as_u64()
                .context("Native history has no valid totalMessages")?;
            if total.is_some_and(|n| n != count) {
                bail!("Native history total changed while paging");
            }
            total = Some(count);
            let batch = page["messages"]
                .as_array()
                .context("Native history page has no messages array")?;
            messages.extend(batch.iter().cloned());
            if messages.len() as u64 > count {
                bail!("Native history exceeded advertised total");
            }
            match page.get("nextCursor") {
                None => break,
                Some(Value::String(next)) if !next.is_empty() && next.len() <= 2048 => {
                    if batch.is_empty() || !seen.insert(next.clone()) {
                        bail!("Native history cursor repeated or made no progress");
                    }
                    cursor = Some(next.clone());
                }
                _ => bail!("Native history returned an invalid cursor"),
            }
        }
        if Some(messages.len() as u64) != total {
            bail!("Native history ended before its advertised total");
        }
        let revisions = self.revisions.lock();
        if *revisions.get(id).unwrap_or(&0) != revision {
            return Err(command_error(
                "stale_cursor",
                "Transcript changed while paging; wait for idle and refresh again",
            ));
        }
        let views = messages
            .iter()
            .filter(|m| m["role"].is_string())
            .map(|message| {
                let mid = message_id(id, message);
                archive::message_view(message, &mid, &json!(now()))
            })
            .collect::<Vec<_>>();
        self.store.replace_messages(id, &views)?;
        let mut session = self.store.get("session", id)?;
        session["lastUserMessage"] = json!("");
        session["lastAssistantText"] = json!("");
        session["lastUserMessageAt"] = Value::Null;
        session["lastAssistantMessageAt"] = Value::Null;
        for message in &messages {
            if normal_user(message) {
                let text = archive::assistant_text(message);
                if !text.trim().is_empty() && !text.trim_start().starts_with('/') {
                    session["lastUserMessage"] = json!(text);
                    session["lastUserMessageAt"] = message_time(message);
                }
            }
            if final_assistant(message) {
                session["lastAssistantText"] = json!(archive::assistant_text(message));
                session["lastAssistantMessageAt"] = message_time(message);
            }
        }
        for key in ["lastUserMessageAt", "lastAssistantMessageAt"] {
            let timestamp = session[key].as_str().unwrap_or_default().to_owned();
            if session["activityUpdatedAt"].as_str().unwrap_or_default() < timestamp.as_str() {
                session["activityUpdatedAt"] = json!(timestamp);
            }
        }
        self.store
            .put("session", id, &session, Some("session.updated"))?;
        Ok(())
    }
    fn apply_control_state(&self, id: &str, previous: &Value, state: &Value) -> Result<()> {
        let current = self.store.get("session", id)?;
        if current["journalId"] != previous["journalId"]
            || current["bindingRevision"] != previous["bindingRevision"]
        {
            return Err(command_error(
                "stale_identity",
                "Writer binding changed while the host control executed",
            ));
        }
        let journal = required(state, "journalId")?;
        let file = PathBuf::from(required(state, "sessionFile")?).canonicalize()?;
        let (header, _) = archive::load(&file)?;
        let root = PathBuf::from(required(&current, "cwd")?).canonicalize()?;
        if header["id"] != journal
            || Path::new(required(&header, "cwd")?).canonicalize()? != root
            || Path::new(required(state, "cwd")?).canonicalize()? != root
        {
            return Err(command_error(
                "source_mismatch",
                "Control outcome source header or root differs from its registered writer",
            ));
        }
        for other in self.store.list("session")? {
            if other["id"] != id
                && other["writerConnected"] == true
                && (other["journalId"] == journal
                    || other["sessionFile"]
                        .as_str()
                        .and_then(|p| Path::new(p).canonicalize().ok())
                        .as_ref()
                        == Some(&file))
            {
                return Err(command_error(
                    "source_mismatch",
                    "Another live writer already owns the control outcome",
                ));
            }
        }
        let mut next = current;
        if next["journalId"] != journal || next["sessionFile"].as_str() != file.to_str() {
            if next["originalSource"].is_null() {
                next["originalSource"] = json!({"journalId":previous["journalId"],"sessionFile":previous["sessionFile"]});
            }
            next["journalId"] = json!(journal);
            next["sessionFile"] = json!(file);
        }
        self.apply_state_inner(id, state, true, Some(next))
    }
    fn apply_state(&self, id: &str, state: &Value, bridge: bool) -> Result<()> {
        self.apply_state_inner(id, state, bridge, None)
    }
    fn apply_state_inner(
        &self,
        id: &str,
        state: &Value,
        bridge: bool,
        session: Option<Value>,
    ) -> Result<()> {
        let mut session = match session {
            Some(session) => session,
            None => self.store.get("session", id)?,
        };
        migrate_identity(&mut session);
        if bridge {
            if let Some(journal) = state["journalId"].as_str() {
                if session["journalId"]
                    .as_str()
                    .is_some_and(|current| current != journal)
                {
                    bail!("Runtime journal identity differs from the registered saved session");
                }
                session["journalId"] = json!(journal);
            }
        } else if let Some(provider) = state["sessionId"].as_str() {
            session["providerSessionId"] = json!(provider);
        }
        for key in [
            "leafId",
            "hostControls",
            "providerSessionId",
            "queuedMessages",
            "contextUsage",
            "turnError",
            "isStreaming",
            "isCompacting",
        ] {
            if let Some(value) = state.get(key) {
                session[key] = value.clone();
            }
        }
        session["writerConnected"] = json!(
            self.links
                .lock()
                .get(id)
                .is_some_and(|link| link.rpc.is_some() || link.bridge.is_some())
        );
        session["bindingRevision"] = json!(
            self.links
                .lock()
                .get(id)
                .and_then(|link| link.bridge_generation.clone())
        );
        if let Some(model) = state.get("model").filter(|m| m.is_object()) {
            session["model"] = public_model(model);
        }
        for key in ["thinkingLevel", "sessionFile"] {
            if let Some(value) = state.get(key) {
                session[key] = value.clone();
            }
        }
        if let Some(name) = state["sessionName"]
            .as_str()
            .or(state["name"].as_str())
            .filter(|name| !name.is_empty())
        {
            session["name"] = json!(name);
        }
        session["todos"] = state
            .get(if bridge { "todos" } else { "todoPhases" })
            .cloned()
            .unwrap_or_else(|| session["todos"].clone());
        if state["subagents"].is_array() {
            session["subagents"] = state["subagents"].clone();
        }
        if bridge {
            if let Some(status) = state["status"].as_str().filter(|s| {
                matches!(
                    *s,
                    "idle" | "running" | "waiting" | "disconnected" | "failed" | "closed"
                )
            }) {
                session["status"] = json!(status);
            }
            if session["transport"] == "bridge" {
                session["capabilities"] = state["capabilities"].clone();
            } else {
                let mut caps = rpc_capabilities()
                    .into_iter()
                    .map(str::to_owned)
                    .collect::<Vec<_>>();
                if let Some(advertised) = state["capabilities"].as_array() {
                    for capability in advertised.iter().filter_map(Value::as_str).filter(|s| {
                        s.starts_with("agent.")
                            || *s == "interaction.respond"
                            || *s == "project.checkpoint"
                            || s.starts_with("session.control")
                            || *s == "session.command"
                    }) {
                        if !caps.iter().any(|c| c == capability) {
                            caps.push(capability.to_owned());
                        }
                    }
                }
                session["capabilities"] = json!(caps);
            }
        } else {
            let mut capabilities = rpc_capabilities()
                .into_iter()
                .map(str::to_owned)
                .collect::<Vec<_>>();
            if self
                .links
                .lock()
                .get(id)
                .is_some_and(|link| link.bridge.is_some())
            {
                for capability in session["capabilities"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                    .filter(|capability| {
                        capability.starts_with("agent.")
                            || *capability == "project.checkpoint"
                            || *capability == "interaction.respond"
                            || capability.starts_with("session.control")
                            || *capability == "session.command"
                    })
                {
                    if !capabilities.iter().any(|existing| existing == capability) {
                        capabilities.push(capability.to_owned());
                    }
                }
            }
            session["capabilities"] = json!(capabilities);
            session["status"] = json!(runtime_status(
                state,
                self.store
                    .list("interaction")?
                    .iter()
                    .any(|i| i["sessionId"] == id && i["status"] == "pending")
            ));
            session["hasPendingAsyncWork"] = state["hasPendingAsyncWork"].clone();
            session["isSettled"] = state["isSettled"].clone();
        }
        if bridge {
            for key in ["hasPendingAsyncWork", "isSettled"] {
                if let Some(value) = state.get(key) {
                    session[key] = value.clone();
                }
            }
            let pending = self
                .store
                .list("interaction")?
                .iter()
                .any(|i| i["sessionId"] == id && i["status"] == "pending");
            if pending
                || (state["isStreaming"] == false
                    && state["isCompacting"] != true
                    && (session["hasPendingAsyncWork"] == true || session["isSettled"] == false))
                || (session["status"] == "idle" && session["hasPendingAsyncWork"] == true)
            {
                session["status"] = json!("waiting");
            }
        }
        if session["todos"] != self.store.get("session", id)?["todos"] {
            session["activityUpdatedAt"] = json!(now());
        }
        session["workState"] = json!(work_state(
            &session,
            self.store
                .list("interaction")?
                .iter()
                .any(|i| i["sessionId"] == id && i["status"] == "pending")
        ));
        session["updatedAt"] = json!(now());
        self.store
            .put("session", id, &session, Some("session.updated"))?;
        Ok(())
    }
    fn upsert_message(&self, id: &str, message: &Value, event_id: Option<&str>) -> Result<()> {
        if !message["role"].is_string() {
            return Ok(());
        }
        let mid = message["_entryId"]
            .as_str()
            .filter(|id| !id.is_empty())
            .or(event_id.filter(|id| !id.is_empty()))
            .map(str::to_owned)
            .unwrap_or_else(|| message_id(id, message));
        let msg = archive::message_view(message, &mid, &json!(now()));
        self.store.message(id, &mid, &msg)?;
        Ok(())
    }
    fn record_activity(&self, id: &str, message: &Value, final_message: bool) -> Result<()> {
        let mut session = self.store.get("session", id)?;
        let mut changed = false;
        let timestamp = message_time(message);
        let stamp = timestamp.as_str().unwrap_or_default();
        if normal_user(message) {
            let text = archive::assistant_text(message);
            if !text.trim().is_empty()
                && !text.trim_start().starts_with('/')
                && session["lastUserMessageAt"].as_str().unwrap_or_default() < stamp
            {
                session["lastUserMessage"] = json!(text);
                session["lastUserMessageAt"] = timestamp.clone();
                changed = true;
            }
        }
        if final_message
            && final_assistant(message)
            && session["lastAssistantMessageAt"]
                .as_str()
                .unwrap_or_default()
                < stamp
        {
            session["lastAssistantText"] = json!(archive::assistant_text(message));
            session["lastAssistantMessageAt"] = timestamp.clone();
            changed = true;
        }
        if changed {
            if session["activityUpdatedAt"].as_str().unwrap_or_default() < stamp {
                session["activityUpdatedAt"] = timestamp;
            }
            session["updatedAt"] = json!(now());
            self.store
                .put("session", id, &session, Some("session.updated"))?;
        }
        Ok(())
    }
    fn runtime_error(&self, id: &str, message: &str) {
        if let Ok(mut session) = self.store.get("session", id) {
            session["status"] = json!("failed");
            session["lastError"] = json!(message);
            session["updatedAt"] = json!(now());
            let _ = self
                .store
                .put("session", id, &session, Some("session.updated"));
            let _ = self.notify(id, "error", message, None);
        }
    }
    async fn frame(self: &Arc<Self>, session: &str, mut frame: Value, bridge: bool) -> Result<()> {
        if frame["type"] == "response" {
            if let Some(id) = frame["id"].as_str() {
                let mut responses = self.responses.lock();
                if responses
                    .get(id)
                    .is_some_and(|pending| pending.session == session && pending.bridge == bridge)
                    && let Some(pending) = responses.remove(id)
                {
                    if let Some(previous) = &pending.control_snapshot
                        && let Some(state) = frame["data"]
                            .get("_omputerState")
                            .or(frame.get("_omputerState"))
                    {
                        if let Err(error) = self.apply_control_state(session, previous, state) {
                            frame = json!({"type":"response","success":false,"error":{"code":error_code(&error),"message":error.to_string()}});
                        } else if let Some(messages) = frame["data"]["_omputerMessages"].as_array()
                        {
                            let views = messages
                                .iter()
                                .filter(|m| m["role"].is_string())
                                .map(|message| {
                                    let mid = message_id(session, message);
                                    archive::message_view(message, &mid, &message_time(message))
                                })
                                .collect::<Vec<_>>();
                            if let Err(error) = self.store.replace_messages(session, &views) {
                                frame = json!({"type":"response","success":false,"error":{"code":"outcome_unknown","message":error.to_string()}});
                            }
                        }
                    }
                    let _ = pending.tx.send(frame);
                }
            }
            return Ok(());
        }
        let ty = frame["type"].as_str().unwrap_or_default();
        if bridge {
            match ty {
                "operation_output" => {
                    let operation = required(&frame, "operationId")?;
                    let output_id = required(&frame, "outputId")?;
                    let status = self.store.command_status(operation)?;
                    if status["sessionId"] != session {
                        bail!("Operation output belongs to another session");
                    }
                    self.store.command_output_once(
                        operation,
                        output_id,
                        required(&frame, "kind")?,
                        frame["text"].as_str().context("Output text missing")?,
                    )?;
                    self.bridge_link(session)?
                        .send(json!({"type":"output_ack","outputId":output_id}))
                        .await?;
                    return Ok(());
                }
                "state" => return self.apply_state(session, &frame["session"], true),
                "event" => {
                    self.process_event(session, &frame["event"])?;
                    return Ok(());
                }
                "interaction" => return self.interaction(session, &frame["request"], false),
                "notification" => {
                    self.omp_notification(session, frame.get("data").unwrap_or(&frame))?;
                    return Ok(());
                }
                "checkpoint" => {
                    let result = if frame["sessionId"] != session {
                        Err(command_error(
                            "source_mismatch",
                            "Checkpoint session does not match registered bridge",
                        ))
                    } else {
                        self.store.checkpoint(session, &frame["data"])
                    };
                    if let Some(id) = frame["id"].as_str() {
                        let response = match result {
                            Ok(data) => {
                                json!({"type":"response","id":id,"success":true,"data":data})
                            }
                            Err(error) => {
                                json!({"type":"response","id":id,"success":false,"error":{"code":if error.to_string().contains("memory_conflict") {"memory_conflict"} else {"invalid_checkpoint"},"message":error.to_string()}})
                            }
                        };
                        self.bridge_link(session)?
                            .send(response)
                            .await
                            .context("Bridge closed before checkpoint acknowledgement")?;
                    }
                    return Ok(());
                }
                "interaction_end" => {
                    let id = required(&frame, "id")?;
                    if self
                        .store
                        .get("interaction", id)
                        .is_ok_and(|request| request["sessionId"] == session)
                    {
                        self.store
                            .end_interaction(id, required(&frame, "status")?)?;
                    }
                    return Ok(());
                }
                _ => return Ok(()),
            }
        }
        if ty == "extension_ui_request" {
            let method = frame["method"].as_str().unwrap_or_default();
            if method == "cancel" {
                if let Some(id) = frame["targetId"].as_str()
                    && self
                        .store
                        .get("interaction", id)
                        .is_ok_and(|request| request["sessionId"] == session)
                {
                    self.store.end_interaction(id, "cancelled")?;
                }
                return Ok(());
            }
            if matches!(method, "select" | "confirm" | "input" | "editor" | "ask") {
                self.interaction(session, &frame, true)?;
            } else if method == "notify" {
                let mut notification = frame.clone();
                notification["nativeSource"] = json!(true);
                self.omp_notification(session, &notification)?;
            }
            return Ok(());
        }
        self.process_event(session, &frame)?;
        if matches!(ty, "agent_end" | "session_settled" | "turn_end") {
            let app = self.clone();
            let id = session.to_owned();
            tokio::spawn(async move {
                if let Ok(state) = app.native(&id, json!({"type":"get_state"})).await {
                    let _ = app.apply_state(&id, &state, false);
                }
            });
        }
        Ok(())
    }
    fn process_event(&self, id: &str, event: &Value) -> Result<()> {
        let ty = event["type"].as_str().unwrap_or_default();
        if matches!(ty, "notification" | "omputer_command_error") {
            let mut notification = event.clone();
            if ty == "omputer_command_error" {
                notification["level"] = json!("error");
                notification["message"] = event["error"].clone();
                let mut session = self.store.get("session", id)?;
                session["turnError"] = event["error"].clone();
                session["workState"] = json!(work_state(&session, false));
                self.store
                    .put("session", id, &session, Some("session.updated"))?;
            }
            self.omp_notification(id, &notification)?;
            return Ok(());
        }
        if matches!(
            ty,
            "message_start" | "message_update" | "message_end" | "agent_start" | "turn_start"
        ) {
            *self.revisions.lock().entry(id.to_owned()).or_default() += 1;
        }
        if matches!(ty, "message_start" | "message_update" | "message_end") {
            self.upsert_message(id, &event["message"], event["messageId"].as_str())?;
            self.record_activity(id, &event["message"], ty == "message_end")?;
        }
        let mut session = self.store.get("session", id)?;
        let mut changed = false;
        match ty {
            "agent_start" | "turn_start" => {
                session["status"] = json!("running");
                session["turnError"] = Value::Null;
                session["isSettled"] = json!(false);
                changed = true;
            }
            "agent_end" => {
                if let Some(messages) = event["messages"].as_array() {
                    for message in messages {
                        self.record_activity(id, message, true)?;
                    }
                }
                session = self.store.get("session", id)?;
                session["status"] = json!("waiting");
                session["isSettled"] = json!(false);
                changed = true;
                let error = event["messages"].as_array().and_then(|messages| {
                    messages
                        .iter()
                        .rev()
                        .find(|m| m["role"] == "assistant" && m["stopReason"] == "error")
                });
                if let Some(message) = error {
                    session["turnError"] = json!(
                        message["errorMessage"]
                            .as_str()
                            .unwrap_or("OMP assistant turn failed")
                    );
                    session["status"] = json!("waiting");
                    self.notify(
                        id,
                        "error",
                        session["turnError"]
                            .as_str()
                            .unwrap_or("OMP assistant turn failed"),
                        None,
                    )?;
                } else if !session["turnError"].is_string() {
                    self.notify(id, "turn_done", "OMP turn ended", None)?;
                }
            }
            "session_settled" => {
                let pending = self
                    .store
                    .list("interaction")?
                    .iter()
                    .any(|i| i["sessionId"] == id && i["status"] == "pending");
                session["status"] = json!(if pending { "waiting" } else { "idle" });
                session["isSettled"] = json!(!pending);
                session["hasPendingAsyncWork"] = json!(false);
                changed = true;
            }
            "model_changed" => {
                if event["model"].is_object() {
                    session["model"] = public_model(&event["model"]);
                    changed = true;
                }
            }
            "thinking_level_changed" => {
                session["thinkingLevel"] = event["thinkingLevel"].clone();
                changed = true;
            }
            "todo_update" => {
                session["todos"] = event["phases"].clone();
                session["activityUpdatedAt"] = json!(now());
                changed = true;
            }
            "subagent_snapshot" => {
                session["subagents"] = event["subagents"].clone();
                changed = true;
            }
            "subagent_lifecycle" | "subagent_progress" => {
                let sub = event
                    .get("payload")
                    .or(event.get("subagent"))
                    .or(event.get("data"))
                    .unwrap_or(event);
                if let Some(subid) = sub["id"].as_str().or(sub["subagentId"].as_str()) {
                    let mut list = session["subagents"].as_array().cloned().unwrap_or_default();
                    if let Some(existing) = list.iter_mut().find(|a| a["id"] == subid) {
                        if let Some(obj) = sub.as_object() {
                            for (k, v) in obj {
                                existing[k] = v.clone();
                            }
                        }
                    } else {
                        let mut sub = sub.clone();
                        sub["id"] = json!(subid);
                        list.push(sub);
                    }
                    session["subagents"] = json!(list);
                    changed = true;
                }
            }
            "prompt_result" if event["status"] == "error" => {
                session["turnError"] = json!(
                    event["error"]["message"]
                        .as_str()
                        .or(event["error"].as_str())
                        .unwrap_or("OMP reported a prompt error")
                );
                session["status"] = json!("idle");
                changed = true;
                self.notify(
                    id,
                    "error",
                    session["turnError"].as_str().unwrap_or_default(),
                    None,
                )?;
            }
            "message_end"
                if event["message"]["role"] == "assistant"
                    && event["message"]["stopReason"] == "error" =>
            {
                session["turnError"] = json!(
                    event["message"]["errorMessage"]
                        .as_str()
                        .unwrap_or("OMP assistant turn failed")
                );
                session["status"] = json!("waiting");
                changed = true;
                self.notify(
                    id,
                    "error",
                    session["turnError"]
                        .as_str()
                        .unwrap_or("OMP assistant turn failed"),
                    None,
                )?;
            }
            "rpc_frame_error" => {
                session["lastError"] = json!(
                    "Native OMP frame exceeded its advertised transport limit; refresh when idle or inspect the session locally"
                );
                session["status"] = json!("failed");
                changed = true;
                self.notify(
                    id,
                    "error",
                    session["lastError"].as_str().unwrap_or_default(),
                    None,
                )?;
            }
            _ => {}
        }
        if changed {
            session["workState"] = json!(work_state(
                &session,
                self.store
                    .list("interaction")?
                    .iter()
                    .any(|i| i["sessionId"] == id && i["status"] == "pending")
            ));
            session["updatedAt"] = json!(now());
            self.store
                .put("session", id, &session, Some("session.updated"))?;
        }
        if !ty.is_empty()
            && !matches!(
                ty,
                "response" | "message_start" | "message_update" | "message_end"
            )
        {
            self.store.event(
                "session.event",
                Some(id),
                session["projectId"].as_str(),
                &public_event(event),
            )?;
        }
        Ok(())
    }
    fn interaction(&self, id: &str, request: &Value, native: bool) -> Result<()> {
        let session = self.store.get("session", id)?;
        let rid = required(request, "id")?;
        if let Ok(previous) = self.store.get("interaction", rid) {
            // Identity, provenance and deadline are immutable while a host still waits.
            if previous["sessionId"] != id
                || previous["responseTransport"] != if native { "rpc" } else { "bridge" }
                || (previous["status"] != "pending"
                    && previous["cancellationReason"] != "disconnect")
            {
                return Ok(());
            }
            self.store.reconcile_pending_replay(rid, id)?;
            let mut replay = previous;
            replay["status"] = json!("pending");
            replay.as_object_mut().unwrap().remove("cancellationReason");
            self.store
                .put("interaction", rid, &replay, Some("interaction.pending"))?;
            return Ok(());
        }
        let mut interaction = json!({"id":rid,"sessionId":id,"projectId":session["projectId"],"method":request["method"],"title":request["title"].as_str().unwrap_or("OMP question"),"createdAt":request["createdAt"].as_str().unwrap_or(&now()),"status":"pending"});
        interaction["responseTransport"] = json!(if native { "rpc" } else { "bridge" });
        interaction["supportsNotes"] = json!(!native);
        for key in ["message", "options", "questions", "prefill", "expiresAt"] {
            if let Some(value) = request.get(key) {
                interaction[key] = value.clone();
            }
        }
        if let Some(options) = interaction["options"].as_array() {
            interaction["options"] = json!(
                options
                    .iter()
                    .map(|o| if let Some(label) = o.as_str() {
                        json!({"label":label})
                    } else {
                        o.clone()
                    })
                    .collect::<Vec<_>>()
            );
        }
        if interaction["expiresAt"].is_null()
            && let Some(ms) = request["timeout"].as_i64()
        {
            interaction["expiresAt"] =
                json!((chrono::Utc::now() + chrono::Duration::milliseconds(ms)).to_rfc3339());
        }
        self.store.put(
            "interaction",
            rid,
            &interaction,
            Some("interaction.pending"),
        )?;
        let mut session = session;
        session["status"] = json!("waiting");
        self.store
            .put("session", id, &session, Some("session.updated"))?;
        self.notify(
            id,
            if interaction["method"] == "approval" {
                "approval"
            } else {
                "question"
            },
            interaction["title"].as_str().unwrap_or("OMP question"),
            Some(rid),
        )?;
        Ok(())
    }
    fn notify(
        &self,
        session: &str,
        kind: &str,
        title: &str,
        interaction: Option<&str>,
    ) -> Result<()> {
        self.store.event("notification",Some(session),None,&json!({"id":Uuid::new_v4(),"kind":kind,"title":title,"body":"","sessionId":session,"interactionId":interaction}))?;
        Ok(())
    }
    fn omp_notification(&self, session: &str, frame: &Value) -> Result<()> {
        let level = frame["notifyType"]
            .as_str()
            .or(frame["level"].as_str())
            .or(frame["kind"].as_str())
            .or(frame["notificationType"].as_str())
            .or(frame["type"].as_str())
            .unwrap_or("info");
        let kind = if level == "error" {
            "error"
        } else {
            "connection"
        };
        let message = frame["message"]
            .as_str()
            .or(frame["body"].as_str())
            .unwrap_or_default();
        let title = frame["title"].as_str().unwrap_or(if kind == "error" {
            "OMP error"
        } else {
            "OMP notification"
        });
        let native = frame["nativeSource"] == true;
        let key = crate::security::hash(&format!("{session}:{level}:{message}"));
        let mut notifications = self.notifications.lock();
        notifications.retain(|_, (_, at)| at.elapsed() < Duration::from_secs(2));
        if notifications
            .get(&key)
            .is_some_and(|(source, _)| *source != native)
        {
            notifications.remove(&key);
            return Ok(());
        }
        notifications.insert(key, (native, std::time::Instant::now()));
        drop(notifications);
        self.store.event("notification",Some(session),None,&json!({"id":Uuid::new_v4(),"kind":kind,"title":title,"body":message,"sessionId":session}))?;
        Ok(())
    }
    async fn refresh_inactive_sessions(&self) -> Result<()> {
        let _guard = self.starting.lock().await;
        if self.update_pending.load(Ordering::SeqCst) {
            return Ok(());
        }
        for mut session in self.store.list("session")? {
            if session["transport"] == "archive"
                || !matches!(
                    session["status"].as_str(),
                    Some("closed" | "failed" | "disconnected")
                )
                || self
                    .links
                    .lock()
                    .get(session["id"].as_str().unwrap_or_default())
                    .is_some_and(|link| link.rpc.is_some() || link.bridge.is_some())
            {
                continue;
            }
            let previous = session["capabilities"].clone();
            self.set_inactive_capabilities(&mut session);
            if previous != session["capabilities"] {
                self.store.put(
                    "session",
                    required(&session, "id")?,
                    &session,
                    Some("session.updated"),
                )?;
            }
        }
        Ok(())
    }
    pub async fn ipc(self: Arc<Self>, listener: UnixListener) {
        let mut maintenance = tokio::time::interval(Duration::from_secs(15));
        maintenance.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            let accepted = tokio::select! {
                accepted = listener.accept() => accepted,
                _ = maintenance.tick() => {
                    if self.refresh_inactive_sessions().await.is_err() {
                        eprintln!("Cannot refresh inactive OMP session ownership");
                    }
                    continue;
                }
            };
            match accepted {
                Ok((stream, _)) => {
                    let app = self.clone();
                    tokio::spawn(async move {
                        if let Err(e) = app.bridge_connection(stream).await {
                            eprintln!("Local bridge connection closed: {e}");
                        }
                    });
                }
                Err(e) => {
                    eprintln!("Local bridge accept failed: {e}");
                    break;
                }
            }
        }
    }
    async fn bridge_connection(self: Arc<Self>, stream: UnixStream) -> Result<()> {
        let (read, write) = stream.into_split();
        let mut reader = BufReader::new(read);
        let first = tokio::time::timeout(
            Duration::from_secs(10),
            rpc_transport::line(&mut reader, 1024 * 1024),
        )
        .await??
        .context("Bridge closed before registration")?;
        let registration: Value = serde_json::from_str(&first)?;
        let token = std::fs::read_to_string(self.config.state_dir.join("bridge.token"))?;
        if registration["type"] != "register"
            || registration["token"].as_str() != Some(token.trim())
        {
            bail!("Invalid local bridge registration credential");
        }
        let registration_guard = self.starting.lock().await;
        if self.update_pending.load(Ordering::SeqCst) {
            return Err(command_error(
                "update_pending",
                "Local update is prepared; bridge will reconnect after it finishes",
            ));
        }
        let raw = &registration["session"];
        let managed = registration["managed"] == true;
        let mut id = if managed {
            registration["managedSessionId"]
                .as_str()
                .or(raw["managedSessionId"].as_str())
                .or(raw["id"].as_str())
                .context("Managed bridge requires managedSessionId")?
        } else {
            required(raw, "id")?
        }
        .to_owned();
        let root = PathBuf::from(required(raw, "cwd")?).canonicalize()?;
        let source = raw["sessionFile"]
            .as_str()
            .and_then(|file| Path::new(file).canonicalize().ok());
        if let Some(file) = &source {
            let (header, _) = archive::load(file)?;
            if header["id"] != raw["journalId"].as_str().unwrap_or(&id)
                || Path::new(required(&header, "cwd")?).canonicalize()? != root
            {
                bail!("Bridge session source identity or root does not match its runtime");
            }
            if !managed {
                for saved in self.store.list("session")? {
                    if saved["sessionFile"]
                        .as_str()
                        .and_then(|path| Path::new(path).canonicalize().ok())
                        .as_ref()
                        == Some(file)
                    {
                        id = required(&saved, "id")?.to_owned();
                        break;
                    }
                }
            }
        }
        if self
            .links
            .lock()
            .get(&id)
            .is_some_and(|link| link.bridge.is_some())
        {
            bail!("Session already has a connected bridge; refusing duplicate initialization");
        }
        let project = if managed {
            let s = self
                .store
                .get("session", &id)
                .context("Managed bridge has no daemon-owned RPC session")?;
            if !self.managed_children.lock().contains(&id)
                || s["transport"] != "rpc"
                || s["cwd"].as_str() != root.to_str()
            {
                bail!("Managed bridge is not owned by the matching live RPC process");
            }
            self.store.get(
                "project",
                s["projectId"].as_str().context("Session has no project")?,
            )?
        } else {
            self.store.register_project(&root, None)?
        };
        if !managed {
            if self.managed_children.lock().contains(&id) {
                bail!("Session still has an owned managed process; refusing a second writer");
            }
            if self
                .links
                .lock()
                .get(&id)
                .is_some_and(|l| l.bridge.is_some() || l.rpc.is_some())
            {
                bail!("Session already has a live runtime; refusing ambiguous registration");
            }
            let mut session=self.store.get("session",&id).unwrap_or_else(|_|json!({"id":id,"projectId":project["id"],"name":raw["name"].as_str().unwrap_or("OMP"),"cwd":root,"todos":[],"subagents":[],"activityUpdatedAt":now()}));
            if session["projectId"] != project["id"] || session["cwd"].as_str() != root.to_str() {
                bail!("Bridge session id belongs to another project");
            }
            session["transport"] = json!("bridge");
            session["status"] = json!("idle");
            session["updatedAt"] = json!(now());
            session["capabilities"] = json!([]);
            self.store
                .put("session", &id, &session, Some("session.updated"))?;
        }
        let (tx, rx) = mpsc::channel(256);
        let generation = Uuid::new_v4().to_string();
        {
            let mut links = self.links.lock();
            let link = links.entry(id.clone()).or_default();
            link.bridge = Some(tx.clone());
            link.bridge_generation = Some(generation.clone());
        }
        drop(registration_guard);
        let (close_tx, close_rx) = oneshot::channel();
        let (writer_failed_tx, mut writer_failed_rx) = oneshot::channel();
        let app = self.clone();
        let sid = id.clone();
        let writer_generation = generation.clone();
        tokio::spawn(async move {
            tokio::select! {_ = write_frames(write,rx)=>{let _=writer_failed_tx.send(());},_ = close_rx=>{}}
            if app.links.lock().get(&sid).is_some_and(|link| {
                link.bridge_generation.as_deref() == Some(writer_generation.as_str())
            }) {
                app.fail_pending(&sid, true);
            }
        });
        let result: Result<()> = async {
            tx.send(json!({"type":"registered","sessionId":id,"projectId":project["id"],"memoryRevision":project["memoryRevision"].as_u64().unwrap_or(0),"bindingRevision":generation}))
                .await?;
            self.apply_state(&id, raw, true)?;
            loop {
                let next = tokio::select! {
                    line = rpc_transport::line(&mut reader, rpc_transport::LOGICAL_BYTES) => line?,
                    _ = &mut writer_failed_rx => bail!("Bridge command writer disconnected"),
                };
                let Some(line) = next else {
                    break;
                };
                let frame: Value = serde_json::from_str(&line)?;
                if frame
                    .get("sessionId")
                    .is_some_and(|sid| sid.as_str() != Some(id.as_str()))
                {
                    continue;
                }
                self.frame(&id, frame, true).await?;
            }
            Ok(())
        }
        .await;
        let _ = close_tx.send(());
        let _cleanup_guard = self.starting.lock().await;
        let disconnected = {
            let mut links = self.links.lock();
            if let Some(link) = links.get_mut(&id) {
                if link.bridge_generation.as_deref() == Some(&generation) {
                    link.bridge = None;
                    link.bridge_generation = None;
                    true
                } else {
                    false
                }
            } else {
                false
            }
        };
        if disconnected {
            self.fail_pending(&id, true);
            self.cancel_transport_interactions(&id, false)?;
            let mut session = self.store.get("session", &id)?;
            session["writerConnected"] = json!(
                self.links
                    .lock()
                    .get(&id)
                    .is_some_and(|link| link.rpc.is_some())
            );
            session["bindingRevision"] = Value::Null;
            session["workState"] = json!(work_state(&session, false));
            if !managed {
                session["status"] = json!("disconnected");
                self.set_inactive_capabilities(&mut session);
            } else if self
                .links
                .lock()
                .get(&id)
                .is_some_and(|link| link.rpc.is_some())
            {
                session["capabilities"] = json!(rpc_capabilities());
            } else {
                self.set_inactive_capabilities(&mut session);
            }
            session["updatedAt"] = json!(now());
            self.store
                .put("session", &id, &session, Some("session.updated"))?;
        }
        result
    }
}
async fn write_frames<W: tokio::io::AsyncWrite + Unpin>(
    mut writer: W,
    mut rx: mpsc::Receiver<Value>,
) {
    while let Some(frame) = rx.recv().await {
        let mut bytes = frame.to_string().into_bytes();
        bytes.push(b'\n');
        if writer.write_all(&bytes).await.is_err() {
            break;
        }
        if writer.flush().await.is_err() {
            break;
        }
    }
}
fn migrate_identity(session: &mut Value) {
    if !session["journalId"].is_string()
        && let Some(legacy) = session["runtimeSessionId"].as_str().map(str::to_owned)
    {
        let header = session["sessionFile"]
            .as_str()
            .and_then(|file| archive::load(Path::new(file)).ok())
            .map(|(header, _)| header);
        let journal = header
            .as_ref()
            .filter(|header| header["cwd"] == session["cwd"])
            .and_then(|header| header["id"].as_str());
        if let Some(journal) = journal {
            if journal != legacy {
                session["providerSessionId"] = json!(legacy);
            }
            session["journalId"] = json!(journal);
        } else {
            session["journalId"] = json!(legacy);
        }
    }
    session.as_object_mut().unwrap().remove("runtimeSessionId");
}
fn validate_control_identity(session: &Value, payload: &Value) -> Result<()> {
    if !session["journalId"].is_string()
        || !session["bindingRevision"].is_string()
        || payload["expectedJournalId"] != session["journalId"]
        || payload["expectedBindingRevision"] != session["bindingRevision"]
    {
        return Err(command_error(
            "stale_identity",
            "Session identity changed; refresh controls before executing",
        ));
    }
    Ok(())
}
fn session_idle(session: &Value) -> bool {
    session["isSettled"] == true
        && session["hasPendingAsyncWork"] != true
        && session["isStreaming"] != true
        && session["isCompacting"] != true
        && session["status"] == "idle"
        && session["queuedMessages"]
            .as_array()
            .is_none_or(Vec::is_empty)
}
fn work_state(session: &Value, pending: bool) -> &'static str {
    if session["writerConnected"] != true {
        "disconnected"
    } else if pending {
        "human_wait"
    } else if session["isStreaming"] == true
        || session["isCompacting"] == true
        || session["status"] == "running"
    {
        "running"
    } else if session["queuedMessages"]
        .as_array()
        .is_some_and(|q| !q.is_empty())
    {
        "queued"
    } else if session["hasPendingAsyncWork"] == true || session["isSettled"] == false {
        "background"
    } else if session["turnError"].is_string() {
        "turn_error"
    } else {
        "settled"
    }
}
fn required<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .with_context(|| format!("{key} must be a nonempty string"))
}
pub fn public_model(model: &Value) -> Value {
    json!({"provider":model["provider"],"id":model["id"],"name":model["name"].as_str().or(model["id"].as_str()).unwrap_or_default()})
}
pub fn message_id(session: &str, message: &Value) -> String {
    if let Some(id) = message["_entryId"].as_str().filter(|id| !id.is_empty()) {
        return id.to_owned();
    }
    crate::security::hash(&format!(
        "{session}:{}:{}:{}",
        message["role"], message["timestamp"], message["toolCallId"]
    ))
}
fn rpc_capabilities() -> Vec<&'static str> {
    vec![
        "session.prompt",
        "session.steer",
        "session.follow_up",
        "session.abort",
        "session.model",
        "session.thinking",
        "session.compact",
        "session.rename",
        "session.refresh",
        "session.bash",
    ]
}
pub(crate) fn public_event(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .filter(|(k, _)| {
                    !matches!(
                        k.as_str(),
                        "systemPrompt"
                            | "apiKey"
                            | "headers"
                            | "accessToken"
                            | "refreshToken"
                            | "providerPayload"
                            | "dumpTools"
                            | "baseUrl"
                            | "auth"
                            | "credentials"
                    )
                })
                .map(|(k, v)| {
                    (
                        k.clone(),
                        if matches!(k.as_str(), "model" | "current" | "resolvedModel")
                            && v.is_object()
                        {
                            public_model(v)
                        } else if k == "models" && v.is_array() {
                            json!(
                                v.as_array()
                                    .unwrap()
                                    .iter()
                                    .map(public_model)
                                    .collect::<Vec<_>>()
                            )
                        } else {
                            public_event(v)
                        },
                    )
                })
                .collect(),
        ),
        Value::Array(a) => json!(a.iter().map(public_event).collect::<Vec<_>>()),
        _ => value.clone(),
    }
}
fn validate_answer(interaction: &Value, payload: &Value) -> Result<()> {
    if payload["cancelled"] == true {
        return Ok(());
    }
    match interaction["method"].as_str().unwrap_or_default() {
        "select" => {
            let value = required(payload, "value")?;
            if !interaction["options"]
                .as_array()
                .is_some_and(|a| a.iter().any(|o| o["label"] == value))
            {
                bail!("Selected option is not part of this request");
            }
        }
        "confirm" | "approval" => {
            if !payload["confirmed"].is_boolean() {
                bail!("confirmed must be a boolean");
            }
        }
        "input" | "editor" => {
            if !payload["value"].is_string() {
                bail!("value must be a string");
            }
        }
        "ask" => validate_ask(interaction, payload)?,
        _ => bail!("Unsupported interaction method"),
    }
    Ok(())
}
fn runtime_status(state: &Value, pending: bool) -> &'static str {
    if state["isStreaming"] == true || state["isCompacting"] == true {
        "running"
    } else if pending || state["hasPendingAsyncWork"] == true || state["isSettled"] == false {
        "waiting"
    } else {
        "idle"
    }
}
fn message_time(message: &Value) -> Value {
    message["timestamp"]
        .as_i64()
        .and_then(chrono::DateTime::from_timestamp_millis)
        .map(|t| json!(t.to_rfc3339()))
        .or_else(|| message["timestamp"].as_str().map(|s| json!(s)))
        .unwrap_or_else(|| json!(now()))
}
fn normal_user(message: &Value) -> bool {
    message["role"] == "user" && message["synthetic"] != true && message["attribution"] != "agent"
}
fn final_assistant(message: &Value) -> bool {
    message["role"] == "assistant"
        && message["stopReason"] == "stop"
        && !archive::assistant_text(message).is_empty()
}
fn validate_ask(interaction: &Value, payload: &Value) -> Result<()> {
    let invalid = |message: &str| command_error("invalid_answer", message);
    let questions = interaction["questions"]
        .as_array()
        .ok_or_else(|| invalid("Host ask questions are missing"))?;
    let answer = &payload["answer"];
    let results = answer["results"]
        .as_array()
        .ok_or_else(|| invalid("Ask requires one submitted result per question"))?;
    if answer["kind"] != "submit" || results.len() != questions.len() {
        return Err(invalid("Ask requires one submitted result per question"));
    }
    for (question, result) in questions.iter().zip(results) {
        if !result.is_object() || result["id"] != question["id"] {
            return Err(invalid("Question identity mismatch"));
        }
        let options = question["options"]
            .as_array()
            .ok_or_else(|| invalid("Host ask options are missing"))?;
        let selected = result["selectedOptions"]
            .as_array()
            .ok_or_else(|| invalid("Selected options must be an array"))?;
        let mut unique = std::collections::HashSet::new();
        for option in selected {
            let label = option
                .as_str()
                .ok_or_else(|| invalid("Selected option must be text"))?;
            if !unique.insert(label) || !options.iter().any(|o| o["label"] == label) {
                return Err(invalid("Selected option must be a unique offered answer"));
            }
        }
        for key in ["customInput", "note"] {
            if result.get(key).is_some_and(|v| !v.is_string()) {
                return Err(invalid("Custom answer and note must be text"));
            }
        }
        if (interaction["supportsNotes"] == false || interaction["responseTransport"] == "rpc")
            && result["note"]
                .as_str()
                .is_some_and(|note| !note.trim().is_empty())
        {
            return Err(invalid(
                "This native OMP question cannot preserve notes; remove the note before submitting",
            ));
        }
        let custom = result["customInput"]
            .as_str()
            .is_some_and(|s| !s.trim().is_empty());
        if question["multi"] != true && (selected.len() > 1 || (!selected.is_empty() && custom)) {
            return Err(invalid("Question is single-select"));
        }
        if question["multi"] != true && selected.is_empty() && !custom {
            return Err(invalid("Choose an option or enter a custom answer"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn app() -> Arc<App> {
        let store = Arc::new(Store::open(Path::new(":memory:"), "test".into()).unwrap());
        store.put("project","p",&json!({"id":"p","path":"/project","goal":"manual goal","summary":"manual summary","nextStep":"manual next","decisions":["manual decision"],"updatedAt":"2099-01-01T00:00:00Z"}),None).unwrap();
        store.put("session","s",&json!({"id":"s","projectId":"p","cwd":"/project","transport":"bridge","status":"idle","todos":[],"updatedAt":"2026-01-01T00:00:00Z","activityUpdatedAt":"2026-01-01T00:00:00Z"}),None).unwrap();
        App::new(
            store,
            RuntimeConfig {
                state_dir: PathBuf::new(),
                omp: PathBuf::new(),
                bridge: PathBuf::new(),
            },
        )
    }
    #[test]
    fn canonical_ids_preserve_same_millisecond_repeats_and_stream_revisions_without_reset() {
        let app = app();
        let user = json!({"role":"user","timestamp":1792329478325i64,"content":[{"type":"text","text":"identical queued request"}]});
        for id in ["67072843", "0f87e894"] {
            app.process_event(
                "s",
                &json!({"type":"message_start","messageId":id,"message":user}),
            )
            .unwrap();
            app.process_event(
                "s",
                &json!({"type":"message_end","messageId":id,"message":user}),
            )
            .unwrap();
        }
        let mut assistant = json!({"role":"assistant","timestamp":1792329478325i64,"content":[]});
        app.process_event(
            "s",
            &json!({"type":"message_start","messageId":"stream-entry","message":assistant}),
        )
        .unwrap();
        assistant["content"] = json!([{"type":"text","text":"streamed"}]);
        app.process_event(
            "s",
            &json!({"type":"message_update","messageId":"stream-entry","message":assistant}),
        )
        .unwrap();
        assistant["stopReason"] = json!("stop");
        app.process_event(
            "s",
            &json!({"type":"message_end","messageId":"stream-entry","message":assistant}),
        )
        .unwrap();
        app.process_event(
            "s",
            &json!({"type":"agent_end","messages":[user,user,assistant]}),
        )
        .unwrap();
        let before = app.store.messages("s", i64::MAX, 100).unwrap();
        assert_eq!(before["messages"].as_array().unwrap().len(), 3);
        let pages = [
            ("67072843", &user),
            ("0f87e894", &user),
            ("stream-entry", &assistant),
        ]
        .map(|(id, message)| {
            let mut projected = message.clone();
            projected["_entryId"] = json!(id);
            let mid = message_id("s", &projected);
            archive::message_view(&projected, &mid, &message_time(&projected))
        });
        let sequence = app.store.snapshot().unwrap()["sequence"].as_i64().unwrap();
        app.store.replace_messages("s", &pages).unwrap();
        app.store.replace_messages("s", &pages).unwrap();
        assert_eq!(app.store.messages("s", i64::MAX, 100).unwrap(), before);
        assert!(
            !app.store
                .journal(sequence, 100)
                .unwrap()
                .iter()
                .any(|event| event["type"] == "session.event"
                    && event["data"]["type"] == "transcript_reset")
        );
        let restarted = self::app();
        restarted.store.replace_messages("s", &pages).unwrap();
        let restored = restarted.store.messages("s", i64::MAX, 100).unwrap();
        assert_eq!(
            restored["messages"]
                .as_array()
                .unwrap()
                .iter()
                .map(|message| message["id"].clone())
                .collect::<Vec<_>>(),
            before["messages"]
                .as_array()
                .unwrap()
                .iter()
                .map(|message| message["id"].clone())
                .collect::<Vec<_>>()
        );
        let mut grown = pages.to_vec();
        grown.push(archive::message_view(
            &user,
            "next-entry",
            &message_time(&user),
        ));
        app.store.replace_messages("s", &grown).unwrap();
        let expanded = app.store.messages("s", i64::MAX, 100).unwrap();
        assert_eq!(expanded["messages"].as_array().unwrap().len(), 4);
        assert_eq!(
            &expanded["messages"].as_array().unwrap()[..3],
            before["messages"].as_array().unwrap().as_slice()
        );
        assert!(
            !app.store
                .journal(sequence, 100)
                .unwrap()
                .iter()
                .any(|event| event["type"] == "session.event"
                    && event["data"]["type"] == "transcript_reset")
        );
    }
    fn ask() -> Value {
        json!({"id":"q","method":"ask","title":"Choose","questions":[{"id":"one","question":"First?","options":[{"label":"A"},{"label":"B"}],"multi":false}]})
    }
    fn submitted() -> Value {
        json!({"interactionId":"q","answer":{"kind":"submit","results":[{"id":"one","selectedOptions":["A"]}]}})
    }
    #[tokio::test]
    async fn malformed_ask_does_not_claim_or_cancel_and_correct_answer_succeeds() {
        let app = app();
        app.interaction("s", &ask(), false).unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().bridge = Some(tx);
        for answer in [
            json!({"kind":"submit","results":[]}),
            json!({"kind":"submit","results":[{"id":"wrong","selectedOptions":["A"]}]}),
            json!({"kind":"submit","results":[{"id":"one","selectedOptions":["A","B"]}]}),
            json!({"kind":"submit","results":[{"id":"one","selectedOptions":["unoffered"]}]}),
        ] {
            let request = json!({"id":Uuid::new_v4().to_string(),"action":"interaction.respond","payload":{"interactionId":"q","answer":answer}});
            assert_eq!(
                error_code(&app.command(&request).await.unwrap_err()),
                "invalid_answer"
            );
            assert_eq!(
                app.store.get("interaction", "q").unwrap()["status"],
                "pending"
            );
        }
        let worker = app.clone();
        let response = tokio::spawn(async move {
            let frame = rx.recv().await.unwrap();
            worker.frame("s",json!({"type":"response","id":frame["id"],"success":true,"data":{"accepted":true}}),true).await.unwrap();
        });
        let result=app.command(&json!({"id":Uuid::new_v4().to_string(),"action":"interaction.respond","payload":submitted()})).await.unwrap();
        assert_eq!(result["accepted"], true);
        response.await.unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "resolved"
        );
    }
    #[tokio::test]
    async fn host_validation_releases_claim_and_desktop_resolution_survives_rejection() {
        let app = app();
        app.interaction("s", &ask(), false).unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().bridge = Some(tx);
        let worker = app.clone();
        let responder = tokio::spawn(async move {
            for desktop in [false, true] {
                let frame = rx.recv().await.unwrap();
                if desktop {
                    worker.store.end_interaction("q", "resolved").unwrap();
                }
                worker.frame("s",json!({"type":"response","id":frame["id"],"success":false,"error":{"code":"invalid_answer","message":"host rejected"}}),true).await.unwrap();
            }
        });
        for desktop in [false, true] {
            assert_eq!(error_code(&app.command(&json!({"id":Uuid::new_v4().to_string(),"action":"interaction.respond","payload":submitted()})).await.unwrap_err()),"invalid_answer");
            assert_eq!(
                app.store.get("interaction", "q").unwrap()["status"],
                if desktop { "resolved" } else { "pending" }
            );
        }
        responder.await.unwrap();
    }
    #[tokio::test]
    async fn disconnect_wakes_only_own_transport_commands() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().bridge = Some(tx);
        let worker = app.clone();
        let call = tokio::spawn(async move {
            worker
                .bridge_command("s", "session.rename", json!({"name":"name"}))
                .await
        });
        rx.recv().await.unwrap();
        app.fail_pending("other", true);
        assert!(!call.is_finished());
        app.fail_pending("s", false);
        assert!(!call.is_finished());
        app.fail_pending("s", true);
        let result = tokio::time::timeout(Duration::from_secs(1), call)
            .await
            .unwrap()
            .unwrap()
            .unwrap_err();
        assert_eq!(error_code(&result), "outcome_unknown");
    }
    #[test]
    fn disconnect_pending_replay_clears_abandoned_claim_only() {
        let app = app();
        app.interaction("s", &ask(), false).unwrap();
        app.store.claim_interaction("q", "old").unwrap();
        app.store.cancel_session_interactions("s").unwrap();
        app.interaction("s", &ask(), false).unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "pending"
        );
        app.store.claim_interaction("q", "new").unwrap();
        app.store.end_interaction("q", "resolved").unwrap();
        app.interaction("s", &ask(), false).unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "resolved"
        );
    }
    #[test]
    fn restart_recovers_valid_closed_failed_and_disconnected_sources_only() {
        let app = app();
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let source = root.join("saved.jsonl");
        let native_id = Uuid::new_v4().to_string();
        std::fs::write(
            &source,
            format!("{}\n", json!({"type":"session","id":native_id,"cwd":root})),
        )
        .unwrap();
        app.store
            .put("project", "p", &json!({"id":"p","path":root}), None)
            .unwrap();
        for status in ["closed", "failed", "disconnected", "running"] {
            app.store.put("session", "s", &json!({"id":"s","runtimeSessionId":native_id,"projectId":"p","cwd":root,"transport":"rpc","status":status,"sessionFile":source,"capabilities":rpc_capabilities(),"updatedAt":now()}), None).unwrap();
            app.initialize_disconnected().unwrap();
            let recovered = app.store.get("session", "s").unwrap();
            assert_eq!(
                recovered["capabilities"],
                json!(["session.resume"]),
                "{status}"
            );
            assert_eq!(
                recovered["status"],
                if status == "running" {
                    "disconnected"
                } else {
                    status
                }
            );
        }
        let mut changed = app.store.get("session", "s").unwrap();
        changed["journalId"] = json!("another-native-session");
        app.store.put("session", "s", &changed, None).unwrap();
        app.initialize_disconnected().unwrap();
        assert_eq!(
            app.store.get("session", "s").unwrap()["capabilities"],
            json!([])
        );
        changed["journalId"] = json!(native_id);
        std::fs::write(&source, "not a session\n").unwrap();
        app.store.put("session", "s", &changed, None).unwrap();
        app.initialize_disconnected().unwrap();
        assert_eq!(
            app.store.get("session", "s").unwrap()["capabilities"],
            json!([])
        );
    }
    #[tokio::test]
    async fn inactive_owned_process_recovers_after_its_actual_exit_without_archive_scan() {
        let app = app();
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let source = root.join("managed.jsonl");
        let native_id = Uuid::new_v4().to_string();
        std::fs::write(
            &source,
            format!("{}\n", json!({"type":"session","id":native_id,"cwd":root})),
        )
        .unwrap();
        app.store
            .put("project", "p", &json!({"id":"p","path":root}), None)
            .unwrap();
        app.store.put("session", "s", &json!({"id":"s","runtimeSessionId":native_id,"projectId":"p","cwd":root,"transport":"rpc","status":"failed","sessionFile":source,"capabilities":[],"updatedAt":now()}), None).unwrap();
        app.managed_children.lock().insert("s".into());
        app.refresh_inactive_sessions().await.unwrap();
        assert_eq!(
            app.store.get("session", "s").unwrap()["capabilities"],
            json!([])
        );
        app.managed_children.lock().remove("s");
        app.refresh_inactive_sessions().await.unwrap();
        assert_eq!(
            app.store.get("session", "s").unwrap()["capabilities"],
            json!(["session.resume"])
        );
    }
    #[tokio::test]
    async fn update_reservation_waits_for_acknowledged_work_and_blocks_new_controls() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().bridge = Some(tx);
        let worker = app.clone();
        let command = tokio::spawn(async move {
            worker.command(&json!({"id":Uuid::new_v4().to_string(),"sessionId":"s","action":"session.rename","payload":{"name":"saved"}})).await
        });
        let request = rx.recv().await.unwrap();
        assert_eq!(
            error_code(&app.prepare_update().await.unwrap_err()),
            "session_busy"
        );
        app.frame(
            "s",
            json!({"type":"response","id":request["id"],"success":true,"data":{"name":"saved"}}),
            true,
        )
        .await
        .unwrap();
        command.await.unwrap().unwrap();
        app.managed_children.lock().insert("dead-link-child".into());
        assert_eq!(app.managed_rpc_sessions(), 1);
        assert_eq!(
            error_code(&app.prepare_update().await.unwrap_err()),
            "session_busy"
        );
        app.managed_children.lock().clear();
        app.links.lock().get_mut("s").unwrap().bridge = None;
        assert_eq!(app.prepare_update().await.unwrap()["prepared"], true);
        assert_eq!(
            error_code(
                &app.command(&json!({"action":"session.refresh","sessionId":"s","payload":{}}))
                    .await
                    .unwrap_err()
            ),
            "update_pending"
        );
        assert_eq!(app.cancel_update().await["prepared"], false);
    }
    #[tokio::test]
    async fn native_note_rejection_preserves_question_and_disconnect_is_transport_scoped() {
        let app = app();
        app.interaction("s", &ask(), true).unwrap();
        let mut bridge_ask = ask();
        bridge_ask["id"] = json!("bridge-question");
        app.interaction("s", &bridge_ask, false).unwrap();
        let (tx, _rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().rpc = Some(tx);
        let mut payload = submitted();
        payload["answer"]["results"][0]["note"] = json!("Never silently drop this context");
        assert_eq!(error_code(&app.command(&json!({"id":Uuid::new_v4().to_string(),"action":"interaction.respond","payload":payload})).await.unwrap_err()), "invalid_answer");
        app.store
            .claim_interaction("q", "after-validation")
            .unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "pending"
        );
        app.cancel_transport_interactions("s", false).unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "pending"
        );
        assert_eq!(
            app.store.get("interaction", "bridge-question").unwrap()["status"],
            "cancelled"
        );
        app.cancel_transport_interactions("s", true).unwrap();
        assert_eq!(
            app.store.get("interaction", "q").unwrap()["status"],
            "cancelled"
        );
    }
    #[test]
    fn replay_cannot_change_provenance_question_or_absolute_deadline() {
        let app = app();
        let mut original = ask();
        original["expiresAt"] = json!("2099-01-01T00:00:00Z");
        app.interaction("s", &original, false).unwrap();
        let mut replay = ask();
        replay["questions"][0]["options"] = json!([{"label":"replaced"}]);
        replay["expiresAt"] = json!("2199-01-01T00:00:00Z");
        app.interaction("s", &replay, true).unwrap();
        app.interaction("s", &replay, false).unwrap();
        let stored = app.store.get("interaction", "q").unwrap();
        assert_eq!(stored["responseTransport"], "bridge");
        assert_eq!(stored["questions"], original["questions"]);
        assert_eq!(stored["expiresAt"], original["expiresAt"]);
    }
    #[test]
    fn project_activity_ignores_deltas_local_commands_and_synthetic_prompts() {
        let app = app();
        for message in [
            json!({"role":"user","content":"real goal","timestamp":1000}),
            json!({"role":"user","content":"/model","timestamp":2000}),
            json!({"role":"user","content":"injected","synthetic":true,"timestamp":3000}),
            json!({"role":"user","content":"agent prompt","attribution":"agent","timestamp":4000}),
        ] {
            app.process_event("s", &json!({"type":"message_end","message":message}))
                .unwrap();
        }
        let partial = json!({"role":"assistant","content":[{"type":"text","text":"partial"}],"timestamp":5000,"stopReason":"stop"});
        app.process_event("s", &json!({"type":"message_update","message":partial}))
            .unwrap();
        assert!(app.store.get("session", "s").unwrap()["lastAssistantText"].is_null());
        let final_message = json!({"role":"assistant","content":[{"type":"text","text":"Final answer"}],"timestamp":6000,"stopReason":"stop"});
        app.process_event("s", &json!({"type":"message_end","message":final_message}))
            .unwrap();
        app.process_event("s",&json!({"type":"todo_update","phases":[{"tasks":[{"content":"pending first","status":"pending"},{"content":"active next","status":"in_progress"}]}]})).unwrap();
        let project = app.store.snapshot().unwrap()["projects"][0].clone();
        assert_eq!(project["activity"]["goal"], "real goal");
        assert_eq!(project["activity"]["lastAssistantText"], "Final answer");
        assert_eq!(project["activity"]["nextStep"], "active next");
        assert_eq!(project["goal"], "manual goal");
        assert_eq!(project["updatedAt"], "2099-01-01T00:00:00Z");
    }
    #[test]
    fn agent_end_is_not_settled_and_errors_notify() {
        let app = app();
        app.process_event("s", &json!({"type":"agent_end","messages":[]}))
            .unwrap();
        assert_eq!(app.store.get("session", "s").unwrap()["status"], "waiting");
        app.apply_state(
            "s",
            &json!({"isStreaming":false,"hasPendingAsyncWork":true,"isSettled":false}),
            false,
        )
        .unwrap();
        assert_eq!(app.store.get("session", "s").unwrap()["status"], "waiting");
        app.process_event("s",&json!({"type":"agent_end","messages":[{"role":"assistant","timestamp":1,"content":[],"stopReason":"error","errorMessage":"provider failed"}]})).unwrap();
        app.apply_state(
            "s",
            &json!({"isStreaming":false,"hasPendingAsyncWork":false,"isSettled":true}),
            false,
        )
        .unwrap();
        assert_eq!(app.store.get("session", "s").unwrap()["status"], "idle");
        assert_eq!(
            app.store.get("session", "s").unwrap()["turnError"],
            "provider failed"
        );
        assert!(
            app.store
                .journal(0, 1000)
                .unwrap()
                .iter()
                .any(|event| event["type"] == "notification" && event["data"]["kind"] == "error")
        );
    }
    #[test]
    fn bridge_notification_translates_error_level() {
        let app = app();
        app.process_event(
            "s",
            &json!({"type":"notification","message":"custom failure","level":"error"}),
        )
        .unwrap();
        let events = app.store.journal(0, 100).unwrap();
        assert!(events.iter().any(|event| event["type"] == "notification"
            && event["data"]["kind"] == "error"
            && event["data"]["body"] == "custom failure"));
    }
    #[test]
    fn fresh_provider_identity_does_not_replace_persisted_journal_or_disable_failed_turn() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().rpc = Some(tx);
        let mut session = app.store.get("session", "s").unwrap();
        session["runtimeSessionId"] = json!("journal-original");
        app.store.put("session", "s", &session, None).unwrap();
        app.apply_state("s",&json!({"sessionId":"provider-fresh","isStreaming":false,"isCompacting":false,"isSettled":true,"hasPendingAsyncWork":false}),false).unwrap();
        app.process_event("s",&json!({"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"offline","content":[],"timestamp":1}]})).unwrap();
        app.apply_state("s",&json!({"sessionId":"provider-another","isStreaming":false,"isCompacting":false,"isSettled":true,"hasPendingAsyncWork":false}),false).unwrap();
        let saved = app.store.get("session", "s").unwrap();
        assert_eq!(saved["journalId"], "journal-original");
        assert_eq!(saved["providerSessionId"], "provider-another");
        assert!(saved.get("runtimeSessionId").is_none());
        assert_eq!(saved["writerConnected"], true);
        assert_eq!(saved["status"], "idle");
        assert_eq!(saved["workState"], "turn_error");
        assert!(
            saved["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|cap| cap == "session.prompt")
        );
    }
    #[tokio::test]
    async fn acknowledged_branch_updates_same_visible_object_before_following_state_and_rejects_old_binding()
     {
        let app = app();
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let source = root.join("branch.jsonl");
        std::fs::write(
            &source,
            format!(
                "{}\n",
                json!({"type":"session","id":"journal-next","cwd":root})
            ),
        )
        .unwrap();
        let mut session = app.store.get("session", "s").unwrap();
        session["cwd"] = json!(root);
        session["journalId"] = json!("journal-original");
        session["bindingRevision"] = json!("binding-one");
        app.store.put("session", "s", &session, None).unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().insert(
            "s".into(),
            Links {
                bridge: Some(tx),
                bridge_generation: Some("binding-one".into()),
                ..Default::default()
            },
        );
        let worker = app.clone();
        let call = tokio::spawn(async move {
            worker.command(&json!({"id":"public-operation","sessionId":"s","action":"session.control","payload":{"control":"branch","arguments":{"entryId":"entry"},"expectedJournalId":"journal-original","expectedBindingRevision":"binding-one"}})).await
        });
        let request = rx.recv().await.unwrap();
        assert_eq!(request["operationId"], "public-operation");
        let state = json!({"journalId":"journal-next","providerSessionId":"provider-next","sessionFile":source,"cwd":root,"status":"idle","isSettled":true,"hasPendingAsyncWork":false});
        app.frame("s",json!({"type":"response","id":request["id"],"success":true,"data":{"branched":true,"_omputerState":state}}),true).await.unwrap();
        // This frame may arrive before the command future gets polled again.
        app.apply_state("s", &state, true).unwrap();
        assert_eq!(call.await.unwrap().unwrap()["branched"], true);
        let saved = app.store.get("session", "s").unwrap();
        assert_eq!(saved["journalId"], "journal-next");
        assert_eq!(saved["originalSource"]["journalId"], "journal-original");
        assert_eq!(app.store.list("session").unwrap().len(), 1);
        let error = app.command(&json!({"id":"stale","sessionId":"s","action":"session.control","payload":{"expectedJournalId":"journal-original","expectedBindingRevision":"binding-one"}})).await.unwrap_err();
        assert_eq!(error_code(&error), "stale_identity");
    }
    #[tokio::test]
    async fn idle_close_refuses_external_writer_before_signalling_any_managed_child() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        app.links
            .lock()
            .entry("terminal".into())
            .or_default()
            .bridge = Some(tx);
        app.managed_children.lock().insert("s".into());
        let (shutdown, mut signals) = mpsc::unbounded_channel();
        app.child_shutdown.lock().insert("s".into(), shutdown);
        assert_eq!(
            error_code(&app.close_idle_managed().await.unwrap_err()),
            "session_busy"
        );
        assert!(signals.try_recv().is_err());
        assert!(!app.update_pending.load(Ordering::SeqCst));
        assert_eq!(
            app.update_blockers().await.unwrap()["blockers"][0]["kind"],
            "external_writer"
        );
    }
    #[tokio::test]
    async fn replayed_output_is_durable_once_and_cross_session_output_never_acknowledges() {
        let app = app();
        let operation = Uuid::new_v4().to_string();
        app.store
            .begin_command(
                &operation,
                &json!({"id":operation,"sessionId":"s","action":"session.command","payload":{}}),
            )
            .unwrap();
        let (tx, mut rx) = mpsc::channel(8);
        app.links.lock().entry("s".into()).or_default().bridge = Some(tx);
        let frame = json!({"type":"operation_output","operationId":operation,"outputId":"output-1","kind":"command","text":"actual output"});
        app.frame("s", frame.clone(), true).await.unwrap();
        app.frame("s", frame.clone(), true).await.unwrap();
        assert_eq!(rx.recv().await.unwrap()["type"], "output_ack");
        assert_eq!(rx.recv().await.unwrap()["type"], "output_ack");
        assert_eq!(
            app.store.command_output_page(&operation, 0, 100).unwrap()["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(app.frame("other", frame, true).await.is_err());
        assert!(rx.try_recv().is_err());
    }
    #[test]
    fn identity_transition_rejects_wrong_header_without_mutating_original_binding() {
        let app = app();
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let file = root.join("source.jsonl");
        std::fs::write(
            &file,
            format!(
                "{}\n",
                json!({"type":"session","id":"header-real","cwd":root})
            ),
        )
        .unwrap();
        let mut saved = app.store.get("session", "s").unwrap();
        saved["journalId"] = json!("old");
        saved["bindingRevision"] = json!("binding");
        saved["cwd"] = json!(root);
        app.store.put("session", "s", &saved, None).unwrap();
        let error = app
            .apply_control_state(
                "s",
                &saved,
                &json!({"journalId":"header-forged","sessionFile":file,"cwd":root}),
            )
            .unwrap_err();
        assert_eq!(error_code(&error), "source_mismatch");
        assert_eq!(app.store.get("session", "s").unwrap(), saved);
    }
}
