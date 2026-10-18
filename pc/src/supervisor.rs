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
    admin_with_pid(state, action, payload).map(|(value, _)| value)
}

fn admin_with_pid(state: &Path, action: &str, payload: Value) -> Result<(Value, libc::pid_t)> {
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
    stream.set_read_timeout(Some(
        if matches!(
            action,
            "backup.create" | "backup.restore" | "update.closeIdle" | "update.resume"
        ) {
            Duration::from_secs(180)
        } else {
            Duration::from_secs(3)
        },
    ))?;
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
    Ok((frame["data"].clone(), credentials.pid))
}

pub fn update_warning(install: &Installation) -> Option<String> {
    let (_, pid) = admin_with_pid(&install.layout.state, "status", json!({})).ok()?;
    let running = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let installed = install.executable.canonicalize().ok()?;
    (running != installed).then(|| "Güncelleme hazır; çalışan yerel hizmet önceki sürümde bırakıldı. Etkin oturumlar kesilmedi. Yeni hizmet bir sonraki normal hizmet başlangıcında yüklenir. Açık terminal OMP oturumları yeni köprüyü ancak kendi normal yeniden açılışlarında yükler; bellekte değiştirilmez.".into())
}

fn startup_warning(install: &Installation, additional: Option<String>) -> Option<String> {
    let mut warnings = install.warnings.clone();
    warnings.extend(additional);
    (!warnings.is_empty()).then(|| warnings.join("\n"))
}

/// Port zero in the managed launcher means a stable owner-only preference,
/// not a new ephemeral firewall target on every service start.
pub fn automatic_port(state: &Path, requested: u16) -> Result<u16> {
    let path = state.join("lan-port");
    if requested != 0 {
        setup::atomic_write(&path, requested.to_string().as_bytes(), 0o600)?;
        return Ok(requested);
    }
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)
    {
        Ok(mut file) => {
            let info = file.metadata()?;
            if !info.is_file()
                || info.uid() != unsafe { libc::geteuid() }
                || info.mode() & 0o077 != 0
                || info.len() > 5
            {
                bail!("Automatic LAN port must be a private owned regular file");
            }
            let mut value = String::new();
            file.read_to_string(&mut value)?;
            let port: u16 = value
                .parse()
                .context("Saved automatic LAN port is invalid")?;
            if port == 0 {
                bail!("Saved automatic LAN port cannot be zero");
            }
            Ok(port)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            setup::atomic_write(&path, b"8787", 0o600)?;
            Ok(8787)
        }
        Err(error) => Err(error.into()),
    }
}

pub fn restart_owned(install: &Installation) -> Result<()> {
    let (prepared, pid) = admin_with_pid(&install.layout.state, "update.prepare", json!({}))
        .context("Güncelleme bekletildi. Etkin uygulama oturumlarını tamamlayın; çalışan sürüm güvenli güncelleme hazırlığını desteklemiyorsa hizmetin normal sonraki başlangıcını bekleyin")?;
    if prepared["prepared"] != true || prepared["managedRpcSessions"] != 0 {
        let _ = admin(&install.layout.state, "update.cancel", json!({}));
        bail!("Etkin uygulama oturumları korunuyor; güncelleme henüz uygulanamaz");
    }
    let result = (|| -> Result<()> {
        let main_pid = systemctl_output(&[
            "--user",
            "show",
            "--property=MainPID",
            "--value",
            "omputer.service",
        ])
        .ok()
        .and_then(|value| value.trim().parse::<libc::pid_t>().ok());
        if install.service_owned && main_pid == Some(pid) {
            let fragment = systemctl_output(&[
                "--user",
                "show",
                "--property=FragmentPath",
                "--value",
                "omputer.service",
            ])?;
            if std::path::Path::new(fragment.trim()).canonicalize()?
                != install.layout.unit().canonicalize()?
            {
                bail!("Yerel hizmet farklı bir kullanıcı birimine ait; değiştirilmedi");
            }
            run_systemctl(&["--user", "daemon-reload"])?;
            run_systemctl(&["--user", "restart", "omputer.service"])?;
        } else {
            let guard = setup::lock(&install.layout.state.join("supervisor.lock"))?;
            if guard.try_lock_exclusive().is_ok() {
                bail!("Çalışan hizmet Omputer arka plan yöneticisine ait değil; korunuyor");
            }
            setup::atomic_write(
                &install.layout.state.join("supervisor.update"),
                pid.to_string().as_bytes(),
                0o600,
            )?;
        }
        let deadline = Instant::now() + Duration::from_secs(25);
        while Instant::now() < deadline {
            if let Ok((status, next_pid)) =
                admin_with_pid(&install.layout.state, "status", json!({}))
                && status["ready"] == true
                && next_pid != pid
                && update_warning(install).is_none()
            {
                if install.layout.state.join("restore-error").exists() {
                    bail!(
                        "{}",
                        fs::read_to_string(install.layout.state.join("restore-error"))?
                    );
                }
                return Ok(());
            }
            thread::sleep(Duration::from_millis(200));
        }
        bail!(
            "Güncelleme henüz hazır değil. Yerel bağlantı bilgilerini kontrol edip yeniden deneyin; eski kaynaklar ve eşleştirme korundu"
        )
    })();
    if result.is_err() {
        let _ = fs::remove_file(install.layout.state.join("supervisor.update"));
        let _ = admin(&install.layout.state, "update.cancel", json!({}));
    }
    result
}

