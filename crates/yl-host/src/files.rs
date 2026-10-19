//! Authorized file access for the Host.
//!
//! Every operation resolves a client-supplied relative path against the
//! configured root, canonicalizes existing components (resolving symlinks) and
//! verifies the result still starts with the root. Uploads go to a temporary
//! file in the destination directory and are renamed only after size and hash
//! checks. This is a basic single-root implementation; ACLs, SAF, resume and
//! richer conflict policy belong to later milestones.

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::UNIX_EPOCH;

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tracing::warn;

use yl_proto::{FileEntry, ServerMessage};

pub const CHUNK_SIZE: usize = 256 * 1024;
const MAX_ENTRIES: usize = 10_000;
const MAX_UPLOAD_BYTES: u64 = 4 * 1024 * 1024 * 1024;

pub struct FileServer {
    root: PathBuf,
    root_label: String,
    uploads: HashMap<u64, UploadState>,
    downloads: HashMap<u64, Arc<AtomicBool>>,
    download_chunk_size: usize,
}

struct UploadState {
    task_id: u64,
    target: PathBuf,
    temp: PathBuf,
    file: Option<File>,
    hasher: Sha256,
    received: u64,
    expected: u64,
    overwrite: bool,
}

impl Drop for UploadState {
    fn drop(&mut self) {
        // Windows refuses to delete a file that still has an open handle, so
        // close it before removing the temporary file.
        drop(self.file.take());
        let _ = fs::remove_file(&self.temp);
    }
}

impl Drop for FileServer {
    fn drop(&mut self) {
        self.cancel_all_downloads();
    }
}

pub struct DownloadReader {
    task_id: u64,
    relative_path: String,
    file: Option<File>,
    hasher: Sha256,
    offset: u64,
    size: u64,
    cancel: Arc<AtomicBool>,
    chunk_size: usize,
}

