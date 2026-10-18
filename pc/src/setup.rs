use anyhow::{Context, Result, bail};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt, symlink},
    path::{Path, PathBuf},
};

const OWNER: &str = "omputer-desktop-install-v1\n";
const ICON: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" rx="30" fill="#10172a"/><path d="M88 64a24 24 0 1 1-24-24" fill="none" stroke="#b8b9ff" stroke-width="12" stroke-linecap="round"/><circle cx="88" cy="40" r="9" fill="#e0ed8b"/></svg>"##;

#[derive(Clone, Debug)]
pub struct Layout {
    pub home: PathBuf,
    pub data: PathBuf,
    pub config: PathBuf,
    pub state: PathBuf,
    pub app: PathBuf,
}

#[derive(Clone, Debug)]
pub struct Installation {
    pub layout: Layout,
    pub executable: PathBuf,
    pub runtime: PathBuf,
    pub bridge: PathBuf,
    pub warnings: Vec<String>,
    pub service_owned: bool,
}

#[derive(Default, Serialize, Deserialize)]
struct Metadata {
    version: u32,
    release: String,
    installed_at: String,
    managed: BTreeMap<String, String>,
}

impl Layout {
    pub fn discover(state: PathBuf) -> Result<Self> {
        let home =
            absolute_env("HOME")?.context("HOME is required for a user-only installation")?;
        let data = absolute_env("XDG_DATA_HOME")?.unwrap_or_else(|| home.join(".local/share"));
        let config = absolute_env("XDG_CONFIG_HOME")?.unwrap_or_else(|| home.join(".config"));
        let state = if state.is_absolute() {
            state
        } else {
            std::env::current_dir()?.join(state)
        };
        Ok(Self {
            app: data.join("omputer/app"),
            home,
            data,
            config,
            state,
        })
    }

    pub fn current(&self) -> PathBuf {
        self.app.join("current")
    }
    pub fn unit(&self) -> PathBuf {
        self.config.join("systemd/user/omputer.service")
    }
    pub fn autostart(&self) -> PathBuf {
        self.config.join("autostart/omputer.desktop")
    }
}

fn absolute_env(key: &str) -> Result<Option<PathBuf>> {
    let Some(value) = std::env::var_os(key).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };
    let path = PathBuf::from(value);
    if !path.is_absolute() {
        bail!("{key} must be an absolute path");
    }
    Ok(Some(path))
}

pub fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path).with_context(|| format!("Cannot create {}", path.display()))?;
    let info = fs::symlink_metadata(path)?;
    if !info.is_dir() || info.file_type().is_symlink() || info.uid() != unsafe { libc::geteuid() } {
        bail!(
            "{} must be a directory owned by the current user, not a symlink",
            path.display()
        );
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub fn lock(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .mode(0o600)
        .open(path)?;
    let info = file.metadata()?;
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Unsafe owner or permissions on {}", path.display());
    }
    Ok(file)
}

