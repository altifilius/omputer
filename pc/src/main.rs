mod bundle;
mod desktop;
mod setup;
mod supervisor;

use anyhow::{Context, Result, bail};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use clap::{Parser, Subcommand};
use fs2::FileExt;
use omputer::{
    archive,
    discovery::LocalServices,
    runtime::{App, RuntimeConfig},
    security, server,
    store::Store,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{fs, net::SocketAddr, os::unix::fs::PermissionsExt, path::PathBuf, sync::Arc};

#[derive(Parser)]
#[command(
    name = "omputer",
    version,
    about = "Local-only OMP controller. HTTPS/WSS and Unix IPC; no relay, cloud backend, or push service.",
    after_help = "Open Omputer without a subcommand to install and start the local desktop application. Explicit subcommands are optional diagnostics. The app bundles its OMP runtime and bridge, automatically discovers the local LAN, and requires approval on this PC before a phone can control it. No cloud relay, public exposure, or router/firewall changes are configured."
)]
struct Cli {
    #[arg(
        long,
        global = true,
        env = "OMPUTER_STATE_DIR",
        help = "Private local state directory (default XDG_DATA_HOME/omputer or ~/.local/share/omputer)"
    )]
    state_dir: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        help = "Developer/test override: folder containing resources/omp-runtime and resources/bridge/index.ts"
    )]
    bundle_dir: Option<PathBuf>,
    #[arg(
        long,
        global = true,
        hide = true,
        help = "Run the installed private background supervisor"
    )]
    background: bool,
    #[command(subcommand)]
    command: Option<Commands>,
}
#[derive(Subcommand)]
enum Commands {
    #[command(
        about = "Run HTTPS/WSS daemon and local bridge IPC; loopback-only unless explicitly configured"
    )]
    Serve {
        #[arg(
            long,
            default_value = "127.0.0.1:8787",
            help = "Socket address; use 0.0.0.0:8787 only for explicit LAN/VPN access"
        )]
        listen: SocketAddr,
        #[arg(long, default_value = "Omputer")]
        name: String,
        #[arg(
            long,
            default_value = "omp",
            help = "Actual installed OMP executable (requires rpc-ui support)"
        )]
        omp: PathBuf,
        #[arg(
            long,
            help = "Absolute path to Omputer bridge/index.ts (default this source checkout's bridge/index.ts)"
        )]
        bridge: Option<PathBuf>,
        #[arg(
            long,
            help = "Additional certificate SAN at first identity creation only; paired identity is never silently rotated"
        )]
        tls_host: Vec<String>,
    },
    #[command(about = "Register or inspect locally authorized canonical project roots")]
    Project {
        #[command(subcommand)]
        command: ProjectCommands,
    },
    #[command(about = "Create a one-use 10-minute bundle; stdout JSON, stderr URI and optional QR")]
    Pair {
        #[arg(
            long,
            help = "Phone-reachable HTTPS origin, e.g. https://192.168.1.10:8787"
        )]
        url: String,
        #[arg(long, help = "Print pairing QR to stderr as well as the URI")]
        qr: bool,
    },
    #[command(about = "List or revoke paired devices locally (revocation closes active WSS)")]
    Device {
        #[command(subcommand)]
        command: DeviceCommands,
    },
    #[command(about = "Import saved OMP JSONL read-only; never opens or resumes a live writer")]
    Import {
        #[arg(help = "JSONL file or directory (default local OMP agent/sessions)")]
        path: Option<PathBuf>,
    },
}
#[derive(Subcommand)]
enum ProjectCommands {
    Add {
        path: PathBuf,
        #[arg(long)]
        name: Option<String>,
    },
    List,
}
#[derive(Subcommand)]
enum DeviceCommands {
    List,
    Revoke { id: String },
}
#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("omputer: {e:#}");
        std::process::exit(1);
    }
}
async fn run() -> Result<()> {
    let cli = Cli::parse();
    let dir = cli.state_dir.unwrap_or_else(security::default_state_dir);
    if cli.command.is_none() {
        if cli.background {
            return supervisor::background(setup::Layout::discover(dir)?);
        }
        return desktop::run(dir, cli.bundle_dir);
    }
    if cli.background {
        bail!("--background cannot be combined with a diagnostic subcommand");
    }
    let command = cli.command.unwrap();
    let mut hosts = match &command {
        Commands::Serve { tls_host, .. } => tls_host.clone(),
        _ => Vec::new(),
    };
    if matches!(&command, Commands::Serve { .. })
        && std::env::var_os("OMPUTER_AUTOMATIC_LAN").is_some_and(|value| value == "1")
    {
        let ip = supervisor::automatic_address(0)?.ip().to_string();
        if !hosts.contains(&ip) {
            hosts.push(ip);
        }
    }
    let _diagnostic_guard = if !matches!(&command, Commands::Serve { .. }) {
        setup::private_dir(&dir)?;
        let guard = setup::lock(&dir.join("daemon.lock"))?;
        guard.try_lock_exclusive().context("The running service owns this database; use the native application's controls instead of an offline diagnostic mutation")?;
        Some(guard)
    } else {
        None
    };
    // Acquire the single-writer lease before opening/migrating SQLite. Restore
    // never swaps a database underneath a live Store or HTTP/bridge listener.
    setup::private_dir(&dir)?;
    let daemon_guard = if matches!(&command, Commands::Serve { .. }) {
        let guard = setup::lock(&dir.join("daemon.lock"))?;
        guard
            .try_lock_exclusive()
            .context("Another Omputer daemon already owns this state directory")?;
        omputer::backup::recover_interrupted_restore(&dir)?;
        if let Err(error) = omputer::backup::apply_pending_restore(&dir) {
            omputer::backup::recover_interrupted_restore(&dir)?;
            setup::atomic_write(
                &dir.join("restore-error"),
                format!("Restore rejected; original database retained: {error:#}").as_bytes(),
                0o600,
            )?;
            if dir.join("restore.request").exists() {
                fs::rename(
                    dir.join("restore.request"),
                    dir.join(format!("restore-rejected-{}.request", uuid::Uuid::new_v4())),
                )?;
            }
        }
        Some(guard)
    } else {
        None
    };
    security::initialize(&dir, &hosts)?;
    let server_name = match &command {
        Commands::Serve { name, .. } => {
            fs::write(dir.join("server-name"), name)?;
            name.clone()
        }
        _ => fs::read_to_string(dir.join("server-name")).unwrap_or_else(|_| "Omputer".into()),
    };
    let opened = if daemon_guard.is_some() {
        omputer::backup::open_store_recovering(&dir, server_name.clone())
    } else {
        Store::open(&dir.join("omputer.sqlite"), server_name.clone())
    };
    if opened.is_err() && daemon_guard.is_some() {
        omputer::backup::finish_restore(&dir, false)?;
    }
    let store = Arc::new(opened?);
    if daemon_guard.is_some() {
        omputer::backup::finish_restore(&dir, true)?;
    }
    match command {
        Commands::Project { command } => match command {
            ProjectCommands::Add { path, name } => println!(
                "{}",
                serde_json::to_string_pretty(&store.register_project(&path, name)?)?
            ),
            ProjectCommands::List => println!(
                "{}",
                serde_json::to_string_pretty(&store.snapshot()?["projects"])?
            ),
        },
        Commands::Device { command } => match command {
            DeviceCommands::List => {
                println!("{}", serde_json::to_string_pretty(&store.devices()?)?)
            }
            DeviceCommands::Revoke { id } => {
                store.revoke(&id)?;
                println!("{}", json!({"success":true,"id":id}));
            }
        },
        Commands::Pair { url, qr } => {
            let parsed = url::Url::parse(&url).context("--url must be a reachable HTTPS origin")?;
            if parsed.scheme() != "https"
                || parsed.host_str().is_none()
                || !parsed.username().is_empty()
                || parsed.password().is_some()
                || parsed.query().is_some()
                || parsed.fragment().is_some()
                || parsed.path() != "/"
            {
                bail!(
                    "--url must be only https://HOST:PORT, without credentials, path, query, or fragment"
                );
            }
            let (code, expires) = store.create_pair()?;
            let certificate = fs::read(dir.join("certificate.der"))?;
            let bundle = json!({"version":1,"url":url.trim_end_matches('/'),"certificate":STANDARD.encode(&certificate),"fingerprint":hex::encode(Sha256::digest(&certificate)),"code":code,"expiresAt":expires});
            let uri = format!(
                "omputer://pair?data={}",
                URL_SAFE_NO_PAD.encode(bundle.to_string())
            );
            println!("{}", serde_json::to_string_pretty(&bundle)?);
            eprintln!("{uri}");
            if qr {
                let code = qrcode::QrCode::new(uri.as_bytes())
                    .context("Pairing bundle is too large for QR; paste raw bundle JSON instead")?;
                eprintln!(
                    "{}",
                    code.render::<qrcode::render::unicode::Dense1x2>()
                        .quiet_zone(true)
                        .build()
                );
            }
            if parsed
                .host_str()
                .is_some_and(|h| h == "localhost" || h == "127.0.0.1" || h == "::1")
            {
                eprintln!(
                    "Loopback is not reachable from a physical phone. Use its reachable LAN/VPN origin after explicit LAN binding."
                );
            }
        }
        Commands::Import { path } => {
            let path = path.unwrap_or_else(|| archive::agent_dir().join("sessions"));
            let files = archive::files(&path)?;
            let mut imported = 0;
            let mut failed = 0;
            for file in files {
                match archive::import(&store, &file) {
                    Ok(_) => imported += 1,
                    Err(e) => {
                        failed += 1;
                        eprintln!("Skipped {}: {e}", file.display());
                    }
                }
            }
            println!("{}", json!({"imported":imported,"failed":failed}));
            if failed > 0 {
                bail!("Some files could not be imported; originals were not modified");
            }
        }
        Commands::Serve {
            mut listen,
            omp,
            bridge,
            ..
        } => {
            let automatic =
                std::env::var_os("OMPUTER_AUTOMATIC_LAN").is_some_and(|value| value == "1");
            if automatic {
                listen = supervisor::automatic_address(supervisor::automatic_port(
                    &dir,
                    listen.port(),
                )?)?;
            }
            let socket = dir.join("bridge.sock");
            if socket.exists() {
                if tokio::net::UnixStream::connect(&socket).await.is_ok() {
                    bail!(
                        "An active bridge socket already exists in {}; refusing to replace it",
                        dir.display()
                    );
                }
                fs::remove_file(&socket)?;
            }
            let listener = tokio::net::UnixListener::bind(&socket)?;
            fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
            let bridge = bridge.unwrap_or_else(|| {
                std::env::current_exe()
                    .ok()
                    .and_then(|path| {
                        path.parent()
                            .map(|parent| parent.join("resources/bridge/index.ts"))
                    })
                    .unwrap_or_else(|| PathBuf::from("resources/bridge/index.ts"))
            });
            let bridge = bridge.canonicalize().with_context(|| {
                format!(
                    "Bundled bridge extension is missing at {}",
                    bridge.display()
                )
            })?;
            let config = RuntimeConfig {
                state_dir: dir.canonicalize()?,
                omp,
                bridge,
            };
            let app = App::new(store, config);
            app.initialize_disconnected()?;
            // Capture immutable running hashes before publishing the admin API.
            omputer::backup::components(&app);
            tokio::spawn(app.clone().ipc(listener));
            rustls::crypto::ring::default_provider()
                .install_default()
                .map_err(|_| anyhow::anyhow!("Cannot initialize Rustls cryptography"))?;
            let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(
                dir.join("certificate.pem"),
                dir.join("key.pem"),
            )
            .await?;
            let listener = loop {
                match std::net::TcpListener::bind(listen) {
                    Ok(listener) => break listener,
                    Err(error) if automatic => {
                        setup::atomic_write(&dir.join("listener-error"),
                            format!("Yerel HTTPS {listen} adresinde başlatılamadı: {error}. Bağlantı noktası korunuyor; 5 saniyede yeniden deneniyor. Bu noktayı kullanan diğer uygulamayı kapatın veya Omputer kullanıcı hizmetindeki --listen ayarını düzeltin.").as_bytes(), 0o600)?;
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                        listen = supervisor::automatic_address(listen.port())?;
                    }
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!("Cannot bind {listen}; choose --listen HOST:PORT")
                        });
                    }
                }
            };
            listener.set_nonblocking(true)?;
            let mut address = listener.local_addr()?;
            let mut local_services = LocalServices::start(app.clone(), address, &server_name)?;
            fs::remove_file(dir.join("listener-error")).ok();
            let (shutdown_tx, mut shutdown_rx) = tokio::sync::watch::channel(false);
            tokio::spawn(async move {
                let mut terminate =
                    match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    {
                        Ok(signal) => signal,
                        Err(_) => return,
                    };
                tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
                let _ = shutdown_tx.send(true);
            });
            let mut listener = listener;
            'listeners: loop {
                println!("OMPUTER_READY=https://{address}");
                let handle = axum_server::Handle::new();
                let serving_handle = handle.clone();
                let router = server::router(app.clone());
                let config = tls.clone();
                let mut serving = tokio::spawn(async move {
                    axum_server::from_tcp_rustls(listener, config)
                        .handle(serving_handle)
                        .serve(router.into_make_service_with_connect_info::<SocketAddr>())
                        .await
                });
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
                loop {
                    tokio::select! {
                        outcome = &mut serving => {
                            outcome.context("HTTPS listener task stopped")??;
                            break 'listeners;
                        }
                        _ = shutdown_rx.changed() => {
                            handle.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
                            serving.await.context("HTTPS shutdown failed")??;
                            break 'listeners;
                        }
                        _ = interval.tick(), if automatic => {
                            let next = supervisor::automatic_address(address.port())?;
                            if next.ip() == address.ip() { continue; }
                            match std::net::TcpListener::bind(next) {
                                Ok(next_listener) => {
                                    next_listener.set_nonblocking(true)?;
                                    handle.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
                                    serving.await.context("HTTPS rebind failed")??;
                                    local_services.update_address(next).await?;
                                    local_services.listener_error(None);
                                    address = next;
                                    listener = next_listener;
                                    continue 'listeners;
                                }
                                Err(error) => local_services.listener_error(Some(format!(
                                    "Yerel ağ adresi {next} henüz açılamadı: {error}. Çalışan oturumlar korunuyor; 5 saniyede yeniden deneniyor."))),
                            }
                        }
                    }
                }
            }
            fs::remove_file(socket).ok();
        }
    }
    Ok(())
}
