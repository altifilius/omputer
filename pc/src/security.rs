use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use rand::{RngCore, rngs::OsRng};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Component, Path, PathBuf},
};

pub fn secret() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}
pub fn hash(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}
pub fn default_state_dir() -> PathBuf {
    if let Some(value) = std::env::var_os("OMPUTER_STATE_DIR") {
        return value.into();
    }
    if let Some(value) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(value).join("omputer");
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| ".".into()))
        .join(".local/share/omputer")
}
pub fn private_file(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}
pub fn initialize(dir: &Path, hosts: &[String]) -> Result<()> {
    fs::create_dir_all(dir).context("Cannot create Omputer state directory")?;
    if fs::symlink_metadata(dir)?.file_type().is_symlink() {
        bail!("State directory must not be a symlink");
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    if !dir.join("bridge.token").exists() {
        private_file(&dir.join("bridge.token"), secret().as_bytes())?;
    }
    fs::set_permissions(dir.join("bridge.token"), fs::Permissions::from_mode(0o600))?;
    let cert = dir.join("certificate.pem");
    let key = dir.join("key.pem");
    if cert.exists() != key.exists() {
        bail!(
            "Incomplete TLS identity in {}; restore both certificate.pem and key.pem instead of silently replacing the paired identity",
            dir.display()
        );
    }
    if !cert.exists() {
        let mut names = vec![
            "localhost".to_owned(),
            "127.0.0.1".to_owned(),
            "::1".to_owned(),
        ];
        names.extend_from_slice(hosts);
        let identity = rcgen::generate_simple_self_signed(names)?;
        private_file(&key, identity.key_pair.serialize_pem().as_bytes())?;
        private_file(&cert, identity.cert.pem().as_bytes())?;
        private_file(&dir.join("certificate.der"), identity.cert.der().as_ref())?;
    }
    fs::set_permissions(key, fs::Permissions::from_mode(0o600))?;
    if !dir.join("certificate.der").exists() {
        let pem = fs::read_to_string(cert)?;
        let encoded: String = pem.lines().filter(|s| !s.starts_with("-----")).collect();
        private_file(&dir.join("certificate.der"), &STANDARD.decode(encoded)?)?;
    }
    Ok(())
}

/// Open beneath a pinned root directory, resolving symlinks atomically inside it.
/// Linux openat2 RESOLVE_BENEATH rejects escapes even during concurrent renames.
pub fn read_project_file(root: &Path, relative: &str, bound: usize) -> Result<(String, bool)> {
    let relative = Path::new(relative);
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|c| !matches!(c, Component::Normal(_) | Component::CurDir))
    {
        bail!("Use a nonempty relative path without parent traversal");
    }
    let root = fs::File::open(root)?;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(relative.as_os_str().as_bytes())?;
    #[repr(C)]
    struct OpenHow {
        flags: u64,
        mode: u64,
        resolve: u64,
    }
    let how = OpenHow {
        flags: (libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NONBLOCK) as u64,
        mode: 0,
        resolve: 0x08 | 0x02,
    };
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            root.as_raw_fd(),
            path.as_ptr(),
            &how,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error()).context("File must exist beneath the registered root (escaping symlinks are rejected; Linux openat2 is required)");
    }
    let file = unsafe { fs::File::from_raw_fd(fd as i32) };
    if !file.metadata()?.is_file() {
        bail!("Only regular files can be read");
    }
    let mut bytes = Vec::new();
    file.take(bound as u64 + 1).read_to_end(&mut bytes)?;
    let truncated = bytes.len() > bound;
    bytes.truncate(bound);
    if truncated {
        while std::str::from_utf8(&bytes).is_err_and(|e| e.error_len().is_none()) {
            bytes.pop();
        }
    }
    let text = String::from_utf8(bytes).context("File is not UTF-8 text")?;
    Ok((text, truncated))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_traversal_and_escape_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("project");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("ok"), "hello").unwrap();
        fs::write(tmp.path().join("secret"), "private").unwrap();
        std::os::unix::fs::symlink(tmp.path().join("secret"), root.join("link")).unwrap();
        assert_eq!(read_project_file(&root, "ok", 100).unwrap().0, "hello");
        assert!(read_project_file(&root, "../secret", 100).is_err());
        assert!(read_project_file(&root, "link", 100).is_err());
        assert!(read_project_file(&root, "/etc/passwd", 100).is_err());
    }
}
