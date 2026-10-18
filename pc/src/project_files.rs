use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    os::fd::{AsRawFd, FromRawFd},
    os::unix::{ffi::OsStrExt, fs::OpenOptionsExt},
    path::{Component, Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::io::AsyncReadExt;

const FILE_BYTES: usize = 256 * 1024;
const GIT_BYTES: usize = 1024 * 1024;
const TREE_SCAN: usize = 10_000;

fn relative(path: &str, empty: bool) -> Result<&Path> {
    let path = Path::new(path);
    if (!empty && path.as_os_str().is_empty())
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_) | Component::CurDir))
    {
        bail!("Use a relative project path without parent traversal");
    }
    if path.as_os_str().as_bytes().contains(&0) {
        bail!("Path contains NUL");
    }
    Ok(path)
}
// Pinned descriptors, not canonicalize-then-open, keep concurrent symlink swaps confined.
fn open_beneath(root: &Path, path: &str, directory: bool) -> Result<fs::File> {
    let path = relative(path, true)?;
    let root = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY)
        .open(root)?;
    let path = std::ffi::CString::new(if path.as_os_str().is_empty() {
        b".".as_slice()
    } else {
        path.as_os_str().as_bytes()
    })?;
    #[repr(C)]
    struct How {
        flags: u64,
        mode: u64,
        resolve: u64,
    }
    let how = How {
        flags: (libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NONBLOCK
            | if directory { libc::O_DIRECTORY } else { 0 }) as u64,
        mode: 0,
        resolve: 0x08 | 0x04 | 0x02,
    };
    let fd = unsafe {
        libc::syscall(
            libc::SYS_openat2,
            root.as_raw_fd(),
            path.as_ptr(),
            &how,
            std::mem::size_of::<How>(),
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error())
            .context("Path must exist beneath the project root without symlinks");
    }
    Ok(unsafe { fs::File::from_raw_fd(fd as i32) })
}
pub fn file(root: &Path, path: &str) -> Result<(String, bool)> {
    relative(path, false)?;
    let pin = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(root)?;
    let root = PathBuf::from(format!("/proc/self/fd/{}", pin.as_raw_fd()));
    let file = open_beneath(&root, path, false)?;
    if !file.metadata()?.is_file() {
        bail!("Only regular files can be read");
    }
    let mut bytes = Vec::new();
    file.take(FILE_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    let truncated = bytes.len() > FILE_BYTES;
    bytes.truncate(FILE_BYTES);
    while truncated && std::str::from_utf8(&bytes).is_err_and(|error| error.error_len().is_none()) {
        bytes.pop();
    }
    if bytes.contains(&0) {
        bail!("Binary files are not exposed");
    }
    Ok((
        String::from_utf8(bytes).context("File is not UTF-8 text")?,
        truncated,
    ))
}

pub fn tree(root: &Path, path: &str, query: &str, cursor: usize, limit: usize) -> Result<Value> {
    relative(path, true)?;
    if query.len() > 256 {
        bail!("File search query exceeds 256 bytes");
    }
    let limit = limit.clamp(1, 200);
    let root_pin = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(root)?;
    let root_path = PathBuf::from(format!("/proc/self/fd/{}", root_pin.as_raw_fd()));
    let mut pending = vec![path.trim_end_matches('/').to_owned()];
    let mut entries = Vec::new();
    let mut scanned = 0;
    let mut truncated = false;
    while let Some(directory) = pending.pop() {
        let pinned = open_beneath(&root_path, &directory, true)?;
        for entry in fs::read_dir(format!("/proc/self/fd/{}", pinned.as_raw_fd()))? {
            if scanned >= TREE_SCAN {
                truncated = true;
                break;
            }
            scanned += 1;
            let entry = entry?;
            let name = match entry.file_name().into_string() {
                Ok(name) => name,
                Err(_) => {
                    truncated = true;
                    continue;
                }
            };
            if name == ".git" {
                continue;
            }
            let kind = entry.file_type()?;
            if kind.is_symlink() || !(kind.is_file() || kind.is_dir()) {
                continue;
            }
            let path = if directory.is_empty() {
                name.clone()
            } else {
                format!("{directory}/{name}")
            };
            if !query.is_empty() && kind.is_dir() {
                pending.push(path.clone());
            }
            if query.is_empty() || path.to_lowercase().contains(&query.to_lowercase()) {
                entries.push(json!({"path":path,"name":name,"kind":if kind.is_dir(){"directory"}else{"file"}}));
            }
        }
        if truncated {
            break;
        }
    }
    entries.sort_by(|a, b| a["path"].as_str().cmp(&b["path"].as_str()));
    let has_more = entries.len() > cursor.saturating_add(limit);
    let page: Vec<_> = entries.into_iter().skip(cursor).take(limit).collect();
    Ok(
        json!({"entries":page,"hasMore":has_more,"nextCursor":if has_more{Some(cursor.saturating_add(limit))}else{None},"truncated":truncated,"scanLimit":TREE_SCAN}),
    )
}

async fn git(root: &Path, args: &[&str], bound: usize) -> Result<(Vec<u8>, bool)> {
    let root = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY)
        .open(root)?;
    let cwd = PathBuf::from(format!("/proc/self/fd/{}", root.as_raw_fd()));
    let mut child = tokio::process::Command::new("git")
        .arg("--no-optional-locks")
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
        ])
        .args(args)
        .current_dir(cwd)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()?;
    let stdout = child.stdout.take().context("Git output missing")?;
    let work = async {
        let mut bytes = Vec::new();
        stdout
            .take(bound as u64 + 1)
            .read_to_end(&mut bytes)
            .await?;
        let truncated = bytes.len() > bound;
        if truncated {
            child.kill().await?;
        } else {
            let status = child.wait().await?;
            let expected_diff = args.first() == Some(&"diff")
                && args.contains(&"--no-index")
                && status.code() == Some(1);
            let unborn = args.first() == Some(&"rev-parse")
                && args.contains(&"--quiet")
                && status.code() == Some(1);
            if !status.success() && !expected_diff && !unborn {
                bail!("Git read failed (not a repository or unavailable revision)");
            }
        }
        bytes.truncate(bound);
        Ok((bytes, truncated))
    };
    tokio::time::timeout(Duration::from_secs(5), work)
        .await
        .context("Git read exceeded five seconds")?
}
struct Repository {
    pin: fs::File,
    path: PathBuf,
}
async fn git_root(root: &Path) -> Result<Repository> {
    let pin = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(root)?;
    let path = PathBuf::from(format!("/proc/self/fd/{}", pin.as_raw_fd()));
    let (bytes, truncated) = git(&path, &["rev-parse", "--show-toplevel"], 16 * 1024).await?;
    if truncated {
        bail!("Git root exceeds path limit");
    }
    let output = std::str::from_utf8(&bytes)?.trim_end_matches('\n');
    if Path::new(output).canonicalize()? != path.canonicalize()? {
        bail!("Registered root must be the repository root");
    }
    Ok(Repository { pin, path })
}
pub async fn changes(root: &Path) -> Result<Value> {
    let root = git_root(root).await?;
    let (bytes, mut truncated) = git(
        &root.path,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--ignore-submodules=all",
        ],
        GIT_BYTES,
    )
    .await?;
    let mut fields = bytes.split(|b| *b == 0);
    let mut files = Vec::new();
    while let Some(field) = fields.next() {
        if field.is_empty() {
            continue;
        }
        if field.len() < 4 {
            truncated = true;
            break;
        }
        let status = std::str::from_utf8(&field[..2])?.to_owned();
        let path = match std::str::from_utf8(&field[3..]) {
            Ok(path) => path,
            Err(_) => {
                truncated = true;
                continue;
            }
        };
        relative(path, false)?;
        let mut file = json!({"path":path,"status":status});
        if status.contains('R') || status.contains('C') {
            if let Some(old) = fields.next().and_then(|old| std::str::from_utf8(old).ok()) {
                relative(old, false)?;
                file["oldPath"] = json!(old);
            } else {
                truncated = true;
                break;
            }
        }
        files.push(file);
        if files.len() >= 2000 {
            truncated = true;
            break;
        }
    }
    Ok(json!({"files":files,"truncated":truncated,"fileLimit":2000}))
}
struct DiffScratch(PathBuf);
impl Drop for DiffScratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn snapshot(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    Ok(())
}
pub async fn diff(root: &Path, path: &str) -> Result<Value> {
    relative(path, false)?;
    let root = git_root(root).await?;
    let _pinned = &root.pin;
    let mut current = Vec::new();
    match open_beneath(&root.path, path, false) {
        Ok(file) => {
            if !file.metadata()?.is_file() {
                bail!("Only regular files can be diffed");
            }
            file.take(FILE_BYTES as u64 + 1).read_to_end(&mut current)?;
        }
        Err(error)
            if error
                .downcast_ref::<std::io::Error>()
                .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
        Err(error) => return Err(error),
    }
    let (index, index_overflow) = git(
        &root.path,
        &["ls-files", "--stage", "-z", "--", path],
        64 * 1024,
    )
    .await?;
    if index_overflow {
        bail!("Git index entry exceeds limit");
    }
    if index
        .split(|b| *b == 0)
        .any(|entry| entry.starts_with(b"120000 ") || entry.starts_with(b"160000 "))
    {
        bail!("Symlink and submodule diffs are not exposed");
    }
    let (head, head_overflow) = git(
        &root.path,
        &["rev-parse", "--verify", "--quiet", "HEAD"],
        128,
    )
    .await?;
    if head_overflow {
        bail!("Git revision exceeds limit");
    }
    let mut previous = Vec::new();
    let mut truncated = current.len() > FILE_BYTES;
    if !head.is_empty() {
        let (entry, overflow) = git(
            &root.path,
            &["ls-tree", "-z", "HEAD", "--", path],
            64 * 1024,
        )
        .await?;
        if overflow {
            bail!("Git tree entry exceeds limit");
        }
        if !entry.is_empty() {
            let header = entry
                .split(|b| *b == b'\t')
                .next()
                .context("Malformed Git tree entry")?;
            if header.starts_with(b"120000 ") || header.starts_with(b"160000 ") {
                bail!("Symlink and submodule diffs are not exposed");
            }
            let oid = std::str::from_utf8(header)?
                .split_whitespace()
                .nth(2)
                .context("Git object missing")?;
            let (bytes, overflow) = git(&root.path, &["cat-file", "blob", oid], FILE_BYTES).await?;
            previous = bytes;
            truncated |= overflow;
        }
    }
    current.truncate(FILE_BYTES);
    let binary = previous.contains(&0)
        || current.contains(&0)
        || std::str::from_utf8(&previous).is_err_and(|e| e.error_len().is_some())
        || std::str::from_utf8(&current).is_err_and(|e| e.error_len().is_some());
    if binary || truncated {
        return Ok(
            json!({"path":path,"text":"","truncated":truncated,"binary":binary,"byteLimit":FILE_BYTES}),
        );
    }
    let directory = std::env::temp_dir().join(format!("omputer-diff-{}", uuid::Uuid::new_v4()));
    use std::os::unix::fs::DirBuilderExt;
    fs::DirBuilder::new().mode(0o700).create(&directory)?;
    let scratch = DiffScratch(directory);
    let old = scratch.0.join("before");
    let new = scratch.0.join("after");
    snapshot(&old, &previous)?;
    snapshot(&new, &current)?;
    let old = old.to_str().context("Temporary path must be UTF-8")?;
    let new = new.to_str().context("Temporary path must be UTF-8")?;
    let (bytes, overflow) = git(
        &root.path,
        &[
            "diff",
            "--no-index",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--",
            old,
            new,
        ],
        FILE_BYTES,
    )
    .await?;
    let mut end = bytes.len();
    while end > 0
        && std::str::from_utf8(&bytes[..end]).is_err_and(|error| error.error_len().is_none())
    {
        end -= 1;
    }
    let text = std::str::from_utf8(&bytes[..end])?
        .replace(old, "before")
        .replace(new, "after");
    Ok(json!({"path":path,"text":text,"truncated":overflow,"binary":false,"byteLimit":FILE_BYTES}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tree_is_confined_and_searches_nested_files() {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("nested")).unwrap();
        fs::write(tmp.path().join("nested/needle.rs"), "text").unwrap();
        std::os::unix::fs::symlink("/etc", tmp.path().join("escape")).unwrap();
        assert!(tree(tmp.path(), "../", "", 0, 10).is_err());
        assert!(tree(tmp.path(), "escape", "", 0, 10).is_err());
        assert_eq!(
            tree(tmp.path(), "", "needle", 0, 10).unwrap()["entries"][0]["path"],
            "nested/needle.rs"
        );
    }
    #[tokio::test]
    async fn git_handles_literal_weird_paths_and_rejects_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(
            std::process::Command::new("git")
                .args(["init", "--quiet"])
                .current_dir(tmp.path())
                .status()
                .unwrap()
                .success()
        );
        let path = "--odd\nname.txt";
        fs::write(tmp.path().join(path), "literal content").unwrap();
        let list = changes(tmp.path()).await.unwrap();
        assert_eq!(list["files"][0]["path"], path);
        assert!(
            diff(tmp.path(), path).await.unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("+literal content")
        );
        std::os::unix::fs::symlink("/etc/passwd", tmp.path().join("escape")).unwrap();
        assert!(diff(tmp.path(), "escape").await.is_err());
        assert!(diff(tmp.path(), "../secret").await.is_err());
        fs::write(tmp.path().join("binary"), [0, 1, 2]).unwrap();
        assert_eq!(diff(tmp.path(), "binary").await.unwrap()["binary"], true);
        fs::write(tmp.path().join("large"), vec![b'x'; FILE_BYTES + 1]).unwrap();
        assert_eq!(diff(tmp.path(), "large").await.unwrap()["truncated"], true);
        assert!(file(tmp.path(), "escape").is_err());
        assert!(file(tmp.path(), "../secret").is_err());
    }
    #[tokio::test]
    async fn git_diff_combines_staged_and_worktree_and_handles_deleted_weird_name() {
        let tmp = tempfile::tempdir().unwrap();
        let run = |args: &[&str]| {
            assert!(
                std::process::Command::new("git")
                    .args(args)
                    .env("GIT_CONFIG_NOSYSTEM", "1")
                    .env("GIT_CONFIG_GLOBAL", "/dev/null")
                    .env("GIT_TERMINAL_PROMPT", "0")
                    .current_dir(tmp.path())
                    .status()
                    .unwrap()
                    .success()
            )
        };
        run(&["init", "--quiet"]);
        let path = "tracked\nfile.txt";
        fs::write(tmp.path().join(path), "original\n").unwrap();
        run(&["add", "--", path]);
        run(&[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "initial",
        ]);
        fs::write(tmp.path().join(path), "staged\n").unwrap();
        run(&["add", "--", path]);
        fs::write(tmp.path().join(path), "worktree\n").unwrap();
        let changed = diff(tmp.path(), path).await.unwrap();
        let text = changed["text"].as_str().unwrap();
        assert!(text.contains("-original"));
        assert!(text.contains("+worktree"));
        assert!(!text.contains(tmp.path().to_str().unwrap()));
        fs::remove_file(tmp.path().join(path)).unwrap();
        assert!(
            diff(tmp.path(), path).await.unwrap()["text"]
                .as_str()
                .unwrap()
                .contains("-original")
        );
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), tmp.path().join("escape-dir")).unwrap();
        assert!(tree(tmp.path(), "escape-dir", "", 0, 10).is_err());
    }
}