pub fn install(layout: Layout, bundle: Option<&Path>) -> Result<Installation> {
    private_dir(&layout.state)?;
    let install_lock = lock(&layout.state.join("install.lock"))?;
    install_lock.lock_exclusive()?;
    let own_exe = std::env::current_exe()?.canonicalize()?;
    let source = match bundle {
        Some(path) => path.to_path_buf(),
        None => {
            // Packaged executables must use their own embedded resources, not
            // arbitrary files placed alongside a downloaded executable.
            crate::bundle::materialize_embedded()?
                .unwrap_or_else(|| own_exe.parent().unwrap().to_path_buf())
        }
    };
    let resources = source.join("resources");
    validate_resources(&resources)?;
    let root_existed = layout.app.exists();
    if root_existed {
        validate_app_root(&layout.app)?;
    } else {
        private_dir(&layout.app)?;
        atomic_write(&layout.app.join(".omputer-owned"), OWNER.as_bytes(), 0o600)?;
    }
    let releases = layout.app.join("releases");
    private_dir(&releases)?;
    let metadata_path = layout.app.join("install.json");
    let mut metadata = if metadata_path.exists() {
        read_owned_json(&metadata_path)?
    } else {
        Metadata::default()
    };
    let installed_source = own_exe
        .parent()
        .is_some_and(|p| p.parent() == Some(releases.as_path()));
    let release = if installed_source && bundle.is_none() {
        let name = own_exe
            .parent()
            .and_then(Path::file_name)
            .and_then(|v| v.to_str())
            .context("Invalid installed release")?;
        if name != metadata.release {
            bail!("Installed release does not match its ownership record");
        }
        name.to_owned()
    } else {
        bundle_digest(&own_exe, &resources)?
    };
    let target = releases.join(&release);
    if !target.exists() {
        let stage = releases.join(format!(".stage-{}", uuid::Uuid::new_v4()));
        private_dir(&stage)?;
        let result = (|| -> Result<()> {
            copy_file(&own_exe, &stage.join("omputer"), 0o700)?;
            copy_tree(&resources, &stage.join("resources"))?;
            // Hash the copy as well: a source being rebuilt must never commit a mixed release.
            if bundle_digest(&stage.join("omputer"), &stage.join("resources"))? != release {
                bail!(
                    "Application bundle changed during installation. Reopen the completed bundle."
                );
            }
            atomic_write(&stage.join(".omputer-release"), release.as_bytes(), 0o600)?;
            sync_directory(&stage)?;
            fs::rename(&stage, &target)?;
            sync_directory(&releases)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_dir_all(&stage);
        }
        result?;
    } else {
        let info = fs::symlink_metadata(&target)?;
        if !info.is_dir()
            || info.uid() != unsafe { libc::geteuid() }
            || fs::read_to_string(target.join(".omputer-release"))? != release
        {
            bail!("Existing release is not owned by this installation");
        }
        validate_resources(&target.join("resources"))?;
        if bundle_digest(&target.join("omputer"), &target.join("resources"))? != release {
            bail!(
                "Installed release resources have changed; reopen the original application bundle"
            );
        }
    }
    let current = layout.current();
    if let Ok(info) = fs::symlink_metadata(&current) {
        if !info.file_type().is_symlink() {
            bail!("Refusing to replace unrelated application current path");
        }
        let destination = fs::read_link(&current)?;
        if destination.components().count() != 2
            || destination.parent() != Some(Path::new("releases"))
        {
            bail!("Application current link does not belong to Omputer");
        }
    }
    let mut installation = Installation {
        executable: current.join("omputer"),
        runtime: current.join("resources/omp-runtime"),
        bridge: current.join("resources/bridge/index.ts"),
        layout,
        warnings: Vec::new(),
        service_owned: false,
    };
    // Complete integrations before publishing the new release. Local edits
    // remain in place and are surfaced to the user rather than blocking startup.
    install_integrations(&mut installation, &mut metadata)?;
    let pending = installation
        .layout
        .app
        .join(format!(".current-{}", uuid::Uuid::new_v4()));
    symlink(Path::new("releases").join(&release), &pending)?;
    fs::rename(&pending, &current)?;
    sync_directory(&installation.layout.app)?;
    metadata.version = 1;
    metadata.release = release;
    metadata.installed_at = chrono::Utc::now().to_rfc3339();
    persist_metadata(&metadata_path, &metadata)?;
    Ok(installation)
}

pub fn rollback_release(layout: &Layout, previous_executable: &Path) -> Result<()> {
    validate_app_root(&layout.app)?;
    let guard = lock(&layout.state.join("install.lock"))?;
    guard.lock_exclusive()?;
    let release = previous_executable
        .parent()
        .context("Previous executable has no release")?;
    if release.parent() != Some(layout.app.join("releases").as_path())
        || previous_executable.file_name() != Some(std::ffi::OsStr::new("omputer"))
    {
        bail!("Previous executable is not an owned installed release; rollback was not attempted");
    }
    let expected = fs::read_to_string(release.join(".omputer-release"))?;
    if bundle_digest(previous_executable, &release.join("resources"))? != expected {
        bail!("Previous release integrity changed; refusing rollback");
    }
    let pending = layout
        .app
        .join(format!(".rollback-{}", uuid::Uuid::new_v4()));
    symlink(
        Path::new("releases").join(release.file_name().context("Release name missing")?),
        &pending,
    )?;
    fs::rename(pending, layout.current())?;
    let mut metadata = read_owned_json(&layout.app.join("install.json"))?;
    metadata.release = expected;
    persist_metadata(&layout.app.join("install.json"), &metadata)?;
    sync_directory(&layout.app)
}

fn validate_app_root(path: &Path) -> Result<()> {
    let info = fs::symlink_metadata(path)?;
    if !info.is_dir() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Application directory has unsafe ownership or permissions");
    }
    if fs::read_to_string(path.join(".omputer-owned"))
        .ok()
        .as_deref()
        != Some(OWNER)
    {
        bail!(
            "Application directory already exists and is not an Omputer-managed installation; nothing was overwritten"
        );
    }
    Ok(())
}

