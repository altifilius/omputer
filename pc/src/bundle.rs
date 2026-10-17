use anyhow::{Context, Result, bail};
use fs2::FileExt;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Cursor,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Component, Path, PathBuf},
};

static RESOURCES: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/resources.tar.zst"));
const MAX_UNPACKED_BYTES: u64 = 1024 * 1024 * 1024;

/// Materialize the release's exact bundled runtime; no user-side dependency installer.
pub fn materialize_embedded() -> Result<Option<PathBuf>> {
    if RESOURCES.is_empty() {
        return Ok(None);
    }
    let digest = hex::encode(Sha256::digest(RESOURCES));
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".cache")
        })
        .join("omputer/bundles");
    fs::create_dir_all(&base).context("Uygulama kaynak önbelleği oluşturulamadı")?;
    reject_symlink(&base)?;
    fs::set_permissions(&base, fs::Permissions::from_mode(0o700))?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .mode(0o600)
        .open(base.join("extract.lock"))?;
    let lock_info = lock.metadata()?;
    if !lock_info.is_file()
        || lock_info.uid() != unsafe { libc::geteuid() }
        || lock_info.mode() & 0o077 != 0
    {
        bail!("Uygulama kaynak kilidi güvenli bir kullanıcı dosyası değil");
    }
    lock.lock_exclusive()?;
    let destination = base.join(&digest);
    let complete = destination.join(".complete");
    if destination.exists() {
        reject_symlink(&destination)?;
        if fs::read_to_string(&complete).ok().as_deref() == Some(&digest)
            && destination.join("resources/omp-runtime").is_file()
            && destination.join("resources/bridge/index.ts").is_file()
        {
            return Ok(Some(destination));
        }
        bail!(
            "Uygulama kaynak önbelleği eksik veya değişmiş: {}",
            destination.display()
        );
    }
    let staging = base.join(format!(".extract-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&staging)?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))?;
    let result = extract(RESOURCES, &staging).and_then(|()| {
        if !staging.join("resources/omp-runtime").is_file()
            || !staging.join("resources/bridge/index.ts").is_file()
        {
            bail!("Paket OMP çalışma zamanını veya oturum köprüsünü içermiyor");
        }
        fs::set_permissions(
            staging.join("resources/omp-runtime"),
            fs::Permissions::from_mode(0o700),
        )?;
        fs::write(staging.join(".complete"), &digest)?;
        fs::rename(&staging, &destination)?;
        Ok(())
    });
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    result?;
    Ok(Some(destination))
}

fn reject_symlink(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        bail!(
            "Uygulama kaynak yolu normal bir dizin olmalı: {}",
            path.display()
        );
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        bail!("Uygulama kaynak dizininin sahibi bu kullanıcı değil");
    }
    Ok(())
}

fn extract(bytes: &[u8], destination: &Path) -> Result<()> {
    let decoder = zstd::stream::read::Decoder::new(Cursor::new(bytes))?;
    let mut archive = tar::Archive::new(decoder);
    let mut total = 0u64;
    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.into_owned();
        if path.as_os_str().is_empty()
            || path
                .components()
                .any(|part| !matches!(part, Component::Normal(_)))
            || !path.starts_with("resources")
        {
            bail!("Paketin kaynak yolu geçersiz");
        }
        let kind = entry.header().entry_type();
        if !kind.is_file() && !kind.is_dir() {
            bail!("Paket sembolik bağlantı veya özel dosya içeremez");
        }
        total = total
            .checked_add(entry.size())
            .context("Paket boyutu taşıyor")?;
        if total > MAX_UNPACKED_BYTES {
            bail!("Paket açılım boyutu sınırı aşıldı");
        }
        if !entry.unpack_in(destination)? {
            bail!("Paket dosyası özel kaynak dizininin dışına çıkıyor");
        }
    }
    Ok(())
}

use std::os::unix::fs::MetadataExt;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn embedded_archive_rejects_links_and_outside_root() {
        for (name, link) in [("outside/file", false), ("resources/escape", true)] {
            let temporary = tempfile::tempdir().unwrap();
            let mut tar = tar::Builder::new(Vec::new());
            let mut header = tar::Header::new_gnu();
            header.set_size(0);
            header.set_mode(0o600);
            if link {
                header.set_entry_type(tar::EntryType::Symlink);
                header.set_link_name("/etc/passwd").unwrap();
            }
            header.set_cksum();
            tar.append_data(&mut header, name, std::io::empty())
                .unwrap();
            let archive = tar.into_inner().unwrap();
            let compressed = zstd::stream::encode_all(Cursor::new(archive), 1).unwrap();
            assert!(extract(&compressed, temporary.path()).is_err());
        }
    }
}
