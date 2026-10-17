use crate::{runtime::App, security};
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{
        ConnectInfo, Path, Query, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, patch, post},
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

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
        Self::new(StatusCode::BAD_REQUEST, "request_rejected", e)
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
        .route("/v1/sessions/{id}/messages", get(messages))
        .route("/v1/projects/{id}/files", get(file))
        .route("/v1/projects/{id}", patch(project))
        .route("/v1/devices/{id}/revoke", post(revoke))
        .route("/v1/commands", post(command))
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
async fn snapshot(State(app): State<Arc<App>>) -> Result<Json<Value>, ApiError> {
    app.store.expire_interactions()?;
    let mut snapshot = app.store.snapshot()?;
    if let Some(local) = app.local.get() {
        snapshot["serverId"] = json!(local.server_id);
        snapshot["discovery"] = local.discovery.lock().clone();
    }
    Ok(Json(snapshot))
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
    let (text, truncated) = security::read_project_file(root, &query.path, 256 * 1024)
        .map_err(|e| ApiError::new(StatusCode::FORBIDDEN, "file_rejected", e))?;
    Ok(Json(
        json!({"path":query.path,"text":text,"truncated":truncated}),
    ))
}
async fn project(
    State(app): State<Arc<App>>,
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let mut project = app.store.get("project", &id)?;
    let fields = body
        .as_object()
        .context("Project patch must be an object")?;
    for (key, value) in fields {
        match key.as_str() {
            "goal" | "summary" | "nextStep" => {
                if !value.is_string() {
                    return Err(ApiError::new(
                        StatusCode::BAD_REQUEST,
                        "invalid_memory",
                        format!("{key} must be a string"),
                    ));
                }
                project[key] = value.clone();
            }
            "decisions" => {
                if !value
                    .as_array()
                    .is_some_and(|a| a.iter().all(Value::is_string))
                {
                    return Err(ApiError::new(
                        StatusCode::BAD_REQUEST,
                        "invalid_memory",
                        "decisions must be strings",
                    ));
                }
                project[key] = value.clone();
            }
            "sourceSessionId" => {
                if !value.is_null() {
                    let source = app.store.get(
                        "session",
                        value
                            .as_str()
                            .context("sourceSessionId must be a string or null")?,
                    )?;
                    if source["projectId"] != project["id"] {
                        return Err(ApiError::new(
                            StatusCode::BAD_REQUEST,
                            "source_mismatch",
                            "Source session must belong to this project",
                        ));
                    }
                }
                project[key] = value.clone();
            }
            _ => {
                return Err(ApiError::new(
                    StatusCode::BAD_REQUEST,
                    "invalid_memory",
                    format!("Project memory field {key} is not editable"),
                ));
            }
        }
    }
    project["memoryOrigin"] = json!("manual");
    project["updatedAt"] = json!(crate::store::now());
    project["memoryUpdatedAt"] = project["updatedAt"].clone();
    app.store
        .put("project", &id, &project, Some("project.updated"))?;
    Ok(Json(project))
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
    let result = match app.command(&request).await {
        Ok(data) => json!({"id":id,"success":true,"data":data}),
        Err(e) => {
            json!({"id":id,"success":false,"error":{"code":crate::runtime::error_code(&e),"message":e.to_string()}})
        }
    };
    app.store.finish_command(&id, &result)?;
    Ok(command_response(result))
}
fn command_response(result: Value) -> Response {
    let status = if result["success"] == true {
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
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .context("Device token missing")?;
    let device = app.store.authenticate(token)?.context("Device revoked")?;
    Ok(ws
        .max_message_size(64 * 1024)
        .on_upgrade(move |socket| stream(app, socket, device, cursor.after.unwrap_or(0).max(0))))
}
async fn stream(app: Arc<App>, socket: WebSocket, device: String, mut cursor: i64) {
    let (mut writer, mut reader) = socket.split();
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    let mut heartbeat = tokio::time::interval(Duration::from_secs(20));
    let mut last_pong = Instant::now();
    let mut snapshot_sequence = None;
    loop {
        tokio::select! {
            _=tick.tick()=>{
                if !app.store.device_active(&device){let _=writer.send(Message::Close(Some(axum::extract::ws::CloseFrame{code:4401,reason:"device_revoked".into()}))).await;break;}
                if app.store.expire_interactions().is_err(){break;}
                let events=match app.store.journal(cursor,256){Ok(e)=>e,Err(_)=>break};
                for event in events{let seq=event["sequence"].as_i64().unwrap_or(cursor);if writer.send(Message::Text(event.to_string().into())).await.is_err(){return;}cursor=seq;}
                // Replay reaches the authoritative watermark before a snapshot. Later
                // changes stay in SQLite and are replayed on the next tick.
                if let Ok(snapshot)=app.store.snapshot(){
                    let sequence=snapshot["sequence"].as_i64().unwrap_or(cursor);
                    if cursor>sequence{cursor=0;snapshot_sequence=None;continue;}
                    if sequence==cursor&&snapshot_sequence!=Some(sequence){let event=json!({"sequence":sequence,"type":"snapshot","data":snapshot,"createdAt":crate::store::now()});if writer.send(Message::Text(event.to_string().into())).await.is_err(){return;}snapshot_sequence=Some(sequence);}
                }
            },
            _=heartbeat.tick()=>{
                if last_pong.elapsed()>Duration::from_secs(65){break;}
                if writer.send(Message::Ping(Vec::new().into())).await.is_err(){break;}
            },
            incoming=reader.next()=>match incoming{Some(Ok(Message::Pong(_)))=>last_pong=Instant::now(),Some(Ok(Message::Ping(bytes)))=>{if writer.send(Message::Pong(bytes)).await.is_err(){break;}},Some(Ok(Message::Close(_)))|None|Some(Err(_))=>break,_=>{}}
        }
    }
}

#[cfg(test)]
mod pairing_tests {
    use super::*;

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
