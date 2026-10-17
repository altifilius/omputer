use crate::{autodiscover::ArchiveScanner, local_admin, runtime::App, security, store::Store};
use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};
use parking_lot::Mutex;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    fs,
    net::{IpAddr, SocketAddr},
    os::unix::fs::MetadataExt,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{net::UdpSocket, task::JoinHandle};
use uuid::Uuid;

pub const SERVICE_TYPE: &str = "_omputer._tcp.local.";
pub const DISCOVERY_PORT: u16 = 47878;
const PAIR_LIFETIME: Duration = Duration::from_secs(120);
const RECORD_LIFETIME: Duration = Duration::from_secs(300);
const MAX_REQUESTS: usize = 128;

/// RFC1918 and IPv6 ULA only. Public, multicast and scoped link-local
/// addresses are deliberately absent from automatic announcements and bundles.
pub fn is_private_lan(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.is_private() && !ip.is_unspecified(),
        IpAddr::V6(ip) => (ip.segments()[0] & 0xfe00) == 0xfc00,
    }
}
pub fn lan_addresses(bound: SocketAddr) -> Result<Vec<IpAddr>> {
    let mut ips: Vec<_> = if_addrs::get_if_addrs()?
        .into_iter()
        .map(|iface| iface.ip())
        .filter(|ip| is_private_lan(*ip))
        .filter(|ip| {
            bound.ip().is_unspecified() && bound.is_ipv4() == ip.is_ipv4() || *ip == bound.ip()
        })
        .collect();
    ips.sort();
    ips.dedup();
    Ok(ips)
}
fn origin(ip: IpAddr, port: u16) -> String {
    format!("https://{}", SocketAddr::new(ip, port))
}

struct PairRequest {
    name: String,
    claim_hash: String,
    client_commitment: String,
    server_secret: String,
    revealed: Option<PairReveal>,
    expires_at: String,
    created: Instant,
    state: PairState,
}
struct PairReveal {
    client_secret: String,
    code: String,
}
#[derive(Clone, Copy, PartialEq)]
enum PairState {
    Pending,
    Approved,
    Denied,
    Consumed,
}
#[derive(Default)]
struct Window {
    start: Option<Instant>,
    count: u32,
}
impl Window {
    fn allow(&mut self, now: Instant, maximum: u32, period: Duration) -> bool {
        if self
            .start
            .is_none_or(|start| now.duration_since(start) >= period)
        {
            self.start = Some(now);
            self.count = 0;
        }
        if self.count >= maximum {
            return false;
        }
        self.count += 1;
        true
    }
}
#[derive(Default)]
struct PairQueue {
    requests: HashMap<String, PairRequest>,
    origins: HashMap<IpAddr, Window>,
    global: Window,
}
#[derive(Debug)]
pub struct PairError {
    pub code: &'static str,
    pub message: &'static str,
}
fn pair_error(code: &'static str, message: &'static str) -> PairError {
    PairError { code, message }
}