impl FileServer {
    pub fn new(root: &Path) -> Result<Self> {
        let root = fs::canonicalize(root)
            .with_context(|| format!("canonicalize file root {}", root.display()))?;
        if !root.is_dir() {
            bail!("file root is not a directory: {}", root.display());
        }
        let root_label = root
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty())
            .unwrap_or("authorized-folder")
            .to_string();
        Ok(Self {
            root,
            root_label,
            uploads: HashMap::new(),
            downloads: HashMap::new(),
            download_chunk_size: CHUNK_SIZE,
        })
    }

    pub fn set_flow_budget(&mut self) {
        self.download_chunk_size = 2048;
    }

    pub fn capabilities(&self) -> (bool, String) {
        (true, self.root_label.clone())
    }

    pub fn list(&self, relative: &str) -> Result<Vec<FileEntry>> {
        let path = self.resolve_existing(relative, true)?;
        let mut entries = Vec::new();
        for entry in fs::read_dir(&path).context("read directory")? {
            let entry = entry.context("read directory entry")?;
            let metadata = match entry.metadata() {
                Ok(metadata) => metadata,
                Err(error) => {
                    warn!(%error, name = %entry.file_name().to_string_lossy(), "skipping unreadable entry");
                    continue;
                }
            };
            if metadata.file_type().is_symlink() {
                // Symlinks are not listed; resolving one could escape the root.
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            let child_relative = join_relative(relative, &name);
            let modified_ms = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_millis() as u64)
                .unwrap_or(0);
            entries.push(FileEntry {
                name,
                path: child_relative,
                is_dir: metadata.is_dir(),
                size: if metadata.is_dir() { 0 } else { metadata.len() },
                modified_ms,
            });
            if entries.len() > MAX_ENTRIES {
                bail!("directory has more than {MAX_ENTRIES} entries");
            }
        }
        entries.sort_by(|a, b| {
            b.is_dir
                .cmp(&a.is_dir)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        Ok(entries)
    }

    pub fn begin_upload(
        &mut self,
        task_id: u64,
        relative: &str,
        size: u64,
        overwrite: bool,
    ) -> Result<()> {
        if size > MAX_UPLOAD_BYTES {
            bail!("file is larger than the 4 GiB M2 upload limit");
        }
        if self.uploads.contains_key(&task_id) {
            bail!("duplicate upload task id {task_id}");
        }
        let (target, temp) = self.resolve_new_file(relative, task_id, overwrite)?;
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .with_context(|| format!("create temporary file {}", temp.display()))?;
        self.uploads.insert(
            task_id,
            UploadState {
                task_id,
                target,
                temp,
                file: Some(file),
                hasher: Sha256::new(),
                received: 0,
                expected: size,
                overwrite,
            },
        );
        Ok(())
    }

    pub fn write_upload_chunk(&mut self, task_id: u64, offset: u64, data: &[u8]) -> Result<u64> {
        let state = self
            .uploads
            .get_mut(&task_id)
            .with_context(|| format!("unknown upload task {task_id}"))?;
        if offset != state.received {
            bail!(
                "upload {} offset mismatch: expected {}, got {}",
                state.task_id,
                state.received,
                offset
            );
        }
        if data.len() > CHUNK_SIZE {
            bail!("upload chunk too large: {}", data.len());
        }
        if state.received + data.len() as u64 > state.expected {
            bail!("upload exceeds declared size {}", state.expected);
        }
        state
            .file
            .as_mut()
            .context("upload file is already closed")?
            .write_all(data)
            .context("write upload chunk")?;
        state.hasher.update(data);
        state.received += data.len() as u64;
        Ok(state.received)
    }

    pub fn finish_upload(&mut self, task_id: u64) -> Result<(String, u64, String)> {
        let mut state = self
            .uploads
            .remove(&task_id)
            .with_context(|| format!("unknown upload task {task_id}"))?;
        if state.received != state.expected {
            bail!(
                "upload incomplete: received {} of {} bytes",
                state.received,
                state.expected
            );
        }
        {
            let file = state
                .file
                .as_mut()
                .context("upload file is already closed")?;
            file.flush().context("flush upload")?;
            file.sync_all().context("sync upload")?;
        }
        drop(state.file.take());
        let digest = state.hasher.clone().finalize();
        let hash = hex::encode(digest);
        if state.target.exists() {
            if !state.overwrite {
                bail!("target already exists");
            }
            if state.target.is_dir() {
                bail!("target is a directory");
            }
        }
        if let Err(error) = commit_temp(&state.temp, &state.target, state.overwrite) {
            return Err(error).context("commit uploaded file");
        }
        let relative = relative_from_root(&self.root, &state.target);
        Ok((relative, state.expected, hash))
    }

    pub fn cancel_task(&mut self, task_id: u64) {
        // Dropping the upload state closes the handle and removes the temporary
        // file on every exit path.
        self.uploads.remove(&task_id);
        if let Some(flag) = self.downloads.remove(&task_id) {
            flag.store(true, Ordering::Relaxed);
        }
    }

    /// Stops every in-flight download, e.g. when the session ends or file
    /// permission is revoked. A cancelled reader reports a terminal error.
    pub fn cancel_all_downloads(&mut self) {
        for (_, flag) in self.downloads.drain() {
            flag.store(true, Ordering::Relaxed);
        }
    }

    pub fn take_download(&mut self, task_id: u64, relative: &str) -> Result<DownloadReader> {
        let path = self.resolve_existing(relative, false)?;
        let metadata = fs::metadata(&path).context("read download metadata")?;
        if !metadata.is_file() {
            bail!("not a regular file: {relative}");
        }
        let file = File::open(&path).context("open download file")?;
        let cancel = Arc::new(AtomicBool::new(false));
        self.downloads.insert(task_id, cancel.clone());
        Ok(DownloadReader {
            task_id,
            relative_path: normalize_relative(relative)?,
            file: Some(file),
            hasher: Sha256::new(),
            offset: 0,
            size: metadata.len(),
            cancel,
            chunk_size: self.download_chunk_size,
        })
    }

    fn resolve_existing(&self, relative: &str, want_dir: bool) -> Result<PathBuf> {
        let relative = normalize_relative(relative)?;
        let joined = if relative.is_empty() {
            self.root.clone()
        } else {
            self.root
                .join(relative.replace('/', std::path::MAIN_SEPARATOR_STR))
        };
        let canonical = fs::canonicalize(&joined)
            .with_context(|| format!("path does not exist: {relative}"))?;
        if !canonical.starts_with(&self.root) {
            bail!("path escapes the authorized root");
        }
        if want_dir && !canonical.is_dir() {
            bail!("not a directory: {relative}");
        }
        if !want_dir && !canonical.is_file() {
            bail!("not a file: {relative}");
        }
        Ok(canonical)
    }

    fn resolve_new_file(
        &self,
        relative: &str,
        task_id: u64,
        overwrite: bool,
    ) -> Result<(PathBuf, PathBuf)> {
        let normalized = normalize_relative(relative)?;
        let mut parts: Vec<&str> = normalized
            .split('/')
            .filter(|part| !part.is_empty())
            .collect();
        let name = parts.pop().context("upload path has no file name")?;
        validate_leaf_name(name)?;
        let parent_relative = parts.join("/");
        let parent = self.resolve_existing(&parent_relative, true)?;
        let target = parent.join(name);
        if let Ok(metadata) = fs::symlink_metadata(&target) {
            if metadata.file_type().is_symlink() {
                bail!("refusing to overwrite a symlink");
            }
            if metadata.is_dir() {
                bail!("target is a directory");
            }
            if !overwrite {
                bail!("target already exists");
            }
        }
        let temp = parent.join(format!(".yuanlian-upload-{task_id}.part"));
        if temp.exists() {
            bail!("temporary upload file already exists");
        }
        Ok((target, temp))
    }
}

impl DownloadReader {
    pub fn stream(mut self, tx: mpsc::Sender<ServerMessage>) -> Result<()> {
        let mut buffer = vec![0u8; self.chunk_size];
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                let _ = tx.blocking_send(ServerMessage::FileError {
                    request_id: 0,
                    task_id: self.task_id,
                    message: "下载已取消".into(),
                });
                return Ok(());
            }
            let file = self.file.as_mut().context("download file is closed")?;
            let read = file.read(&mut buffer).context("read download chunk")?;
            if read > 0 {
                self.hasher.update(&buffer[..read]);
                let chunk = ServerMessage::FileChunk {
                    task_id: self.task_id,
                    offset: self.offset,
                    data: buffer[..read].to_vec(),
                };
                if self.cancel.load(Ordering::Relaxed) {
                    let _ = tx.blocking_send(ServerMessage::FileError {
                        request_id: 0,
                        task_id: self.task_id,
                        message: "下载已取消".into(),
                    });
                    return Ok(());
                }
                if tx.blocking_send(chunk).is_err() {
                    return Ok(());
                }
                self.offset += read as u64;
                if self.offset > self.size {
                    bail!("file grew while downloading");
                }
            }
            if read == 0 {
                if self.cancel.load(Ordering::Relaxed) {
                    let _ = tx.blocking_send(ServerMessage::FileError {
                        request_id: 0,
                        task_id: self.task_id,
                        message: "下载已取消".into(),
                    });
                    return Ok(());
                }
                let hash = hex::encode(self.hasher.finalize());
                let _ = tx.blocking_send(ServerMessage::FileDone {
                    task_id: self.task_id,
                    path: self.relative_path.clone(),
                    size: self.offset,
                    sha256: hash,
                });
                return Ok(());
            }
        }
    }
}