fn validate_resources(path: &Path) -> Result<()> {
    for item in [path.join("omp-runtime"), path.join("bridge/index.ts")] {
        let info = fs::symlink_metadata(&item).with_context(|| {
            format!(
                "The application bundle is incomplete: {} is missing",
                item.display()
            )
        })?;
        if !info.is_file() {
            bail!("Bundled resources must be regular files, not symlinks");
        }
        if item.file_name().is_some_and(|v| v == "omp-runtime") && info.mode() & 0o111 == 0 {
            bail!("Bundled OMP runtime is not executable");
        }
    }
    Ok(())
}

fn files(root: &Path, relative: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
    let info = fs::symlink_metadata(root.join(relative))?;
    if info.file_type().is_symlink() {
        bail!("Bundle contains a symlink: {}", relative.display());
    }
    if info.is_dir() {
        let mut entries =
            fs::read_dir(root.join(relative))?.collect::<std::io::Result<Vec<_>>>()?;
        entries.sort_by_key(|e| e.file_name());
        for entry in entries {
            files(root, &relative.join(entry.file_name()), output)?;
        }
    } else if info.is_file() {
        output.push(relative.to_path_buf());
    } else {
        bail!("Bundle contains a non-regular resource");
    }
    Ok(())
}

fn hash_file(hash: &mut Sha256, path: &Path) -> Result<()> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let mut buffer = [0u8; 128 * 1024];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(())
}

fn bundle_digest(exe: &Path, resources: &Path) -> Result<String> {
    let mut hash = Sha256::new();
    hash.update(b"omputer-release-v1\0");
    hash_file(&mut hash, exe)?;
    let mut paths = Vec::new();
    files(resources, Path::new(""), &mut paths)?;
    for path in paths {
        hash.update(path.as_os_str().as_encoded_bytes());
        hash.update([0]);
        hash.update(fs::metadata(resources.join(&path))?.len().to_le_bytes());
        hash_file(&mut hash, &resources.join(path))?;
    }
    Ok(hex::encode(hash.finalize()))
}

fn copy_file(source: &Path, destination: &Path, mode: u32) -> Result<()> {
    let mut input = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(source)?;
    if !input.metadata()?.is_file() {
        bail!("Only regular bundle files can be copied");
    }
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(destination)?;
    std::io::copy(&mut input, &mut output)?;
    output.sync_all()?;
    Ok(())
}

fn copy_tree(source: &Path, destination: &Path) -> Result<()> {
    private_dir(destination)?;
    let mut paths = Vec::new();
    files(source, Path::new(""), &mut paths)?;
    for path in paths {
        let target = destination.join(&path);
        private_dir(target.parent().unwrap())?;
        let mode = if fs::metadata(source.join(&path))?.mode() & 0o111 != 0 {
            0o700
        } else {
            0o600
        };
        copy_file(&source.join(path), &target, mode)?;
    }
    Ok(())
}

