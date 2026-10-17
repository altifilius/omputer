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
use std::{
    fs::{self, OpenOptions},
    net::SocketAddr,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    sync::Arc,
};

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
    let hosts = match &command {
        Commands::Serve { tls_host, .. } => tls_host.clone(),
        _ => Vec::new(),
    };
    security::initialize(&dir, &hosts)?;
    let server_name = match &command {
        Commands::Serve { name, .. } => {
            fs::write(dir.join("server-name"), name)?;
            name.clone()
        }
        _ => fs::read_to_string(dir.join("server-name")).unwrap_or_else(|_| "Omputer".into()),
    };
    let store = Arc::new(Store::open(
        &dir.join("omputer.sqlite"),
        server_name.clone(),
    )?);
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
                listen = supervisor::automatic_address(listen.port())?;
            }
            let lock = OpenOptions::new()
                .read(true)
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .open(dir.join("daemon.lock"))?;
            lock.try_lock_exclusive()
                .context("Another Omputer daemon already owns this state directory")?;
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
            tokio::spawn(app.clone().ipc(listener));
            rustls::crypto::ring::default_provider()
                .install_default()
                .map_err(|_| anyhow::anyhow!("Cannot initialize Rustls cryptography"))?;
            let tls = axum_server::tls_rustls::RustlsConfig::from_pem_file(
                dir.join("certificate.pem"),
                dir.join("key.pem"),
            )
            .await?;
            let listener = std::net::TcpListener::bind(listen)
                .with_context(|| format!("Cannot bind {listen}; choose --listen HOST:PORT"))?;
            listener.set_nonblocking(true)?;
            let address = listener.local_addr()?;
            let _local_services = LocalServices::start(app.clone(), address, &server_name)?;
            let handle = axum_server::Handle::new();
            let shutdown = handle.clone();
            tokio::spawn(async move {
                let mut terminate =
                    match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    {
                        Ok(signal) => signal,
                        Err(_) => return,
                    };
                tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
                shutdown.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
            });
            let network_changed = Arc::new(std::sync::atomic::AtomicBool::new(false));
            if automatic {
                let shutdown = handle.clone();
                let changed = network_changed.clone();
                tokio::spawn(async move {
                    loop {
                        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                        if supervisor::automatic_address(address.port())
                            .is_ok_and(|next| next.ip() != address.ip())
                        {
                            changed.store(true, std::sync::atomic::Ordering::Release);
                            shutdown.graceful_shutdown(Some(std::time::Duration::from_secs(5)));
                            break;
                        }
                    }
                });
            }
            println!("OMPUTER_READY=https://{address}");
            if !address.ip().is_loopback() {
                eprintln!(
                    "Explicit LAN/VPN listener enabled on {address}. Restrict network access to trusted devices; no public relay or router changes are configured."
                );
            }
            axum_server::from_tcp_rustls(listener, tls)
                .handle(handle)
                .serve(server::router(app).into_make_service_with_connect_info::<SocketAddr>())
                .await?;
            fs::remove_file(socket).ok();
            drop(lock);
            if network_changed.load(std::sync::atomic::Ordering::Acquire) {
                bail!("Private LAN route changed; supervisor will safely rebind");
            }
        }
    }
    Ok(())
}
