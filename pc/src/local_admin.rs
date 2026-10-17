use crate::{
    discovery::{LocalState, constant_time_equal},
    rpc_transport,
    runtime::App,
};
use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, atomic::Ordering},
    time::Duration,
};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    task::{JoinHandle, JoinSet},
};

pub struct AdminSocket {
    path: PathBuf,
    device: u64,
    inode: u64,
    listener: parking_lot::Mutex<Option<UnixListener>>,
}
impl AdminSocket {
    pub fn bind(dir: &Path) -> Result<Self> {
        let path = dir.join("admin.sock");
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() }
                {
                    bail!("Refusing to replace non-socket or foreign admin.sock");
                }
                match std::os::unix::net::UnixStream::connect(&path) {
                    Ok(_) => bail!("An active local admin socket already exists"),
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::ConnectionRefused | std::io::ErrorKind::NotFound
                        ) => {}
                    Err(error) => {
                        return Err(error).context("Cannot establish whether admin.sock is stale");
                    }
                }
                let current = fs::symlink_metadata(&path)?;
                if current.dev() != metadata.dev() || current.ino() != metadata.ino() {
                    bail!("admin.sock changed during stale-socket inspection");
                }
                fs::remove_file(&path)?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(&path)?;
        Ok(Self {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
            listener: parking_lot::Mutex::new(Some(listener)),
        })
    }
    pub fn serve(&self, app: Arc<App>, state: Arc<LocalState>) -> Result<JoinHandle<()>> {
        let listener = self
            .listener
            .lock()
            .take()
            .context("Admin listener already started")?;
        let token_path = app.config.state_dir.join("bridge.token");
        let metadata = fs::symlink_metadata(&token_path)?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
            || metadata.len() > 256
        {
            bail!("Admin credential must be a same-user private regular file");
        }
        let token = fs::read_to_string(token_path)?.trim().to_owned();
        if token.len() != 64 {
            bail!("Invalid local admin credential");
        }
        Ok(tokio::spawn(async move {
            let limit = Arc::new(Semaphore::new(16));
            let mut clients = JoinSet::new();
            loop {
                tokio::select! {
                    result = listener.accept() => {
                        let (stream, _) = match result { Ok(value) => value, Err(error) => {state.ready.store(false,Ordering::Release);state.discovery.lock()["adminError"]=json!(error.to_string());return;} };
                        let permit = match limit.clone().try_acquire_owned() { Ok(permit) => permit, Err(_) => continue };
                        let app = app.clone(); let state = state.clone(); let token = token.clone();
                        clients.spawn(async move {
                            let _permit = permit;
                            let _ = tokio::time::timeout(Duration::from_secs(30), connection(stream,app,state,&token)).await;
                        });
                    },
                    _ = clients.join_next(), if !clients.is_empty() => {},
                }
            }
        }))
    }
    pub fn remove_owned(&self) {
        if fs::symlink_metadata(&self.path).is_ok_and(|metadata| {
            metadata.file_type().is_socket()
                && metadata.dev() == self.device
                && metadata.ino() == self.inode
                && metadata.uid() == unsafe { libc::geteuid() }
        }) {
            let _ = fs::remove_file(&self.path);
        }
    }
}
impl Drop for AdminSocket {
    fn drop(&mut self) {
        self.remove_owned();
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AdminRequest {
    token: String,
    id: Value,
    action: String,
    #[serde(default)]
    payload: Value,
}
async fn connection(
    stream: UnixStream,
    app: Arc<App>,
    state: Arc<LocalState>,
    token: &str,
) -> Result<()> {
    if stream.peer_cred()?.uid() != unsafe { libc::geteuid() } {
        bail!("Admin peer is not this user");
    }
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    // Exactly one bounded request/response per connection. No unbounded idle
    // readers and no local request body forwarded onto an HTTP auth bypass.
    let line = tokio::time::timeout(
        Duration::from_secs(5),
        rpc_transport::line(&mut reader, 16 * 1024),
    )
    .await??
    .context("Empty admin request")?;
    let request: AdminRequest = serde_json::from_str(&line).context("Invalid admin JSON")?;
    if !(request.id.is_string() && request.id.as_str().is_some_and(|id| id.len() <= 128)
        || request.id.is_number())
    {
        bail!("Invalid admin request id");
    }
    let response = if !constant_time_equal(&request.token, token) {
        json!({"id":request.id,"success":false,"error":{"code":"unauthorized","message":"Same-user admin token required"}})
    } else {
        match action(&app, &state, &request.action, &request.payload).await {
            Ok(data) => json!({"id":request.id,"success":true,"data":data}),
            Err(error) => {
                json!({"id":request.id,"success":false,"error":{"code":"admin_rejected","message":error.to_string()}})
            }
        }
    };
    write.write_all(response.to_string().as_bytes()).await?;
    write.write_all(b"\n").await?;
    write.shutdown().await?;
    Ok(())
}
fn empty(payload: &Value) -> Result<()> {
    if !payload.is_null() && !payload.as_object().is_some_and(|value| value.is_empty()) {
        bail!("This action takes no payload");
    }
    Ok(())
}
fn identifier<'a>(payload: &'a Value, key: &str) -> Result<&'a str> {
    let object = payload.as_object().context("Payload must be an object")?;
    if object.len() != 1 {
        bail!("Unexpected action payload fields");
    }
    let id = payload[key]
        .as_str()
        .context("Action identifier is missing")?;
    uuid::Uuid::parse_str(id).context("Action identifier must be a UUID")?;
    Ok(id)
}
async fn action(
    app: &Arc<App>,
    state: &Arc<LocalState>,
    action: &str,
    payload: &Value,
) -> Result<Value> {
    match action {
        "status" => {
            empty(payload)?;
            let snapshot = app.store.snapshot()?;
            let discovery = state.discovery.lock().clone();
            let urls = state.urls.lock().clone();
            Ok(
                json!({"serverId":state.server_id,"serverName":state.server_name,"fingerprint":state.fingerprint,"certificate":state.certificate,"port":state.port,"urls":urls,"ready":state.ready.load(Ordering::Acquire),"projects":snapshot["projects"].as_array().map_or(0,Vec::len),"sessions":snapshot["sessions"].as_array().map_or(0,Vec::len),"pendingPairs":state.pending_pairs(),"devices":snapshot["devices"],"discovery":discovery}),
            )
        }
        "pair.approve" => {
            state.decide_pair(identifier(payload, "requestId")?, true)?;
            Ok(json!({"approved":true}))
        }
        "pair.deny" => {
            state.decide_pair(identifier(payload, "requestId")?, false)?;
            Ok(json!({"denied":true}))
        }
        "pair.bundle" => {
            empty(payload)?;
            let url = state.urls.lock().first().cloned().context("No usable private LAN address; connect the PC to the same trusted network as the phone")?;
            let (code, expires) = app.store.create_pair()?;
            let mut bundle = json!({"version":1,"serverId":state.server_id,"serverName":state.server_name,"url":url,"certificate":state.certificate,"fingerprint":state.fingerprint,"code":code,"expiresAt":expires});
            let uri = format!(
                "omputer://pair?data={}",
                URL_SAFE_NO_PAD.encode(bundle.to_string())
            );
            bundle["uri"] = json!(uri);
            Ok(bundle)
        }
        "device.revoke" => {
            app.store.revoke(identifier(payload, "deviceId")?)?;
            Ok(json!({"revoked":true}))
        }
        "rescan" => {
            empty(payload)?;
            state.scanner.retry_failed();
            let scanner = state.scanner.clone();
            let store = app.store.clone();
            let result = tokio::task::spawn_blocking(move || scanner.scan(&store)).await?;
            state.discovery.lock()["archives"] = result.clone();
            Ok(result)
        }
        _ => bail!("Unknown local admin action"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener as StdListener;
    #[tokio::test]
    async fn socket_does_not_replace_files_or_active_listeners() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("admin.sock");
        fs::write(&path, "owner data").unwrap();
        assert!(AdminSocket::bind(temp.path()).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "owner data");
        fs::remove_file(&path).unwrap();
        let listener = StdListener::bind(&path).unwrap();
        assert!(AdminSocket::bind(temp.path()).is_err());
        drop(listener);
        let socket = AdminSocket::bind(temp.path()).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        drop(socket);
        assert!(!path.exists());
    }
}
