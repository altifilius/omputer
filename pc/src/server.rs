use crate::runtime::App;
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{
        ConnectInfo, Extension, Path, Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, patch, post},
};
use futures_util::{FutureExt, Sink, SinkExt, Stream, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
}
impl ApiError {
    fn new(status: StatusCode, code: &'static str, message: impl ToString) -> Self {
        Self {
            status,
            code,
            message: message.to_string(),
        }
    }
}
impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> Self {
        if e.is::<crate::store::MemoryConflict>() {
            Self::new(StatusCode::CONFLICT, "memory_conflict", e)
        } else {
            Self::new(StatusCode::BAD_REQUEST, "request_rejected", e)
        }
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({"error":{"code":self.code,"message":self.message}})),
        )
            .into_response()
    }
}
pub fn router(app: Arc<App>) -> Router {
    let protected = Router::new()
        .route("/v1/snapshot", get(snapshot))
        .route("/v1/models", get(models))
        .route("/v1/diagnostics", get(diagnostics))
        .route("/v1/search", get(search))
        .route("/v1/sessions/{id}/export", get(export_session))
        .route("/v1/sessions/{id}/control", get(controls))
        .route("/v1/sessions/{id}/commands", get(session_commands))
        .route("/v1/sessions/{id}/operations", get(operations))
        .route("/v1/sessions/{id}/messages", get(messages))
        .route("/v1/projects/{id}/files", get(file))
        .route("/v1/projects/{id}/tree", get(project_tree))
        .route("/v1/projects/{id}/changes", get(project_changes))
        .route("/v1/projects/{id}/diff", get(project_diff))
        .route("/v1/projects/{id}/memory/history", get(memory_history))
        .route("/v1/projects/{id}", patch(project))
        .route("/v1/devices/{id}/revoke", post(revoke))
        .route("/v1/commands", post(command))
        .route("/v1/commands/{id}", get(operation))
        .route("/v1/commands/{id}/output", get(operation_output))
        .route("/v1/events", get(events))
        .route_layer(middleware::from_fn_with_state(app.clone(), authenticate));
    Router::new()
        .route("/health", get(health))
        .route(
            "/v1/pair",
            post(pair).layer(axum::extract::DefaultBodyLimit::max(2048)),
        )
        .route("/v1/identity", get(identity))
        .route(
            "/v1/pair/request",
            post(pair_request).layer(axum::extract::DefaultBodyLimit::max(2048)),
        )
        .route(
            "/v1/pair/reveal",
            post(pair_reveal).layer(axum::extract::DefaultBodyLimit::max(2048)),
        )
        .route(
            "/v1/pair/claim",
            post(pair_claim).layer(axum::extract::DefaultBodyLimit::max(2048)),
        )
        .merge(protected)
        .layer(axum::extract::DefaultBodyLimit::max(16 * 1024 * 1024))
        .with_state(app)
}
async fn health(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    let ready = app
        .local
        .get()
        .is_some_and(|local| local.ready.load(std::sync::atomic::Ordering::Acquire));
    if !ready {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "service_starting",
            "Local administration is not ready",
        ));
    }
    Ok(Json(json!({"name":"Omputer","protocol":1,"ready":true})))
}
async fn authenticate(
    State(app): State<Arc<App>>,
    mut request: Request<axum::body::Body>,
    next: Next,
) -> Result<Response, ApiError> {
    let token = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ApiError::new(
                StatusCode::UNAUTHORIZED,
                "unauthorized",
                "Authorization: Bearer device token is required",
            )
        })?;
    let device = app.store.authenticate(token)?.ok_or_else(|| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "device_revoked",
            "Device token is invalid or revoked",
        )
    })?;
    request.extensions_mut().insert(device);
    Ok(next.run(request).await)
}
fn local_state(app: &App) -> Result<&Arc<crate::discovery::LocalState>, ApiError> {
    app.local.get().ok_or_else(|| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "service_starting",
            "Local services are not initialized",
        )
    })
}
async fn identity(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    Ok(Json(local_state(&app)?.identity()))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairRequest {
    name: String,
    client_commitment: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairClaim {
    request_id: String,
    claim_secret: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PairReveal {
    request_id: String,
    claim_secret: String,
    client_secret: String,
}
fn pairing_error(error: crate::discovery::PairError) -> ApiError {
    let status = match error.code {
        "pairing_rate_limited" | "pairing_busy" => StatusCode::TOO_MANY_REQUESTS,
        "pairing_consumed" | "pairing_expired" => StatusCode::GONE,
        "pairing_denied" => StatusCode::FORBIDDEN,
        "pairing_commitment_mismatch" | "pairing_not_revealed" => StatusCode::CONFLICT,
        "pairing_storage_failed" => StatusCode::INTERNAL_SERVER_ERROR,
        "pairing_rejected" => StatusCode::UNAUTHORIZED,
        _ => StatusCode::BAD_REQUEST,
    };
    ApiError::new(status, error.code, error.message)
}
async fn pair_request(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    Json(body): Json<PairRequest>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        local_state(&app)?
            .request_pair(peer.ip(), &body.name, &body.client_commitment)
            .map_err(pairing_error)?,
    ))
}
async fn pair_reveal(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    Json(body): Json<PairReveal>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        local_state(&app)?
            .reveal_pair(
                peer.ip(),
                &body.request_id,
                &body.claim_secret,
                &body.client_secret,
            )
            .map_err(pairing_error)?,
    ))
}
async fn pair_claim(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    Json(body): Json<PairClaim>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        local_state(&app)?
            .claim_pair(&app.store, peer.ip(), &body.request_id, &body.claim_secret)
            .map_err(pairing_error)?,
    ))
}
#[derive(Deserialize)]
struct Pair {
    code: String,
    name: String,
}
async fn pair(
    State(app): State<Arc<App>>,
    Json(body): Json<Pair>,
) -> Result<Json<Value>, ApiError> {
    if body.name.trim().is_empty() || body.name.len() > 200 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_name",
            "Device name must contain 1–200 bytes",
        ));
    }
    if body.code.len() != 64 || !body.code.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "pairing_rejected",
            "Invalid local one-use pairing bundle",
        ));
    }
    Ok(Json(
        app.store
            .consume_pair(&body.code, body.name.trim())
            .map_err(|e| ApiError::new(StatusCode::UNAUTHORIZED, "pairing_rejected", e))?,
    ))
}
fn current_snapshot(app: &App) -> Result<Value> {
    let mut snapshot = app.store.snapshot()?;
    if let Some(local) = app.local.get() {
        snapshot["serverId"] = json!(local.server_id);
        snapshot["discovery"] = local.discovery.lock().clone();
    }
    Ok(snapshot)
}
async fn snapshot(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    app.store.expire_interactions()?;
    Ok(Json(current_snapshot(&app)?))
}
async fn models(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    Ok(Json(json!({"models":app.models().await?})))
}
#[derive(Deserialize)]
struct Page {
    before: Option<i64>,
    limit: Option<usize>,
}
async fn messages(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(page): Query<Page>,
) -> Result<Json<Value>, ApiError> {
    app.store.get("session", &id)?;
    Ok(Json(app.store.messages(
        &id,
        page.before.unwrap_or(i64::MAX),
        page.limit.unwrap_or(50).clamp(1, 200),
    )?))
}
#[derive(Deserialize)]
struct FileQuery {
    path: String,
}
async fn file(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(query): Query<FileQuery>,
) -> Result<Json<Value>, ApiError> {
    let project = app.store.get("project", &id)?;
    let root = std::path::Path::new(project["path"].as_str().context("Project root missing")?);
    let (text, truncated) = crate::project_files::file(root, &query.path)
        .map_err(|e| ApiError::new(StatusCode::FORBIDDEN, "file_rejected", e))?;
    Ok(Json(
        json!({"path":query.path,"text":text,"truncated":truncated}),
    ))
}
async fn diagnostics(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    Ok(Json(crate::backup::diagnosis(&app).await?))
}
async fn operation(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.command_status(&id).map_err(|error| {
        ApiError::new(StatusCode::NOT_FOUND, "operation_not_found", error)
    })?))
}
async fn operations(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(page): Query<Page>,
) -> Result<Json<Value>, ApiError> {
    app.store.get("session", &id)?;
    Ok(Json(app.store.list_operations(
        &id,
        page.before.unwrap_or(i64::MAX),
        page.limit.unwrap_or(50),
    )?))
}
#[derive(Deserialize)]
struct OutputPage {
    after: Option<i64>,
    limit: Option<usize>,
}
async fn operation_output(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(page): Query<OutputPage>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.command_output_page(
        &id,
        page.after.unwrap_or(0),
        page.limit.unwrap_or(50),
    )?))
}
async fn controls(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(mut args): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    let view = args.remove("view").unwrap_or_else(|| "state".into());
    control_query(&app, &id, &view, args).await
}
async fn session_commands(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(args): Query<std::collections::HashMap<String, String>>,
) -> Result<Json<Value>, ApiError> {
    control_query(&app, &id, "commands", args).await
}
async fn control_query(
    app: &Arc<App>,
    id: &str,
    view: &str,
    args: std::collections::HashMap<String, String>,
) -> Result<Json<Value>, ApiError> {
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
    ) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "invalid_control_view",
            "Unknown control view",
        ));
    }
    let mut values = serde_json::Map::new();
    for (key, value) in args {
        if key == "view" {
            continue;
        }
        if value.len() > 16 * 1024 {
            return Err(ApiError::new(
                StatusCode::BAD_REQUEST,
                "invalid_control_query",
                "Control query argument exceeds limit",
            ));
        }
        if key == "arguments" {
            let parsed: Value =
                serde_json::from_str(&value).context("arguments must be a JSON object")?;
            values.extend(
                parsed
                    .as_object()
                    .context("arguments must be an object")?
                    .clone(),
            );
        } else {
            values.insert(
                key,
                serde_json::from_str(&value).unwrap_or(Value::String(value)),
            );
        }
    }
    Ok(Json(app.controls(id, view, Value::Object(values)).await?))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchQuery {
    query: String,
    project_id: Option<String>,
    session_id: Option<String>,
    cursor: Option<i64>,
    limit: Option<usize>,
}
async fn search(
    State(app): State<Arc<App>>,
    Query(query): Query<SearchQuery>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.search(
        &query.query,
        query.project_id.as_deref(),
        query.session_id.as_deref(),
        query.cursor.unwrap_or(0),
        query.limit.unwrap_or(50),
    )?))
}
#[derive(Deserialize)]
struct ExportQuery {
    format: Option<String>,
}
async fn export_session(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(query): Query<ExportQuery>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.export_session(
        &id,
        query.format.as_deref().unwrap_or("markdown"),
    )?))
}
async fn memory_history(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(page): Query<Page>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.memory_history(
        &id,
        page.before.unwrap_or(i64::MAX),
        page.limit.unwrap_or(50),
    )?))
}
#[derive(Deserialize)]
struct TreeQuery {
    path: Option<String>,
    query: Option<String>,
    cursor: Option<usize>,
    limit: Option<usize>,
}
async fn project_tree(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(query): Query<TreeQuery>,
) -> Result<Json<Value>, ApiError> {
    let project = app.store.get("project", &id)?;
    let root = std::path::PathBuf::from(project["path"].as_str().context("Project root missing")?);
    let result = tokio::task::spawn_blocking(move || {
        crate::project_files::tree(
            &root,
            query.path.as_deref().unwrap_or(""),
            query.query.as_deref().unwrap_or(""),
            query.cursor.unwrap_or(0),
            query.limit.unwrap_or(100),
        )
    })
    .await
    .context("File browsing worker failed")??;
    Ok(Json(result))
}
async fn project_changes(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let project = app.store.get("project", &id)?;
    let root = std::path::Path::new(project["path"].as_str().context("Project root missing")?);
    Ok(Json(crate::project_files::changes(root).await?))
}
async fn project_diff(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Query(query): Query<FileQuery>,
) -> Result<Json<Value>, ApiError> {
    let project = app.store.get("project", &id)?;
    let root = std::path::Path::new(project["path"].as_str().context("Project root missing")?);
    Ok(Json(crate::project_files::diff(root, &query.path).await?))
}
async fn project(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(app.store.edit_memory(&id, &body)?))
}
async fn revoke(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    app.store.revoke(&id)?;
    Ok(Json(json!({"success":true})))
}
async fn command(
    State(app): State<Arc<App>>,
    Json(request): Json<Value>,
) -> Result<Response, ApiError> {
    let id = request["id"]
        .as_str()
        .context("Command id is required")?
        .to_owned();
    if let Some(result) = app.store.begin_command(&id, &request)? {
        return Ok(command_response(result));
    }
    // This task owns the command, never the lifetime of the HTTP connection.
    let executor = app.clone();
    let mut task = spawn_command(app.clone(), id.clone(), async move {
        executor.command(&request).await
    });
    match tokio::time::timeout(Duration::from_secs(10), &mut task).await {
        Ok(Ok(Ok(result))) => Ok(command_response(result)),
        Ok(Ok(Err(error))) => Err(error.into()),
        Ok(Err(error)) => {
            app.store
                .command_unknown(&id, "The command worker stopped before recording a result")?;
            Err(ApiError::new(
                StatusCode::CONFLICT,
                "outcome_unknown",
                error,
            ))
        }
        Err(_) => Ok(command_response(
            json!({"id":id,"success":true,"accepted":true,"status":"running"}),
        )),
    }
}
fn spawn_command<F>(app: Arc<App>, id: String, work: F) -> tokio::task::JoinHandle<Result<Value>>
where
    F: Future<Output = Result<Value>> + Send + 'static,
{
    tokio::spawn(async move {
        let outcome = std::panic::AssertUnwindSafe(work).catch_unwind().await;
        match outcome {
            Ok(outcome) => {
                let result = match outcome {
                    Ok(data) => json!({"id":id,"success":true,"status":"succeeded","data":data}),
                    Err(error) => {
                        json!({"id":id,"success":false,"status":"failed","error":{"code":crate::runtime::error_code(&error),"message":error.to_string()}})
                    }
                };
                app.store.finish_command(&id, &result)?;
                Ok(result)
            }
            Err(_) => {
                app.store.command_unknown(&id,"The command task stopped unexpectedly; inspect current state before taking another action")?;
                Ok(
                    json!({"id":id,"success":false,"status":"unknown","error":{"code":"outcome_unknown","message":"The command task stopped unexpectedly; it will never be replayed"}}),
                )
            }
        }
    })
}
fn command_response(result: Value) -> Response {
    let status = if result["status"] == "running" {
        StatusCode::ACCEPTED
    } else if result["success"] == true {
        StatusCode::OK
    } else {
        StatusCode::CONFLICT
    };
    (status, Json(result)).into_response()
}
#[derive(Deserialize)]
struct Cursor {
    after: Option<i64>,
}
async fn events(
    State(app): State<Arc<App>>,
    Query(cursor): Query<Cursor>,
    Extension(device): Extension<String>,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    Ok(ws
        .max_message_size(64 * 1024)
        .on_upgrade(move |socket| stream(app, socket, device, cursor.after.unwrap_or(0).max(0))))
}
async fn stream(app: Arc<App>, socket: WebSocket, device: String, cursor: i64) {
    let (writer, reader) = socket.split();
    stream_io(app, writer, reader, device, cursor).await;
}
async fn replay_events(app: Arc<App>, sender: tokio::sync::mpsc::Sender<Message>, mut cursor: i64) {
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut snapshot_sent = false;
    loop {
        tick.tick().await;
        let events = match app.store.journal(cursor, 256) {
            Ok(events) => events,
            Err(_) => return,
        };
        for event in events {
            let sequence = event["sequence"].as_i64().unwrap_or(cursor);
            if sender
                .send(Message::Text(event.to_string().into()))
                .await
                .is_err()
            {
                return;
            }
            cursor = sequence;
        }
        // Later mutations remain in SQLite; a backpressured writer never blocks
        // the independent revocation/liveness reader in stream_io.
        if !snapshot_sent {
            let snapshot = match current_snapshot(&app) {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            };
            let sequence = snapshot["sequence"].as_i64().unwrap_or(cursor);
            if cursor > sequence {
                cursor = 0;
            } else if sequence == cursor {
                let event = json!({"sequence":sequence,"type":"snapshot","data":snapshot,"createdAt":crate::store::now()});
                if sender
                    .send(Message::Text(event.to_string().into()))
                    .await
                    .is_err()
                {
                    return;
                }
                snapshot_sent = true;
            }
        }
    }
}
async fn write_stream<S>(
    mut writer: S,
    mut events: tokio::sync::mpsc::Receiver<Message>,
    mut control: tokio::sync::mpsc::Receiver<Message>,
) where
    S: Sink<Message> + Unpin,
{
    loop {
        let frame = tokio::select! {
            biased;
            frame = control.recv() => frame,
            frame = events.recv() => frame,
        };
        let Some(frame) = frame else { return };
        let closing = matches!(frame, Message::Close(_));
        if writer.send(frame).await.is_err() || closing {
            return;
        }
    }
}
async fn stream_io<S, R, E>(app: Arc<App>, writer: S, mut reader: R, device: String, cursor: i64)
where
    S: Sink<Message> + Unpin,
    R: Stream<Item = std::result::Result<Message, E>> + Unpin,
{
    // At most one queued data frame and one in-flight write. Control frames use
    // their own bounded lane, so a busy replay cannot starve ping/pong/close.
    let (events_tx, events_rx) = tokio::sync::mpsc::channel(1);
    let (control_tx, control_rx) = tokio::sync::mpsc::channel(4);
    let writer = write_stream(writer, events_rx, control_rx);
    let replay = replay_events(app.clone(), events_tx, cursor);
    tokio::pin!(writer, replay);
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut heartbeat = tokio::time::interval(Duration::from_secs(20));
    let mut last_pong = Instant::now();
    loop {
        tokio::select! {
            _ = &mut writer => break,
            _ = &mut replay => break,
            _ = tick.tick() => {
                if !app.store.device_active(&device) {
                    let _ = control_tx.try_send(Message::Close(Some(axum::extract::ws::CloseFrame {
                        code: 4401,
                        reason: "device_revoked".into(),
                    })));
                    // Deliver the terminal reason when possible, but do not let
                    // a non-reading phone keep its revoked connection alive.
                    let _ = tokio::time::timeout(Duration::from_millis(250), &mut writer).await;
                    break;
                }
                if app.store.expire_interactions().is_err() { break; }
            },
            _ = heartbeat.tick() => {
                if last_pong.elapsed() > Duration::from_secs(65)
                    || control_tx.try_send(Message::Ping(Vec::new().into())).is_err()
                { break; }
            },
            incoming = reader.next() => match incoming {
                Some(Ok(Message::Pong(_))) => last_pong = Instant::now(),
                Some(Ok(Message::Ping(bytes))) => {
                    if control_tx.try_send(Message::Pong(bytes)).is_err() { break; }
                },
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                _ => {},
            },
        }
    }
}