pub struct LocalState {
    pub server_id: String,
    pub server_name: String,
    pub certificate: String,
    pub fingerprint: String,
    pub port: u16,
    pub ready: AtomicBool,
    pub urls: Mutex<Vec<String>>,
    pub discovery: Mutex<Value>,
    pub scanner: Arc<ArchiveScanner>,
    pairs: Mutex<PairQueue>,
}
impl LocalState {
    pub fn identity(&self) -> Value {
        json!({"version":1,"serverId":self.server_id,"serverName":self.server_name,"certificate":self.certificate,"fingerprint":self.fingerprint})
    }
    fn rate(queue: &mut PairQueue, ip: IpAddr, now: Instant) -> Result<(), PairError> {
        queue.origins.retain(|_, window| {
            window
                .start
                .is_some_and(|start| now.duration_since(start) < Duration::from_secs(60))
        });
        if !queue.global.allow(now, 300, Duration::from_secs(60)) {
            return Err(pair_error(
                "pairing_rate_limited",
                "Pairing is temporarily busy; retry in one minute",
            ));
        }
        if queue.origins.len() >= 128 && !queue.origins.contains_key(&ip) {
            return Err(pair_error(
                "pairing_rate_limited",
                "Too many pairing origins; retry in one minute",
            ));
        }
        if !queue
            .origins
            .entry(ip)
            .or_default()
            .allow(now, 180, Duration::from_secs(60))
        {
            return Err(pair_error(
                "pairing_rate_limited",
                "Too many pairing attempts; retry in one minute",
            ));
        }
        Ok(())
    }
    pub fn request_pair(
        &self,
        ip: IpAddr,
        name: &str,
        client_commitment: &str,
    ) -> Result<Value, PairError> {
        self.request_pair_at(ip, name, client_commitment, Instant::now())
    }
    fn request_pair_at(
        &self,
        ip: IpAddr,
        name: &str,
        client_commitment: &str,
        now: Instant,
    ) -> Result<Value, PairError> {
        let mut queue = self.pairs.lock();
        Self::rate(&mut queue, ip, now)?;
        let name = name.trim();
        if name.is_empty()
            || name.len() > 200
            || name.chars().any(char::is_control)
            || !is_pair_hex(client_commitment)
        {
            return Err(pair_error(
                "invalid_pair_request",
                "A device name and 64 lowercase hex clientCommitment are required",
            ));
        }
        queue
            .requests
            .retain(|_, request| now.duration_since(request.created) < RECORD_LIFETIME);
        if queue.requests.len() >= MAX_REQUESTS
            || queue
                .requests
                .values()
                .filter(|request| {
                    matches!(request.state, PairState::Pending | PairState::Approved)
                        && now.duration_since(request.created) < PAIR_LIFETIME
                })
                .count()
                >= 5
        {
            return Err(pair_error(
                "pairing_busy",
                "Pairing queue is full; finish or wait for existing requests to expire",
            ));
        }
        // Neither random secret is revealed until both sides have committed.
        let id = Uuid::new_v4().to_string();
        let claim = security::secret();
        let server_secret = security::secret();
        let server_commitment = server_commitment(&self.fingerprint, &id, &claim, &server_secret);
        let expires = (chrono::Utc::now() + chrono::Duration::seconds(120)).to_rfc3339();
        queue.requests.insert(
            id.clone(),
            PairRequest {
                name: name.to_owned(),
                claim_hash: security::hash(&claim),
                client_commitment: client_commitment.to_owned(),
                server_secret,
                revealed: None,
                expires_at: expires.clone(),
                created: now,
                state: PairState::Pending,
            },
        );
        Ok(
            json!({"version":2,"requestId":id,"claimSecret":claim,"serverCommitment":server_commitment,"expiresAt":expires}),
        )
    }
    pub fn reveal_pair(
        &self,
        ip: IpAddr,
        id: &str,
        claim: &str,
        client_secret: &str,
    ) -> Result<Value, PairError> {
        self.reveal_pair_at(ip, id, claim, client_secret, Instant::now())
    }
    fn reveal_pair_at(
        &self,
        ip: IpAddr,
        id: &str,
        claim: &str,
        client_secret: &str,
        now: Instant,
    ) -> Result<Value, PairError> {
        let mut queue = self.pairs.lock();
        Self::rate(&mut queue, ip, now)?;
        if !is_pair_id(id) || !is_pair_hex(claim) || !is_pair_hex(client_secret) {
            return Err(pair_error(
                "pairing_rejected",
                "A UUID requestId and 64 lowercase hex claimSecret and clientSecret are required",
            ));
        }
        let request = queue.requests.get_mut(id).ok_or_else(|| {
            pair_error(
                "pairing_expired",
                "Pair request expired; start a new request",
            )
        })?;
        if !constant_time_equal(&request.claim_hash, &security::hash(claim)) {
            return Err(pair_error(
                "pairing_rejected",
                "Invalid pairing request or claim secret",
            ));
        }
        if now.duration_since(request.created) >= PAIR_LIFETIME {
            return Err(pair_error(
                "pairing_expired",
                "Pair request expired; start a new request",
            ));
        }
        match request.state {
            PairState::Denied => {
                return Err(pair_error(
                    "pairing_denied",
                    "Pair request was denied on the PC",
                ));
            }
            PairState::Consumed => {
                return Err(pair_error(
                    "pairing_consumed",
                    "Pair request was already claimed",
                ));
            }
            PairState::Pending | PairState::Approved => {}
        }
        if !constant_time_equal(
            &request.client_commitment,
            &client_commitment(&self.fingerprint, client_secret),
        ) {
            return Err(pair_error(
                "pairing_commitment_mismatch",
                "Client secret does not match the original commitment",
            ));
        }
        if let Some(revealed) = &request.revealed {
            if !constant_time_equal(&revealed.client_secret, client_secret) {
                return Err(pair_error(
                    "pairing_commitment_mismatch",
                    "Client secret cannot change after reveal",
                ));
            }
        } else {
            request.revealed = Some(PairReveal {
                client_secret: client_secret.to_owned(),
                code: verification_code(
                    &self.fingerprint,
                    id,
                    client_secret,
                    &request.server_secret,
                ),
            });
        }
        Ok(
            json!({"version":2,"serverSecret":request.server_secret,"verificationCode":request.revealed.as_ref().expect("validated reveal").code}),
        )
    }
    pub fn pending_pairs(&self) -> Vec<Value> {
        let now = Instant::now();
        let queue = self.pairs.lock();
        let mut pending: Vec<_> = queue.requests.iter().filter(|(_, request)| request.state == PairState::Pending && request.revealed.is_some() && now.duration_since(request.created) < PAIR_LIFETIME)
            .map(|(id, request)| json!({"requestId":id,"name":request.name,"verificationCode":request.revealed.as_ref().expect("code-ready request").code,"expiresAt":request.expires_at,"fingerprint":self.fingerprint})).collect();
        pending.sort_by(|a, b| a["expiresAt"].as_str().cmp(&b["expiresAt"].as_str()));
        pending
    }
    pub fn decide_pair(&self, id: &str, approve: bool) -> Result<()> {
        if !is_pair_id(id) {
            bail!("requestId must be a canonical UUID");
        }
        let mut queue = self.pairs.lock();
        let request = queue
            .requests
            .get_mut(id)
            .context("Pair request not found")?;
        if Instant::now().duration_since(request.created) >= PAIR_LIFETIME {
            bail!("Pair request expired");
        }
        if request.state != PairState::Pending {
            bail!("Pair request was already decided");
        }
        if request.revealed.is_none() {
            bail!("Pair request is awaiting the phone's committed secret; approval is unavailable");
        }
        request.state = if approve {
            PairState::Approved
        } else {
            PairState::Denied
        };
        Ok(())
    }
    pub fn claim_pair(
        &self,
        store: &Store,
        ip: IpAddr,
        id: &str,
        claim: &str,
    ) -> Result<Value, PairError> {
        self.claim_pair_at(store, ip, id, claim, Instant::now())
    }
    fn claim_pair_at(
        &self,
        store: &Store,
        ip: IpAddr,
        id: &str,
        claim: &str,
        now: Instant,
    ) -> Result<Value, PairError> {
        let mut queue = self.pairs.lock();
        Self::rate(&mut queue, ip, now)?;
        if !is_pair_id(id) || !is_pair_hex(claim) {
            return Err(pair_error(
                "pairing_rejected",
                "A UUID requestId and 64 lowercase hex claimSecret are required",
            ));
        }
        let Some(request) = queue.requests.get_mut(id) else {
            return Ok(json!({"status":"expired"}));
        };
        if !constant_time_equal(&request.claim_hash, &security::hash(claim)) {
            return Err(pair_error(
                "pairing_rejected",
                "Invalid pairing request or claim secret",
            ));
        }
        if now.duration_since(request.created) >= PAIR_LIFETIME {
            return Ok(json!({"status":"expired"}));
        }
        match request.state {
            PairState::Pending => Ok(json!({"status":"pending"})),
            PairState::Denied => Ok(json!({"status":"denied"})),
            PairState::Consumed => Err(pair_error(
                "pairing_consumed",
                "Pair request was already claimed",
            )),
            PairState::Approved => {
                if request.revealed.is_none() {
                    return Err(pair_error(
                        "pairing_not_revealed",
                        "Reveal the committed client secret before claiming approval",
                    ));
                }
                // The queue lock spans device creation and consumption: concurrent
                // claimers cannot mint a second token. Storage failure leaves it retryable.
                let mut device = store.issue_device(&request.name).map_err(|_| {
                    pair_error(
                        "pairing_storage_failed",
                        "Could not persist paired device on PC",
                    )
                })?;
                request.state = PairState::Consumed;
                device["status"] = json!("approved");
                device["serverId"] = json!(self.server_id);
                Ok(device)
            }
        }
    }
}
fn is_pair_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn is_pair_id(value: &str) -> bool {
    value.len() == 36
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte) || byte == b'-')
        && Uuid::parse_str(value).is_ok()
}
fn client_commitment(fingerprint: &str, client_secret: &str) -> String {
    security::hash(&json!(["omputer-client-v2", fingerprint, client_secret]).to_string())
}
fn server_commitment(fingerprint: &str, id: &str, claim: &str, server_secret: &str) -> String {
    security::hash(&json!(["omputer-server-v2", fingerprint, id, claim, server_secret]).to_string())
}
fn verification_code(
    fingerprint: &str,
    id: &str,
    client_secret: &str,
    server_secret: &str,
) -> String {
    let hash = security::hash(
        &json!([
            "omputer-sas-v2",
            fingerprint,
            id,
            client_secret,
            server_secret
        ])
        .to_string(),
    );
    let number = u32::from_str_radix(&hash[..8], 16).expect("SHA256 hex") % 1_000_000;
    format!("{number:06}")
}
pub(crate) fn constant_time_equal(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

pub struct LocalServices {
    state: Arc<LocalState>,
    tasks: Vec<JoinHandle<()>>,
    admin: local_admin::AdminSocket,
}
impl LocalServices {
    pub fn start(app: Arc<App>, address: SocketAddr, server_name: &str) -> Result<Self> {
        if app.local.get().is_some() {
            bail!("Local services are already initialized");
        }
        if server_name.trim().is_empty()
            || server_name.len() > 200
            || server_name.chars().any(char::is_control)
        {
            bail!("Invalid server name");
        }
        let dir = &app.config.state_dir;
        let metadata = fs::symlink_metadata(dir)?;
        if metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            bail!("Local service state must be a same-user mode0700 directory");
        }
        let id_path = dir.join("server-id");
        if !id_path.try_exists()? {
            match security::private_file(&id_path, Uuid::new_v4().to_string().as_bytes()) {
                Ok(()) => {}
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) => {
                }
                Err(error) => return Err(error),
            }
        }
        let id_meta = fs::symlink_metadata(&id_path)?;
        if !id_meta.is_file()
            || id_meta.len() > 128
            || id_meta.uid() != unsafe { libc::geteuid() }
            || id_meta.mode() & 0o077 != 0
        {
            bail!("Server identity must be a same-user private regular file");
        }
        let id = fs::read_to_string(&id_path)?;
        Uuid::parse_str(id.trim())
            .context("Invalid stored server identity; refusing to silently replace it")?;
        let certificate = fs::read(dir.join("certificate.der"))?;
        let scanner = Arc::new(ArchiveScanner::new());
        let state = Arc::new(LocalState {
            server_id: id.trim().to_owned(),
            server_name: server_name.trim().to_owned(),
            certificate: STANDARD.encode(&certificate),
            fingerprint: {
                use sha2::Digest;
                hex::encode(sha2::Sha256::digest(&certificate))
            },
            port: address.port(),
            ready: AtomicBool::new(false),
            urls: Mutex::new(
                lan_addresses(address)?
                    .iter()
                    .map(|ip| origin(*ip, address.port()))
                    .collect(),
            ),
            discovery: Mutex::new(json!({"mdns":"starting","udp":"starting","archives":{}})),
            scanner,
            pairs: Mutex::new(PairQueue::default()),
        });
        let admin = local_admin::AdminSocket::bind(dir)?;
        app.local
            .set(state.clone())
            .map_err(|_| anyhow::anyhow!("Local services are already initialized"))?;
        let mut tasks = Vec::new();
        tasks.push(admin.serve(app.clone(), state.clone())?);
        let scan_app = app.clone();
        let scan_state = state.clone();
        tasks.push(tokio::spawn(async move {
            loop {
                let scanner = scan_state.scanner.clone();
                let store = scan_app.store.clone();
                match tokio::task::spawn_blocking(move || scanner.scan(&store)).await {
                    Ok(result) => scan_state.discovery.lock()["archives"] = result,
                    Err(error) => {
                        scan_state.discovery.lock()["archives"] = json!({"error":error.to_string()})
                    }
                }
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }));
        tasks.push(start_mdns(state.clone(), address));
        tasks.push(start_udp(state.clone(), address));
        state.ready.store(true, Ordering::Release);
        Ok(Self {
            state,
            tasks,
            admin,
        })
    }
}
impl Drop for LocalServices {
    fn drop(&mut self) {
        self.state.ready.store(false, Ordering::Release);
        for task in &self.tasks {
            task.abort();
        }
        self.admin.remove_owned();
    }
}
struct MdnsGuard(ServiceDaemon, Option<JoinHandle<()>>);
impl Drop for MdnsGuard {
    fn drop(&mut self) {
        let _ = self.0.shutdown();
        if let Some(task) = &self.1 {
            task.abort();
        }
    }
}
fn start_mdns(state: Arc<LocalState>, bound: SocketAddr) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut daemon: Option<MdnsGuard> = None;
        let mut previous = HashSet::new();
        loop {
            let result: Result<()> = (|| {
                let ips = lan_addresses(bound)?;
                *state.urls.lock() = ips.iter().map(|ip| origin(*ip, state.port)).collect();
                if ips.is_empty() {
                    daemon.take();
                    previous.clear();
                    state.discovery.lock()["mdns"] = json!("no_lan_address");
                    return Ok(());
                }
                let current: HashSet<_> = ips.iter().copied().collect();
                if current != previous || daemon.is_none() {
                    // Recreate on address changes so removed/public interfaces cannot
                    // retain announcements; only explicitly private IPs are enabled.
                    daemon.take();
                    let mut mdns = MdnsGuard(ServiceDaemon::new()?, None);
                    let monitor = mdns.0.monitor()?;
                    let monitor_state = state.clone();
                    mdns.1 = Some(tokio::spawn(async move {
                        while let Ok(event) = monitor.recv_async().await {
                            match event {
                                mdns_sd::DaemonEvent::Announce(_, _) => {
                                    monitor_state.discovery.lock()["mdns"] = json!("advertising")
                                }
                                mdns_sd::DaemonEvent::Error(error) => {
                                    monitor_state.discovery.lock()["mdns"] =
                                        json!({"error":error.to_string()})
                                }
                                _ => {}
                            }
                        }
                    }));
                    mdns.0.disable_interface(IfKind::All)?;
                    for ip in &ips {
                        mdns.0.enable_interface(*ip)?;
                    }
                    let host = format!("omputer-{}.local.", state.server_id);
                    let label: String = state
                        .server_name
                        .chars()
                        .filter(|c| *c != '.')
                        .scan(0usize, |bytes, c| {
                            *bytes += c.len_utf8();
                            (*bytes <= 35).then_some(c)
                        })
                        .collect();
                    let instance = format!("{}-{}", label, &state.server_id[..8]);
                    let props = [
                        ("id", state.server_id.as_str()),
                        ("fp", state.fingerprint.as_str()),
                        ("v", "1"),
                    ];
                    let service = ServiceInfo::new(
                        SERVICE_TYPE,
                        &instance,
                        &host,
                        ips.as_slice(),
                        state.port,
                        &props[..],
                    )?;
                    state.discovery.lock()["mdns"] = json!("registering");
                    mdns.0.register(service)?;
                    daemon = Some(mdns);
                    previous = current;
                }
                Ok(())
            })();
            if let Err(error) = result {
                state.discovery.lock()["mdns"] = json!({"error":error.to_string()});
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    })
}
fn start_udp(state: Arc<LocalState>, bound: SocketAddr) -> JoinHandle<()> {
    tokio::spawn(async move {
        if bound.ip().is_loopback() || !bound.is_ipv4() {
            state.discovery.lock()["udp"] = json!("disabled");
            return;
        }
        let socket = match UdpSocket::bind((std::net::Ipv4Addr::UNSPECIFIED, DISCOVERY_PORT)).await
        {
            Ok(socket) => socket,
            Err(error) => {
                state.discovery.lock()["udp"] = json!({"error":error.to_string()});
                return;
            }
        };
        if let Err(error) = socket.set_ttl(1) {
            state.discovery.lock()["udp"] = json!({"error":error.to_string()});
            return;
        }
        state.discovery.lock()["udp"] = json!("listening");
        let response = json!({"id":state.server_id,"name":state.server_name,"port":state.port,"fingerprint":state.fingerprint,"v":1}).to_string();
        let mut sources = HashMap::<IpAddr, Instant>::new();
        let mut total = Window::default();
        let mut bytes = [0u8; 64];
        loop {
            let (count, source) = match socket.recv_from(&mut bytes).await {
                Ok(value) => value,
                Err(error) => {
                    state.discovery.lock()["udp"] = json!({"error":error.to_string()});
                    return;
                }
            };
            if &bytes[..count] != b"OMPUTER_DISCOVER_V1"
                || !(is_private_lan(source.ip()) || source.ip().is_loopback())
            {
                continue;
            }
            // Do not answer private routed networks: UDP fallback is link-local
            // discovery, not a remotely queryable presence service.
            let on_link = if_addrs::get_if_addrs().is_ok_and(|interfaces| {
                interfaces
                    .iter()
                    .any(|interface| match (&interface.addr, source.ip()) {
                        (if_addrs::IfAddr::V4(local), IpAddr::V4(remote)) => {
                            (bound.ip().is_unspecified() && is_private_lan(IpAddr::V4(local.ip))
                                || bound.ip() == IpAddr::V4(local.ip))
                                && (u32::from(local.ip) & u32::from(local.netmask))
                                    == (u32::from(remote) & u32::from(local.netmask))
                        }
                        _ => false,
                    })
            });
            if !on_link {
                continue;
            }
            let now = Instant::now();
            sources.retain(|_, last| now.duration_since(*last) < Duration::from_secs(10));
            if sources.len() >= 128 && !sources.contains_key(&source.ip()) {
                continue;
            }
            if sources
                .get(&source.ip())
                .is_some_and(|last| now.duration_since(*last) < Duration::from_secs(1))
                || !total.allow(now, 30, Duration::from_secs(1))
            {
                continue;
            }
            sources.insert(source.ip(), now);
            let _ = socket.send_to(response.as_bytes(), source).await;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn state() -> LocalState {
        LocalState {
            server_id: Uuid::new_v4().to_string(),
            server_name: "PC".into(),
            certificate: "cert".into(),
            fingerprint: "ab".repeat(32),
            port: 8787,
            ready: AtomicBool::new(true),
            urls: Mutex::new(vec![]),
            discovery: Mutex::new(json!({})),
            scanner: Arc::new(ArchiveScanner::new()),
            pairs: Mutex::new(PairQueue::default()),
        }
    }
    #[test]
    fn pairing_v2_matches_cross_language_transcript() {
        let fingerprint = "ab".repeat(32);
        let client = "12".repeat(32);
        let id = "c3f39110-349d-4c92-a49e-977891949688";
        let claim = "34".repeat(32);
        let server = "56".repeat(32);
        assert_eq!(
            client_commitment(&fingerprint, &client),
            "76e3a88c306079a33eabc893ad297e4a5ef0f8f7f84297561ce2893c590d382f"
        );
        assert_eq!(
            server_commitment(&fingerprint, id, &claim, &server),
            "1829f7be07578a344d9e37d85f06b2c51fa7cc62bb93398458457c35d1d0c9bb"
        );
        assert_eq!(
            security::hash(&json!(["omputer-sas-v2", fingerprint, id, client, server]).to_string()),
            "301319499b68799a1fe96b00f80dc8522fc17831eec8e3aea016f2083e8a07ee"
        );
        assert_eq!(
            verification_code(&fingerprint, id, &client, &server),
            "558025"
        );
        assert_ne!(
            client_commitment(&"cd".repeat(32), &client),
            client_commitment(&fingerprint, &client)
        );
        assert_ne!(
            server_commitment(&fingerprint, id, &"78".repeat(32), &server),
            server_commitment(&fingerprint, id, &claim, &server)
        );
        assert_ne!(
            verification_code(&"cd".repeat(32), id, &client, &server),
            "558025"
        );
    }
    #[test]
    fn pairing_requires_committed_reveal_then_explicit_local_approval() {
        let state = state();
        let store = Store::open(std::path::Path::new(":memory:"), "PC".into()).unwrap();
        let ip = "192.168.1.8".parse().unwrap();
        let client = "12".repeat(32);
        let pair = state
            .request_pair(ip, "Phone", &client_commitment(&state.fingerprint, &client))
            .unwrap();
        let id = pair["requestId"].as_str().unwrap();
        let claim = pair["claimSecret"].as_str().unwrap();
        assert_eq!(pair["version"], 2);
        assert!(is_pair_id(id));
        assert!(is_pair_hex(claim));
        assert!(is_pair_hex(pair["serverCommitment"].as_str().unwrap()));
        assert!(pair.get("verificationCode").is_none());
        assert!(pair.get("serverSecret").is_none());
        assert!(state.pending_pairs().is_empty());
        assert!(state.decide_pair(id, true).is_err());
        assert_eq!(
            state.claim_pair(&store, ip, id, claim).unwrap(),
            json!({"status":"pending"})
        );
        assert_eq!(
            state
                .reveal_pair(ip, id, &"00".repeat(32), &client)
                .unwrap_err()
                .code,
            "pairing_rejected"
        );
        assert_eq!(
            state
                .reveal_pair(ip, id, claim, &"00".repeat(32))
                .unwrap_err()
                .code,
            "pairing_commitment_mismatch"
        );
        assert!(state.pending_pairs().is_empty());
        assert!(state.pairs.lock().requests[id].revealed.is_none());
        let revealed = state.reveal_pair(ip, id, claim, &client).unwrap();
        assert_eq!(revealed["version"], 2);
        let server = revealed["serverSecret"].as_str().unwrap();
        assert_eq!(
            server_commitment(&state.fingerprint, id, claim, server),
            pair["serverCommitment"]
        );
        assert_eq!(
            verification_code(&state.fingerprint, id, &client, server),
            revealed["verificationCode"]
        );
        assert_eq!(state.reveal_pair(ip, id, claim, &client).unwrap(), revealed);
        assert_eq!(
            state
                .reveal_pair(ip, id, claim, &"78".repeat(32))
                .unwrap_err()
                .code,
            "pairing_commitment_mismatch"
        );
        assert_eq!(state.reveal_pair(ip, id, claim, &client).unwrap(), revealed);
        let pending = state.pending_pairs();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0]["verificationCode"], revealed["verificationCode"]);
        for key in [
            "claimSecret",
            "clientSecret",
            "serverSecret",
            "clientCommitment",
            "serverCommitment",
        ] {
            assert!(pending[0].get(key).is_none());
        }
        assert_eq!(
            state.claim_pair(&store, ip, id, claim).unwrap()["status"],
            "pending"
        );
        assert!(store.devices().unwrap().is_empty());
        state.decide_pair(id, true).unwrap();
        assert!(state.decide_pair(id, true).is_err());
        assert!(state.decide_pair(id, false).is_err());
        assert!(state.pending_pairs().is_empty());
        assert_eq!(state.reveal_pair(ip, id, claim, &client).unwrap(), revealed);
        let approved = state.claim_pair(&store, ip, id, claim).unwrap();
        assert_eq!(approved["status"], "approved");
        assert!(
            store
                .authenticate(approved["token"].as_str().unwrap())
                .unwrap()
                .is_some()
        );
        assert_eq!(
            state.claim_pair(&store, ip, id, claim).unwrap_err().code,
            "pairing_consumed"
        );
        assert_eq!(
            state.reveal_pair(ip, id, claim, &client).unwrap_err().code,
            "pairing_consumed"
        );
        assert_eq!(store.devices().unwrap().len(), 1);
    }
    #[test]
    fn concurrent_approved_claims_issue_exactly_one_device() {
        let state = state();
        let store = Store::open(std::path::Path::new(":memory:"), "PC".into()).unwrap();
        let ip = "192.168.1.8".parse().unwrap();
        let client = "12".repeat(32);
        let pair = state
            .request_pair(ip, "Phone", &client_commitment(&state.fingerprint, &client))
            .unwrap();
        let id = pair["requestId"].as_str().unwrap();
        let claim = pair["claimSecret"].as_str().unwrap();
        state.reveal_pair(ip, id, claim, &client).unwrap();
        state.decide_pair(id, true).unwrap();
        let barrier = std::sync::Barrier::new(2);
        let results = std::thread::scope(|scope| {
            let first = scope.spawn(|| {
                barrier.wait();
                state.claim_pair(&store, ip, id, claim)
            });
            let second = scope.spawn(|| {
                barrier.wait();
                state.claim_pair(&store, ip, id, claim)
            });
            [first.join().unwrap(), second.join().unwrap()]
        });
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter_map(|result| result.as_ref().err())
                .next()
                .unwrap()
                .code,
            "pairing_consumed"
        );
        assert_eq!(store.devices().unwrap().len(), 1);
    }
    #[test]
    fn denied_and_expired_requests_cannot_reveal_or_authorize() {
        let state = state();
        let store = Store::open(std::path::Path::new(":memory:"), "PC".into()).unwrap();
        let ip = "192.168.1.8".parse().unwrap();
        let client = "12".repeat(32);
        let commitment = client_commitment(&state.fingerprint, &client);
        let created = Instant::now();
        let denied = state
            .request_pair_at(ip, "Phone", &commitment, created)
            .unwrap();
        let id = denied["requestId"].as_str().unwrap();
        let claim = denied["claimSecret"].as_str().unwrap();
        state
            .reveal_pair_at(ip, id, claim, &client, created)
            .unwrap();
        state.decide_pair(id, false).unwrap();
        assert!(state.decide_pair(id, true).is_err());
        assert_eq!(
            state.claim_pair_at(&store, ip, id, claim, created).unwrap()["status"],
            "denied"
        );
        assert_eq!(
            state
                .reveal_pair_at(ip, id, claim, &client, created)
                .unwrap_err()
                .code,
            "pairing_denied"
        );
        let expired = state
            .request_pair_at(ip, "Phone", &commitment, created)
            .unwrap();
        let id = expired["requestId"].as_str().unwrap();
        let claim = expired["claimSecret"].as_str().unwrap();
        assert_eq!(
            state
                .reveal_pair_at(ip, id, claim, &client, created + PAIR_LIFETIME)
                .unwrap_err()
                .code,
            "pairing_expired"
        );
        assert!(state.pairs.lock().requests[id].revealed.is_none());
        assert_eq!(
            state
                .claim_pair_at(&store, ip, id, claim, created + PAIR_LIFETIME)
                .unwrap()["status"],
            "expired"
        );
        assert!(store.devices().unwrap().is_empty());
        state.pairs.lock().requests.get_mut(id).unwrap().created = Instant::now() - PAIR_LIFETIME;
        assert!(state.decide_pair(id, true).is_err());
        assert!(state.pending_pairs().is_empty());
    }
    #[test]
    fn reveal_and_approval_do_not_extend_initial_expiry() {
        let state = state();
        let store = Store::open(std::path::Path::new(":memory:"), "PC".into()).unwrap();
        let ip = "192.168.1.8".parse().unwrap();
        let client = "12".repeat(32);
        let created = Instant::now();
        let pair = state
            .request_pair_at(
                ip,
                "Phone",
                &client_commitment(&state.fingerprint, &client),
                created,
            )
            .unwrap();
        let id = pair["requestId"].as_str().unwrap();
        let claim = pair["claimSecret"].as_str().unwrap();
        let before_expiry = created + PAIR_LIFETIME - Duration::from_millis(1);
        let revealed = state
            .reveal_pair_at(ip, id, claim, &client, before_expiry)
            .unwrap();
        assert_eq!(
            state
                .reveal_pair_at(ip, id, claim, &client, before_expiry)
                .unwrap(),
            revealed
        );
        state.decide_pair(id, true).unwrap();
        let queue = state.pairs.lock();
        assert_eq!(queue.requests[id].created, created);
        assert_eq!(queue.requests[id].expires_at, pair["expiresAt"]);
        drop(queue);
        assert_eq!(
            state
                .reveal_pair_at(ip, id, claim, &client, created + PAIR_LIFETIME)
                .unwrap_err()
                .code,
            "pairing_expired"
        );
        assert_eq!(
            state
                .claim_pair_at(&store, ip, id, claim, created + PAIR_LIFETIME)
                .unwrap()["status"],
            "expired"
        );
        assert!(store.devices().unwrap().is_empty());
    }
    #[test]
    fn queue_counts_unrevealed_requests_and_releases_expired_slots() {
        let state = state();
        let ip = "192.168.1.8".parse().unwrap();
        let commitment = client_commitment(&state.fingerprint, &"12".repeat(32));
        let created = Instant::now();
        for _ in 0..5 {
            state
                .request_pair_at(ip, "Phone", &commitment, created)
                .unwrap();
        }
        assert!(state.pending_pairs().is_empty());
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", &commitment, created)
                .unwrap_err()
                .code,
            "pairing_busy"
        );
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", &commitment, created + PAIR_LIFETIME)
                .unwrap()["version"],
            2
        );
    }
    #[test]
    fn invalid_shapes_are_rejected_and_all_pair_operations_are_rate_limited() {
        let state = state();
        let store = Store::open(std::path::Path::new(":memory:"), "PC".into()).unwrap();
        let ip = "192.168.1.8".parse().unwrap();
        let now = Instant::now();
        for invalid in [
            "123456789abcdef0".to_owned(),
            "AB".repeat(32),
            "0".repeat(63),
            "g".repeat(64),
        ] {
            assert_eq!(
                state
                    .request_pair_at(ip, "Phone", &invalid, now)
                    .unwrap_err()
                    .code,
                "invalid_pair_request"
            );
        }
        assert!(state.pairs.lock().requests.is_empty());
        for attempt in 4..180 {
            let error = match attempt % 3 {
                0 => state
                    .request_pair_at(ip, "Phone", "invalid", now)
                    .unwrap_err(),
                1 => state
                    .reveal_pair_at(ip, "invalid", "invalid", "invalid", now)
                    .unwrap_err(),
                _ => state
                    .claim_pair_at(&store, ip, "invalid", "invalid", now)
                    .unwrap_err(),
            };
            assert_ne!(error.code, "pairing_rate_limited");
        }
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", "invalid", now)
                .unwrap_err()
                .code,
            "pairing_rate_limited"
        );
        assert_eq!(
            state
                .reveal_pair_at(ip, "invalid", "invalid", "invalid", now)
                .unwrap_err()
                .code,
            "pairing_rate_limited"
        );
        assert_eq!(
            state
                .claim_pair_at(&store, ip, "invalid", "invalid", now)
                .unwrap_err()
                .code,
            "pairing_rate_limited"
        );
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", "invalid", now + Duration::from_secs(60))
                .unwrap_err()
                .code,
            "invalid_pair_request"
        );
    }
    #[test]
    fn pair_identifiers_and_secrets_use_canonical_shapes() {
        let id = "c3f39110-349d-4c92-a49e-977891949688";
        assert!(is_pair_id(id));
        assert!(!is_pair_id(&id.to_uppercase()));
        assert!(!is_pair_id(&id.replace('-', "")));
        assert!(is_pair_hex(&"ab".repeat(32)));
        for invalid in [
            "AB".repeat(32),
            "0".repeat(63),
            "0".repeat(65),
            "g".repeat(64),
        ] {
            assert!(!is_pair_hex(&invalid));
        }
    }

    #[test]
    fn global_pairing_rate_bounds_multiple_origins() {
        let state = state();
        let now = Instant::now();
        for attempt in 0..300 {
            let ip = IpAddr::V4(std::net::Ipv4Addr::new(
                192,
                168,
                1,
                (attempt / 100 + 1) as u8,
            ));
            assert_eq!(
                state
                    .request_pair_at(ip, "Phone", "invalid", now)
                    .unwrap_err()
                    .code,
                "invalid_pair_request"
            );
        }
        let ip = "192.168.1.4".parse().unwrap();
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", "invalid", now)
                .unwrap_err()
                .code,
            "pairing_rate_limited"
        );
        assert_eq!(
            state
                .request_pair_at(ip, "Phone", "invalid", now + Duration::from_secs(60))
                .unwrap_err()
                .code,
            "invalid_pair_request"
        );
    }

    #[test]
    fn automatic_advertisements_exclude_public_and_scoped_addresses() {
        for ip in [
            "8.8.8.8",
            "127.0.0.1",
            "169.254.1.1",
            "::1",
            "fe80::1",
            "2001:4860::1",
        ] {
            assert!(!is_private_lan(ip.parse().unwrap()));
        }
        for ip in ["10.0.0.1", "172.16.0.1", "192.168.2.1", "fd00::1"] {
            assert!(is_private_lan(ip.parse().unwrap()));
        }
    }
}