/// Commits the temporary upload. With `overwrite=false` the commit itself must
/// be an atomic no-replace operation; a pre-flight `exists()` check alone
/// races with other processes creating the target after the check.
fn commit_temp(temp: &Path, target: &Path, overwrite: bool) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MOVE_FILE_FLAGS,
        };

        let temp_wide: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
        let target_wide: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut bits = MOVEFILE_WRITE_THROUGH.0;
        if overwrite {
            bits |= MOVEFILE_REPLACE_EXISTING.0;
        }
        // Without REPLACE_EXISTING, MoveFileExW fails if the target appeared
        // after the pre-flight check; it never silently replaces it.
        unsafe {
            MoveFileExW(
                PCWSTR(temp_wide.as_ptr()),
                PCWSTR(target_wide.as_ptr()),
                MOVE_FILE_FLAGS(bits),
            )
            .context("atomic MoveFileExW commit")?;
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        if overwrite {
            return fs::rename(temp, target).context("atomic rename");
        }
        // link(2) fails with EEXIST instead of replacing; the target name is
        // then fully populated before it becomes visible.
        fs::hard_link(temp, target).context("atomic no-replace link")?;
        if let Err(error) = fs::remove_file(temp) {
            warn!(%error, "commit succeeded but temporary upload file remains");
        }
        Ok(())
    }
}