#[cfg(test)]
mod pairing_tests {
    use super::*;
    fn app() -> Arc<App> {
        App::new(
            Arc::new(
                crate::store::Store::open(std::path::Path::new(":memory:"), "test".into()).unwrap(),
            ),
            crate::runtime::RuntimeConfig {
                state_dir: Default::default(),
                omp: Default::default(),
                bridge: Default::default(),
            },
        )
    }

    #[tokio::test]
    async fn command_failure_status_keeps_structured_body_and_uuid_replay() {
        let app = app();
        let request = json!({"id":uuid::Uuid::new_v4(),"action":"not_an_action","payload":{}});
        let response = command(State(app.clone()), Json(request.clone()))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(response.into_body(), 16 * 1024)
            .await
            .unwrap();
        let failure: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(failure["id"], request["id"]);
        assert_eq!(failure["success"], false);
        assert!(failure["error"]["code"].is_string());
        assert!(failure["error"]["message"].is_string());
        let replay = command(State(app), Json(request)).await.unwrap();
        assert_eq!(replay.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(replay.into_body(), 16 * 1024)
            .await
            .unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&body).unwrap(), failure);
    }

    struct StalledWriter(Arc<tokio::sync::Notify>);
    impl Sink<Message> for StalledWriter {
        type Error = std::convert::Infallible;
        fn poll_ready(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::result::Result<(), Self::Error>> {
            self.0.notify_one();
            std::task::Poll::Pending
        }
        fn start_send(
            self: std::pin::Pin<&mut Self>,
            _: Message,
        ) -> std::result::Result<(), Self::Error> {
            unreachable!("writer is never ready")
        }
        fn poll_flush(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::result::Result<(), Self::Error>> {
            std::task::Poll::Pending
        }
        fn poll_close(
            self: std::pin::Pin<&mut Self>,
            _: &mut std::task::Context<'_>,
        ) -> std::task::Poll<std::result::Result<(), Self::Error>> {
            std::task::Poll::Pending
        }
    }

    #[tokio::test]
    async fn revoked_device_closes_even_when_socket_writer_never_becomes_ready() {
        let app = app();
        let device = app.store.issue_device("phone").unwrap();
        let id = device["deviceId"].as_str().unwrap().to_owned();
        app.store
            .message("s", "m", &json!({"id":"m","content":"queued"}))
            .unwrap();
        let stalled = Arc::new(tokio::sync::Notify::new());
        let reader = futures_util::stream::pending::<
            std::result::Result<Message, std::convert::Infallible>,
        >();
        let monitor = stream_io(
            app.clone(),
            StalledWriter(stalled.clone()),
            reader,
            id.clone(),
            0,
        );
        let revoke = async {
            stalled.notified().await;
            app.store.revoke(&id).unwrap();
            // Keep the peer reader open: only revocation may finish the stream.
            std::future::pending::<()>().await;
        };
        let result = tokio::time::timeout(Duration::from_secs(1), async {
            tokio::select! { _ = monitor => {}, _ = revoke => panic!("revocation did not finish stream") }
        }).await;
        assert!(result.is_ok(), "a stalled socket must not block revocation");
    }

    #[test]
    fn pairing_request_requires_commitment_and_rejects_v1_nonce() {
        let commitment = "ab".repeat(32);
        let request: PairRequest =
            serde_json::from_value(json!({"name":"Phone","clientCommitment":commitment})).unwrap();
        assert_eq!(request.name, "Phone");
        assert_eq!(request.client_commitment, commitment);
        assert!(
            serde_json::from_value::<PairRequest>(
                json!({"name":"Phone","clientNonce":"123456789abcdef0"})
            )
            .is_err()
        );
        assert!(serde_json::from_value::<PairRequest>(json!({"name":"Phone","clientCommitment":commitment,"clientNonce":"123456789abcdef0"})).is_err());
    }

    #[test]
    fn pairing_reveal_requires_exact_fields() {
        let id = "c3f39110-349d-4c92-a49e-977891949688";
        let claim = "34".repeat(32);
        let client = "12".repeat(32);
        let reveal: PairReveal = serde_json::from_value(
            json!({"requestId":id,"claimSecret":claim,"clientSecret":client}),
        )
        .unwrap();
        assert_eq!(reveal.request_id, id);
        assert_eq!(reveal.claim_secret, claim);
        assert_eq!(reveal.client_secret, client);
        assert!(
            serde_json::from_value::<PairReveal>(json!({"requestId":id,"claimSecret":claim}))
                .is_err()
        );
        assert!(serde_json::from_value::<PairReveal>(json!({"requestId":id,"claimSecret":claim,"clientSecret":client,"serverSecret":"56".repeat(32)})).is_err());
    }
}

#[cfg(test)]
mod operation_lifetime_tests {
    use super::*;
    fn app() -> Arc<App> {
        App::new(
            Arc::new(
                crate::store::Store::open(std::path::Path::new(":memory:"), "test".into()).unwrap(),
            ),
            crate::runtime::RuntimeConfig {
                state_dir: Default::default(),
                omp: Default::default(),
                bridge: Default::default(),
            },
        )
    }
    #[tokio::test]
    async fn disconnect_drops_waiter_not_owned_command_and_duplicate_never_executes() {
        let app = app();
        let id = uuid::Uuid::new_v4().to_string();
        let request = json!({"id":id,"action":"session.bash","sessionId":"s"});
        assert!(app.store.begin_command(&id, &request).unwrap().is_none());
        let (release, wait) = tokio::sync::oneshot::channel();
        let (done, finished) = tokio::sync::oneshot::channel();
        let store = app.store.clone();
        let output_id = id.clone();
        let task = spawn_command(app.clone(), id.clone(), async move {
            wait.await.context("release")?;
            store.command_output(&output_id, "stdout", "finished after disconnect")?;
            let _ = done.send(());
            Ok(json!({"completed":true}))
        });
        drop(task); // Hyper cancelling the waiting handler drops this handle too.
        assert_eq!(
            app.store.begin_command(&id, &request).unwrap().unwrap()["status"],
            "running"
        );
        release.send(()).unwrap();
        finished.await.unwrap();
        for _ in 0..10 {
            if app.store.command_status(&id).unwrap()["status"] == "succeeded" {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert_eq!(
            app.store.command_status(&id).unwrap()["status"],
            "succeeded"
        );
        assert_eq!(
            app.store.begin_command(&id, &request).unwrap().unwrap()["data"]["completed"],
            true
        );
        assert_eq!(
            app.store.command_output_page(&id, 0, 10).unwrap()["items"][0]["text"],
            "finished after disconnect"
        );
    }
    #[tokio::test]
    async fn panicked_owned_command_is_durable_unknown_not_false_failure_or_replayed() {
        let app = app();
        let id = uuid::Uuid::new_v4().to_string();
        let request = json!({"id":id,"action":"session.bash"});
        app.store.begin_command(&id, &request).unwrap();
        let task = spawn_command(app.clone(), id.clone(), async {
            panic!("worker panic");
            #[allow(unreachable_code)]
            Ok(Value::Null)
        });
        assert_eq!(task.await.unwrap().unwrap()["status"], "unknown");
        assert_eq!(app.store.command_status(&id).unwrap()["status"], "unknown");
        assert_eq!(
            app.store.begin_command(&id, &request).unwrap().unwrap()["error"]["code"],
            "outcome_unknown"
        );
    }
}
