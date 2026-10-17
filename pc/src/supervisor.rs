use crate::setup::{self, Installation, Layout};
use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
            net::UnixStream,
            process::CommandExt,
        },
    },
    path::Path,
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop_owned_supervisor(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Clone, Debug)]
pub struct Startup {
    pub mode: String,
    pub warning: Option<String>,
}

pub fn admin(state: &Path, action: &str, payload: Value) -> Result<Value> {
    let uid = unsafe { libc::geteuid() };
    let directory = fs::symlink_metadata(state)?;
    if !directory.is_dir() || directory.uid() != uid || directory.mode() & 0o077 != 0 {
        bail!("Local state must be an owner-only directory");
    }
    let token_path = state.join("bridge.token");
    let token_file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&token_path)?;
    let token_info = token_file.metadata()?;
    if !token_info.is_file() || token_info.uid() != uid || token_info.mode() & 0o077 != 0 {
        bail!("Local authorization token must be owner-only");
    }
    let mut token = String::new();
    token_file.take(4097).read_to_string(&mut token)?;
    let token = token.trim();
    if token.len() < 32 || token.len() > 4096 {
        bail!("Invalid local authorization token");
    }
    let socket_path = state.join("admin.sock");
    let socket_info = fs::symlink_metadata(&socket_path)?;
    if !socket_info.file_type().is_socket()
        || socket_info.uid() != uid
        || socket_info.mode() & 0o077 != 0
    {
        bail!("Local admin socket must be owner-only");
    }
    let mut stream = UnixStream::connect(&socket_path).context("Local service is not ready")?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let mut credentials: libc::ucred = unsafe { std::mem::zeroed() };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            &mut credentials as *mut _ as *mut libc::c_void,
            &mut length,
        )
    };
    if result != 0 || credentials.uid != uid {
        bail!("Local service peer does not belong to this user");
    }
    let id = uuid::Uuid::new_v4().to_string();
    serde_json::to_writer(
        &mut stream,
        &json!({"token":token,"id":id,"action":action,"payload":payload}),
    )?;
    stream.write_all(b"\n")?;
    let mut response = String::new();
    BufReader::new(stream)
        .take(4 * 1024 * 1024 + 1)
        .read_line(&mut response)?;
    if response.len() > 4 * 1024 * 1024 || !response.ends_with('\n') {
        bail!("Invalid bounded local admin response");
    }
    let frame: Value = serde_json::from_str(&response)?;
    if frame["id"] != id || frame["success"] != true {
        bail!(
            "{}",
            frame["error"]["message"]
                .as_str()
                .unwrap_or("Local service rejected the request")
        );
    }
    Ok(frame["data"].clone())
}

pub fn ensure_running(install: &Installation, retry: bool) -> Result<Startup> {
    let already_ready =
        admin(&install.layout.state, "status", json!({})).is_ok_and(|v| v["ready"] == true);
    let disabled = std::env::var_os("OMPUTER_DISABLE_SYSTEMD").is_some_and(|v| v == "1");
    let mut fallback_reason = None;
    if !disabled {
        match run_systemctl(&["--user", "show-environment"]) {
            Ok(_) => {
                run_systemctl(&["--user", "daemon-reload"])?;
                let loaded = systemctl_output(&[
                    "--user",
                    "show",
                    "--property=FragmentPath",
                    "--value",
                    "omputer.service",
                ])?;
                if !loaded.trim().is_empty() {
                    let loaded_path = std::path::PathBuf::from(loaded.trim());
                    if loaded_path.canonicalize().ok() != install.layout.unit().canonicalize().ok()
                    {
                        bail!(
                            "A different omputer.service is already registered with the user manager. It was preserved; this app will not replace or start an unrelated service."
                        );
                    }
                }
                // A fixed restart delay bounds repeated failures and still
                // recovers automatically when a network/runtime returns.
                if retry {
                    let _ = run_systemctl(&["--user", "reset-failed", "omputer.service"]);
                }
                if already_ready {
                    run_systemctl(&["--user", "enable", "omputer.service"])?;
                } else {
                    run_systemctl(&["--user", "enable", "--now", "omputer.service"])?;
                }
                return Ok(Startup {
                    mode: "Oturum açıldığında başlayan kullanıcı hizmeti".into(),
                    warning: None,
                });
            }
            Err(error) => {
                fallback_reason = Some(format!(
                    "Kullanıcı hizmet yöneticisine erişilemiyor. Masaüstü otomatik başlatma kullanılıyor. {error}"
                ))
            }
        }
    }
    setup::install_autostart(install)?;
    if retry {
        setup::atomic_write(
            &install.layout.state.join("supervisor.retry"),
            uuid::Uuid::new_v4().to_string().as_bytes(),
            0o600,
        )?;
    }
    let guard = setup::lock(&install.layout.state.join("supervisor.lock"))?;
    if guard.try_lock_exclusive().is_ok() {
        FileExt::unlock(&guard)?;
        let log = open_log(&install.layout.state.join("supervisor.log"))?;
        let mut command = Command::new(&install.executable);
        command
            .arg("--state-dir")
            .arg(&install.layout.state)
            .arg("--background")
            .env("PATH", setup::runtime_path(&install.layout)?)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log.try_clone()?))
            .stderr(Stdio::from(log));
        detach(&mut command);
        command
            .spawn()
            .context("Cannot start the private background supervisor")?;
    }
    Ok(Startup {
        mode: "Masaüstü otomatik başlatma".into(),
        warning: fallback_reason,
    })
}