/// Apply only the staged release; restore its predecessor if readiness fails.
/// User data is never removed or rewritten by binary rollback.
pub fn apply_update(install: &Installation) -> Result<()> {
    let (_, pid) = admin_with_pid(&install.layout.state, "status", json!({}))?;
    let previous = fs::read_link(format!("/proc/{pid}/exe"))?;
    let result = restart_owned(install);
    if let Err(error) = result {
        setup::rollback_release(&install.layout, &previous)?;
        // A failing candidate may have exited; start only our owned integration.
        let _ = restart_owned(install).or_else(|_| ensure_running(install, true).map(|_| ()));
        bail!("Update failed; previous executable restored, user data preserved: {error:#}");
    }
    Ok(())
}

pub fn ensure_running(install: &Installation, retry: bool) -> Result<Startup> {
    let already_ready =
        admin(&install.layout.state, "status", json!({})).is_ok_and(|v| v["ready"] == true);
    let disabled = !install.service_owned
        || std::env::var_os("OMPUTER_DISABLE_SYSTEMD").is_some_and(|v| v == "1");
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
                    warning: startup_warning(install, None),
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
        warning: startup_warning(install, fallback_reason),
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
        warnings: Vec::new(),
        service_owned: false,
    };
    let mut child: Option<Child> = None;
    let mut attempts = VecDeque::<Instant>::new();
    let mut paused = false;
    let mut paused_until: Option<Instant> = None;
    let mut retry_marker =
        fs::read(install.layout.state.join("supervisor.retry")).unwrap_or_default();
    let mut ready_at = None;
    let mut update_marker =
        fs::read(install.layout.state.join("supervisor.update")).unwrap_or_default();
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
        let marker = fs::read(install.layout.state.join("supervisor.update")).unwrap_or_default();
        if marker != update_marker {
            update_marker = marker.clone();
            if let Some(process) = child.as_mut()
                && String::from_utf8_lossy(&marker).parse::<u32>().ok() == Some(process.id())
                && let Ok((prepared, pid)) =
                    admin_with_pid(&install.layout.state, "update.prepare", json!({}))
                && pid as u32 == process.id()
                && prepared["prepared"] == true
                && prepared["managedRpcSessions"] == 0
                && fs::read(install.layout.state.join("supervisor.update"))
                    .ok()
                    .as_ref()
                    == Some(&marker)
            {
                // Exact owned child, authenticated preparation and no managed
                // RPC session: never signal terminal OMP or process groups.
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
                attempts.clear();
                paused = false;
                paused_until = None;
            }
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
    if let Ok(error) = fs::read_to_string(layout.state.join("listener-error")) {
        return Some(error);
    }
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
    fn automatic_port_reuses_saved_value_and_honors_explicit_override() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(automatic_port(temp.path(), 0).unwrap(), 8787);
        assert_eq!(automatic_port(temp.path(), 33975).unwrap(), 33975);
        let busy = std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = busy.local_addr().unwrap().port();
        assert_eq!(automatic_port(temp.path(), port).unwrap(), port);
        assert_eq!(automatic_port(temp.path(), 0).unwrap(), port);
        assert!(std::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_err());
        assert_eq!(
            fs::read_to_string(temp.path().join("lan-port")).unwrap(),
            port.to_string()
        );
    }

    #[test]
    fn automatic_port_rejects_symlinks_and_corrupt_preference() {
        let temp = tempfile::tempdir().unwrap();
        let original = temp.path().join("keep");
        fs::write(&original, "33975").unwrap();
        std::os::unix::fs::symlink(&original, temp.path().join("lan-port")).unwrap();
        assert!(automatic_port(temp.path(), 0).is_err());
        assert_eq!(fs::read_to_string(original).unwrap(), "33975");
        fs::remove_file(temp.path().join("lan-port")).unwrap();
        setup::atomic_write(&temp.path().join("lan-port"), b"0", 0o600).unwrap();
        assert!(automatic_port(temp.path(), 0).is_err());
    }
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