pub fn normalize_relative(input: &str) -> Result<String> {
    let cleaned = input.trim().replace('\\', "/");
    let mut parts = Vec::new();
    for part in cleaned.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            bail!("parent directory segments are not allowed");
        }
        if part.contains(':') || part.contains('\0') {
            bail!("invalid path segment");
        }
        parts.push(part);
    }
    Ok(parts.join("/"))
}

fn validate_leaf_name(name: &str) -> Result<()> {
    if name.is_empty() || name == "." || name == ".." {
        bail!("invalid file name");
    }
    if name.chars().any(|character| {
        matches!(character, '<' | '>' | ':' | '"' | '|' | '?' | '*' | '/')
            || character == '\\'
            || character.is_control()
    }) {
        bail!("file name contains characters unsupported on the Host");
    }
    if name.ends_with(' ') || name.ends_with('.') {
        bail!("file name ends with a space or dot");
    }
    Ok(())
}

fn join_relative(parent: &str, name: &str) -> String {
    let parent = parent.trim_matches('/');
    if parent.is_empty() {
        name.to_string()
    } else {
        format!("{parent}/{name}")
    }
}

fn relative_from_root(root: &Path, target: &Path) -> String {
    let relative = target.strip_prefix(root).unwrap_or(target);
    let mut parts = Vec::new();
    for component in relative.components() {
        if let Component::Normal(value) = component {
            parts.push(value.to_string_lossy().to_string());
        }
    }
    parts.join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server_with(files: &[(&str, &[u8])]) -> (tempfile::TempDir, FileServer) {
        let dir = tempfile::tempdir().unwrap();
        for (name, data) in files {
            let path = dir.path().join(name);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(path, data).unwrap();
        }
        let server = FileServer::new(dir.path()).unwrap();
        (dir, server)
    }

    #[test]
    fn normalizes_and_rejects_escape_paths() {
        assert_eq!(normalize_relative("/a//b/").unwrap(), "a/b");
        assert!(normalize_relative("../secret").is_err());
        assert!(normalize_relative("a/../../b").is_err());
        assert!(normalize_relative("C:/windows").is_err());
        assert!(normalize_relative(r"a\..\b").is_err());
    }

    #[test]
    fn lists_directories_without_symlinks() {
        let (_dir, server) = server_with(&[("hello.txt", b"hello"), ("sub/note.txt", b"note")]);
        let entries = server.list("").unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].name, "sub");
        assert!(entries[0].is_dir);
        assert_eq!(entries[1].name, "hello.txt");
        assert_eq!(entries[1].size, 5);
        let nested = server.list("sub").unwrap();
        assert_eq!(nested.len(), 1);
        assert_eq!(nested[0].path, "sub/note.txt");
    }

    #[test]
    fn upload_commits_after_size_and_hash() {
        let (dir, mut server) = server_with(&[]);
        server.begin_upload(7, "upload.bin", 6, false).unwrap();
        assert_eq!(server.write_upload_chunk(7, 0, b"abc").unwrap(), 3);
        assert!(server.write_upload_chunk(7, 1, b"bad").is_err());
        server.write_upload_chunk(7, 3, b"def").unwrap();
        let (path, size, hash) = server.finish_upload(7).unwrap();
        assert_eq!(path, "upload.bin");
        assert_eq!(size, 6);
        assert_eq!(fs::read(dir.path().join("upload.bin")).unwrap(), b"abcdef");
        assert_eq!(hash.len(), 64);
    }

    #[test]
    fn upload_refuses_existing_target_without_overwrite() {
        let (dir, mut server) = server_with(&[("exists.txt", b"old")]);
        assert!(server.begin_upload(1, "exists.txt", 3, false).is_err());
        server.begin_upload(2, "exists.txt", 3, true).unwrap();
        server.write_upload_chunk(2, 0, b"new").unwrap();
        server.finish_upload(2).unwrap();
        assert_eq!(fs::read(dir.path().join("exists.txt")).unwrap(), b"new");
    }

    #[test]
    fn rejects_uploads_outside_the_root() {
        let (_dir, mut server) = server_with(&[]);
        assert!(server.begin_upload(1, "../outside.txt", 1, false).is_err());
        assert!(server.list("..").is_err());
    }

    #[test]
    fn cancel_removes_temporary_upload() {
        let (dir, mut server) = server_with(&[]);
        server.begin_upload(3, "cancel.bin", 3, false).unwrap();
        server.write_upload_chunk(3, 0, b"a").unwrap();
        server.cancel_task(3);
        assert!(!dir.path().join(".yuanlian-upload-3.part").exists());
    }

    #[test]
    fn no_overwrite_rejects_target_created_after_begin() {
        let (dir, mut server) = server_with(&[]);
        server.begin_upload(11, "race.txt", 3, false).unwrap();
        // Another process creates the target between the pre-flight check and
        // the commit. The commit must fail and leave the new file untouched.
        fs::write(dir.path().join("race.txt"), b"theirs").unwrap();
        server.write_upload_chunk(11, 0, b"new").unwrap();
        assert!(server.finish_upload(11).is_err());
        assert_eq!(fs::read(dir.path().join("race.txt")).unwrap(), b"theirs");
        assert!(!dir.path().join(".yuanlian-upload-11.part").exists());
    }

    #[test]
    #[allow(clippy::permissions_set_readonly_false)]
    fn failed_overwrite_keeps_old_file_and_cleans_temp() {
        let (dir, mut server) = server_with(&[("keep.txt", b"old")]);
        server.begin_upload(12, "keep.txt", 3, true).unwrap();
        server.write_upload_chunk(12, 0, b"new").unwrap();
        // A read-only target makes the atomic replace fail. The old file must
        // still contain its original bytes and no .part file may be left.
        let target = dir.path().join("keep.txt");
        let mut permissions = fs::metadata(&target).unwrap().permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&target, permissions).unwrap();
        let result = server.finish_upload(12);
        #[cfg(windows)]
        {
            let mut permissions = fs::metadata(&target).unwrap().permissions();
            permissions.set_readonly(false);
            fs::set_permissions(&target, permissions).unwrap();
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&target, fs::Permissions::from_mode(0o644)).unwrap();
        }
        assert!(result.is_err(), "replace unexpectedly succeeded");
        assert_eq!(fs::read(&target).unwrap(), b"old");
        assert!(!dir.path().join(".yuanlian-upload-12.part").exists());
    }

    #[test]
    fn incomplete_upload_failure_removes_temp() {
        let (dir, mut server) = server_with(&[]);
        server.begin_upload(13, "short.bin", 10, false).unwrap();
        server.write_upload_chunk(13, 0, b"abc").unwrap();
        assert!(server.finish_upload(13).is_err());
        assert!(!dir.path().join(".yuanlian-upload-13.part").exists());
        assert!(!dir.path().join("short.bin").exists());
    }

    #[test]
    fn cancelled_download_has_terminal_error_and_no_done() {
        let payload = vec![0x5Au8; CHUNK_SIZE * 2];
        let (_dir, mut server) = server_with(&[("big.bin", &payload)]);
        let reader = server.take_download(21, "big.bin").unwrap();
        server.cancel_task(21);
        let (tx, mut rx) = mpsc::channel::<ServerMessage>(8);
        reader.stream(tx).unwrap();
        let mut messages = Vec::new();
        while let Ok(message) = rx.try_recv() {
            messages.push(message);
        }
        assert!(
            messages
                .iter()
                .any(|message| matches!(message, ServerMessage::FileError { task_id: 21, .. })),
            "cancelled download must report a terminal error: {messages:?}"
        );
        assert!(
            !messages
                .iter()
                .any(|message| matches!(message, ServerMessage::FileDone { .. })),
            "cancelled download must not report success"
        );
    }
}