fn run_systemctl(arguments: &[&str]) -> Result<()> {
    systemctl_output(arguments).map(|_| ())
}

fn systemctl_output(arguments: &[&str]) -> Result<String> {
    let mut command = Command::new("systemctl");
    command
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .context("User service manager is unavailable")?;
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Some(status) = child.try_wait()? {
            if status.success() {
                let mut output = String::new();
                if let Some(stdout) = child.stdout.take() {
                    stdout.take(32768).read_to_string(&mut output)?;
                }
                return Ok(output);
            }
            let mut error = String::new();
            if let Some(stderr) = child.stderr.take() {
                stderr.take(8192).read_to_string(&mut error)?;
            }
            bail!("User service operation failed: {}", error.trim());
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("User service manager did not respond in time");
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn detach(command: &mut Command) {
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
}

fn open_log(path: &Path) -> Result<std::fs::File> {
    let file = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let info = file.metadata()?;
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Private service log has unsafe ownership or permissions");
    }
    // Rotation is bounded and never touches an unrelated pathname.
    if info.len() > 8 * 1024 * 1024 {
        file.set_len(0)?;
    }
    Ok(file)
}

fn spawn_daemon(install: &Installation) -> Result<Child> {
    let log = open_log(&install.layout.state.join("service.log"))?;
    let mut command = Command::new(&install.executable);
    command
        .arg("--state-dir")
        .arg(&install.layout.state)
        .args(["serve", "--listen", "0.0.0.0:0", "--omp"])
        .arg(&install.runtime)
        .arg("--bridge")
        .arg(&install.bridge)
        .env("OMPUTER_AUTOMATIC_LAN", "1")
        .env("PATH", setup::runtime_path(&install.layout)?)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log));
    command
        .spawn()
        .context("Cannot start the bundled local service")
}