pub fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let parent = path.parent().context("File has no parent")?;
    let temp = parent.join(format!(".omputer-write-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        sync_directory(parent)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)?.sync_all().map_err(Into::into)
}
fn read_owned_json(path: &Path) -> Result<Metadata> {
    let info = fs::symlink_metadata(path)?;
    if !info.is_file() || info.uid() != unsafe { libc::geteuid() } || info.mode() & 0o077 != 0 {
        bail!("Installation metadata has unsafe ownership or permissions");
    }
    serde_json::from_slice(&fs::read(path)?).context("Cannot read installation ownership record")
}
fn persist_metadata(path: &Path, metadata: &Metadata) -> Result<()> {
    atomic_write(path, &serde_json::to_vec_pretty(metadata)?, 0o600)
}

fn managed_write(path: &Path, content: &str, metadata: &mut Metadata) -> Result<bool> {
    let parent = path.parent().unwrap();
    fs::create_dir_all(parent)?;
    let parent_info = fs::symlink_metadata(parent)?;
    if !parent_info.is_dir()
        || parent_info.uid() != unsafe { libc::geteuid() }
        || parent_info.mode() & 0o022 != 0
    {
        bail!(
            "Integration directory must be owned by this user and not writable by others: {}",
            parent.display()
        );
    }
    let key = path
        .to_str()
        .context("Installation paths must be UTF-8")?
        .to_owned();
    if let Ok(info) = fs::symlink_metadata(path) {
        if !info.is_file() || info.uid() != unsafe { libc::geteuid() } {
            bail!(
                "Refusing to replace an unrelated integration: {}",
                path.display()
            );
        }
        let existing = fs::read(path)?;
        if existing != content.as_bytes() {
            let digest = hex::encode(Sha256::digest(&existing));
            if metadata.managed.get(&key) != Some(&digest) {
                return Ok(false);
            }
        }
    }
    atomic_write(path, content.as_bytes(), 0o600)?;
    metadata
        .managed
        .insert(key, hex::encode(Sha256::digest(content.as_bytes())));
    // Commit ownership after each integration so a partial setup is safely retryable.
    Ok(true)
}

fn install_integrations(install: &mut Installation, metadata: &mut Metadata) -> Result<()> {
    let layout = &install.layout;
    let metadata_path = layout.app.join("install.json");
    let icon = layout.data.join("icons/hicolor/scalable/apps/omputer.svg");
    if !managed_write(&icon, ICON, metadata)? {
        install
            .warnings
            .push(format!("Yerel düzenlemeler korundu: {}", icon.display()));
    }
    persist_metadata(&metadata_path, metadata)?;
    let desktop = format!(
        "# Managed by Omputer desktop application\n[Desktop Entry]\nType=Application\nVersion=1.0\nName=Omputer\nComment=OMP oturumları ve telefon bağlantısı\nExec={} --state-dir {}\nIcon={}\nTerminal=false\nCategories=Development;Utility;\nStartupNotify=true\nStartupWMClass=omputer\n",
        desktop_quote(&install.executable)?,
        desktop_quote(&layout.state)?,
        icon.display()
    );
    let desktop_path = layout.data.join("applications/omputer.desktop");
    if !managed_write(&desktop_path, &desktop, metadata)? {
        install.warnings.push(format!(
            "Yerel düzenlemeler korundu: {}",
            desktop_path.display()
        ));
    }
    persist_metadata(&metadata_path, metadata)?;
    let loader = format!(
        "// Managed by Omputer desktop application. Existing terminal sessions are not modified.\nimport type {{ ExtensionAPI }} from '@oh-my-pi/pi-coding-agent';\nimport omputer from {};\nexport default function(api: ExtensionAPI) {{\n  if (process.env.OMPUTER_RPC_MANAGED === '1') return;\n  process.env.OMPUTER_STATE_DIR ??= {};\n  return omputer(api);\n}}\n",
        serde_json::to_string(
            install
                .bridge
                .to_str()
                .context("Bridge path must be UTF-8")?
        )?,
        serde_json::to_string(layout.state.to_str().context("State path must be UTF-8")?)?
    );
    for agent in omputer::autodiscover::agent_directories() {
        if !agent.is_absolute() {
            bail!("OMP agent directory must be absolute");
        }
        let loader_path = agent.join("extensions/omputer.ts");
        if !managed_write(&loader_path, &loader, metadata)? {
            install.warnings.push(format!("OMP uzantısındaki yerel düzenlemeler korundu; yeni köprü otomatik yüklenmeyebilir: {}", loader_path.display()));
        }
        persist_metadata(&metadata_path, metadata)?;
    }
    let path = runtime_path(layout)?;
    let mut environment = format!(
        "Environment={}\nEnvironment={}\nEnvironment={}\n",
        systemd_quote(&format!("PATH={}", path.to_string_lossy()))?,
        systemd_quote(&format!("HOME={}", layout.home.display()))?,
        systemd_quote(&format!("OMPUTER_STATE_DIR={}", layout.state.display()))?
    );
    for key in [
        "XDG_DATA_HOME",
        "XDG_CONFIG_HOME",
        "XDG_CACHE_HOME",
        "PI_CODING_AGENT_DIR",
        "OMP_PROFILE",
        "PI_PROFILE",
        "PI_CONFIG_DIR",
    ] {
        if let Some(value) = std::env::var_os(key) {
            environment.push_str(&format!(
                "Environment={}\n",
                systemd_quote(&format!("{key}={}", value.to_string_lossy()))?
            ));
        }
    }
    let unit = format!(
        "# Managed by Omputer desktop application\n[Unit]\nDescription=Omputer local OMP companion\nAfter=network.target\nStartLimitIntervalSec=0\n\n[Service]\nType=simple\nExecStart={} --state-dir {} serve --listen 0.0.0.0:0 --omp {} --bridge {}\n{}Environment=OMPUTER_AUTOMATIC_LAN=1\nRestart=on-failure\nRestartSec=30\nTimeoutStopSec=10\nKillMode=process\nUMask=0077\nNoNewPrivileges=true\n\n[Install]\nWantedBy=default.target\n",
        systemd_path(&install.executable)?,
        systemd_path(&layout.state)?,
        systemd_path(&install.runtime)?,
        systemd_path(&install.bridge)?,
        environment
    );
    install.service_owned = false;
    if !managed_write(&layout.unit(), &unit, metadata)? {
        install.warnings.push(format!(
            "Hizmetteki yerel düzenlemeler korundu: {}",
            layout.unit().display()
        ));
    }
    if fs::read_to_string(layout.unit()).ok().as_deref() == Some(unit.as_str()) {
        install.service_owned = true;
    }
    persist_metadata(&metadata_path, metadata)?;
    Ok(())
}

pub fn install_autostart(install: &Installation) -> Result<()> {
    let _guard = lock(&install.layout.state.join("install.lock"))?;
    _guard.lock_exclusive()?;
    let path = install.layout.app.join("install.json");
    let mut metadata = read_owned_json(&path)?;
    let entry = format!(
        "# Managed by Omputer desktop application\n[Desktop Entry]\nType=Application\nName=Omputer background connection\nExec={} --state-dir {} --background\nTerminal=false\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n",
        desktop_quote(&install.executable)?,
        desktop_quote(&install.layout.state)?
    );
    if !managed_write(&install.layout.autostart(), &entry, &mut metadata)? {
        bail!(
            "Masaüstü otomatik başlatma dosyasında yerel düzenlemeler var; korundu: {}",
            install.layout.autostart().display()
        );
    }
    persist_metadata(&path, &metadata)
}

pub fn runtime_path(layout: &Layout) -> Result<OsString> {
    let mut paths = vec![
        layout.current().join("resources"),
        layout.home.join(".local/bin"),
        layout.home.join(".bun/bin"),
        layout.home.join(".cargo/bin"),
    ];
    if let Some(path) = std::env::var_os("PATH") {
        for entry in std::env::split_paths(&path) {
            if entry.is_absolute() && !paths.contains(&entry) {
                paths.push(entry);
            }
        }
    }
    for entry in ["/usr/local/bin", "/usr/bin", "/bin"] {
        let path = PathBuf::from(entry);
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    std::env::join_paths(paths).context("Cannot construct the runtime PATH")
}

fn desktop_quote(path: &Path) -> Result<String> {
    let value = path.to_str().context("Desktop paths must be UTF-8")?;
    if value.contains(['\n', '\r', '\0']) {
        bail!("Invalid desktop path");
    }
    Ok(format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('`', "\\`")
            .replace('$', "\\$")
            .replace('%', "%%")
    ))
}
fn systemd_path(path: &Path) -> Result<String> {
    systemd_quote(path.to_str().context("Service paths must be UTF-8")?)
}
fn systemd_quote(value: &str) -> Result<String> {
    if value.contains(['\n', '\r', '\0']) {
        bail!("Invalid service environment or path");
    }
    Ok(format!(
        "\"{}\"",
        value
            .replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_unrelated_and_edited_integrations() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("omputer.service");
        fs::write(&path, "unrelated").unwrap();
        let mut metadata = Metadata::default();
        assert!(!managed_write(&path, "managed", &mut metadata).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), "unrelated");
        fs::remove_file(&path).unwrap();
        managed_write(&path, "managed", &mut metadata).unwrap();
        managed_write(&path, "updated", &mut metadata).unwrap();
        fs::write(&path, "local edits").unwrap();
        assert!(!managed_write(&path, "new release", &mut metadata).unwrap());
        assert_eq!(fs::read_to_string(&path).unwrap(), "local edits");
    }
    #[test]
    fn rejects_symlink_resources_and_does_not_truncate_source() {
        let tmp = tempfile::tempdir().unwrap();
        fs::write(tmp.path().join("original"), "keep").unwrap();
        symlink(tmp.path().join("original"), tmp.path().join("link")).unwrap();
        let mut paths = Vec::new();
        assert!(files(tmp.path(), Path::new("link"), &mut paths).is_err());
        assert!(
            copy_file(
                &tmp.path().join("original"),
                &tmp.path().join("original"),
                0o700
            )
            .is_err()
        );
        assert_eq!(
            fs::read_to_string(tmp.path().join("original")).unwrap(),
            "keep"
        );
    }
    #[test]
    fn quotes_service_and_launcher_paths() {
        assert_eq!(
            systemd_quote("/tmp/one % two").unwrap(),
            "\"/tmp/one %% two\""
        );
        assert!(systemd_quote("bad\nvalue").is_err());
        assert_eq!(
            desktop_quote(Path::new("/tmp/a b")).unwrap(),
            "\"/tmp/a b\""
        );
    }
}