pub fn background(layout: Layout) -> Result<()> {
    setup::private_dir(&layout.state)?;
    let guard = setup::lock(&layout.state.join("supervisor.lock"))?;
    if guard.try_lock_exclusive().is_err() {
        return Ok(());
    }
    unsafe {
        libc::signal(
            libc::SIGTERM,
            stop_owned_supervisor as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGINT,
            stop_owned_supervisor as *const () as libc::sighandler_t,
        );
    }
    let current = layout.current();
    let install = Installation {
        executable: current.join("omputer"),
        runtime: current.join("resources/omp-runtime"),
        bridge: current.join("resources/bridge/index.ts"),
        layout,
    };
    let mut child: Option<Child> = None;
    let mut attempts = VecDeque::<Instant>::new();
    let mut paused = false;
    let mut paused_until: Option<Instant> = None;
    let mut retry_marker =
        fs::read(install.layout.state.join("supervisor.retry")).unwrap_or_default();
    let mut ready_at = None;
    loop {
        if STOP.load(Ordering::Relaxed) {
            // Only the exact child we spawned is signalled. Terminal OMP work is
            // not our child; runtime session processes are never group-killed.
            if let Some(mut process) = child.take()
                && process.try_wait()?.is_none()
            {
                unsafe {
                    libc::kill(process.id() as libc::pid_t, libc::SIGTERM);
                }
                let deadline = Instant::now() + Duration::from_secs(8);
                while process.try_wait()?.is_none() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(100));
                }
                if process.try_wait()?.is_none() {
                    let _ = process.kill();
                    let _ = process.wait();
                }
            }
            return Ok(());
        }
        if paused_until.is_some_and(|deadline| Instant::now() >= deadline) {
            attempts.clear();
            paused = false;
            paused_until = None;
        }
        let marker = fs::read(install.layout.state.join("supervisor.retry")).unwrap_or_default();
        if marker != retry_marker {
            retry_marker = marker;
            attempts.clear();
            paused = false;
            paused_until = None;
        }
        if let Some(process) = child.as_mut()
            && let Some(status) = process.try_wait()?
        {
            child = None;
            ready_at = None;
            record(
                &install.layout,
                "recovering",
                Some(format!(
                    "Yerel hizmet kapandı ({status}); yeniden başlatma bekleniyor."
                )),
            )?;
            thread::sleep(Duration::from_secs(3));
        }
        if admin(&install.layout.state, "status", json!({})).is_ok_and(|v| v["ready"] == true) {
            let start = ready_at.get_or_insert_with(Instant::now);
            if start.elapsed() > Duration::from_secs(120) {
                attempts.clear();
            }
            record(&install.layout, "ready", None)?;
        } else if !paused && child.is_none() {
            // A CLI daemon or a simultaneous user-service start owns daemon.lock.
            // Never race its socket setup or kill a process we did not create.
            let daemon_lock = setup::lock(&install.layout.state.join("daemon.lock"))?;
            if daemon_lock.try_lock_exclusive().is_ok() {
                FileExt::unlock(&daemon_lock)?;
                while attempts
                    .front()
                    .is_some_and(|t| t.elapsed() > Duration::from_secs(120))
                {
                    attempts.pop_front();
                }
                if attempts.len() >= 5 {
                    paused = true;
                    paused_until = Some(Instant::now() + Duration::from_secs(120));
                    record(&install.layout, "recovering", Some("Hizmet art arda kapandı. Güvenli beklemeden sonra otomatik yeniden denenecek; isterseniz şimdi yeniden deneyebilirsiniz.".into()))?;
                } else {
                    attempts.push_back(Instant::now());
                    match spawn_daemon(&install) {
                        Ok(process) => {
                            child = Some(process);
                            record(&install.layout, "starting", None)?;
                        }
                        Err(error) => {
                            record(&install.layout, "failed", Some(format!("{error:#}")))?;
                            if attempts.len() >= 5 {
                                paused = true;
                                paused_until = Some(Instant::now() + Duration::from_secs(120));
                            }
                            thread::sleep(Duration::from_secs(3));
                        }
                    }
                }
            }
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn record(layout: &Layout, state: &str, error: Option<String>) -> Result<()> {
    setup::atomic_write(
        &layout.state.join("supervisor.json"),
        &serde_json::to_vec(
            &json!({"state":state,"error":error,"updatedAt":chrono::Utc::now().to_rfc3339()}),
        )?,
        0o600,
    )
}

pub fn last_error(layout: &Layout) -> Option<String> {
    let status: Value =
        serde_json::from_slice(&fs::read(layout.state.join("supervisor.json")).ok()?).ok()?;
    status["error"].as_str().map(str::to_owned)
}

/// Bind only the chosen private IPv4 route, never an automatic wildcard.
/// Offline PCs keep local administration on loopback and migrate when LAN
/// appears. UDP connect chooses a route without sending a network packet.
pub fn automatic_address(port: u16) -> Result<SocketAddr> {
    let mut candidates: Vec<Ipv4Addr> = if_addrs::get_if_addrs()
        .context("Cannot inspect local network interfaces")?
        .into_iter()
        .filter_map(|interface| match interface.ip() {
            IpAddr::V4(ip) if ip.is_private() => Some(ip),
            _ => None,
        })
        .collect();
    candidates.sort_unstable();
    candidates.dedup();
    for destination in [Ipv4Addr::new(192, 168, 0, 1), Ipv4Addr::new(10, 0, 0, 1)] {
        if let Ok(socket) = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))
            && socket.connect((destination, 9)).is_ok()
            && let Ok(local) = socket.local_addr()
            && let IpAddr::V4(ip) = local.ip()
            && candidates.contains(&ip)
        {
            return Ok(SocketAddr::from((ip, port)));
        }
    }
    Ok(SocketAddr::from((
        candidates.first().copied().unwrap_or(Ipv4Addr::LOCALHOST),
        port,
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refuses_token_symlinks_without_connecting() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("other"),
            "private-token-material-that-is-not-an-admin-token",
        )
        .unwrap();
        std::os::unix::fs::symlink(temp.path().join("other"), temp.path().join("bridge.token"))
            .unwrap();
        assert!(admin(temp.path(), "status", json!({})).is_err());
    }
}
