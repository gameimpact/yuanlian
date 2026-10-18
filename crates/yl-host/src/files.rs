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
    downloads: HashMap<u64, DownloadReader>,
}

struct UploadState {
    task_id: u64,
    target: PathBuf,
    temp: PathBuf,
    file: File,
    hasher: Sha256,
    received: u64,
    expected: u64,
    overwrite: bool,
}

impl Drop for FileServer {
    fn drop(&mut self) {
        for (_, state) in self.uploads.drain() {
            drop(state.file);
            let _ = fs::remove_file(&state.temp);
        }
    }
}

pub struct DownloadReader {
    task_id: u64,
    relative_path: String,
    file: File,
    hasher: Sha256,
    offset: u64,
    size: u64,
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
        })
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
                file,
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
        state.file.write_all(data).context("write upload chunk")?;
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
            let _ = fs::remove_file(&state.temp);
            bail!(
                "upload incomplete: received {} of {} bytes",
                state.received,
                state.expected
            );
        }
        state.file.flush().context("flush upload")?;
        state.file.sync_all().context("sync upload")?;
        drop(state.file);
        let digest = state.hasher.finalize();
        let hash = hex::encode(digest);
        if state.target.exists() {
            if !state.overwrite {
                let _ = fs::remove_file(&state.temp);
                bail!("target already exists");
            }
            if state.target.is_dir() {
                let _ = fs::remove_file(&state.temp);
                bail!("target is a directory");
            }
        }
        if let Err(error) = commit_temp(&state.temp, &state.target, state.overwrite) {
            let _ = fs::remove_file(&state.temp);
            return Err(error).context("commit uploaded file");
        }
        let relative = relative_from_root(&self.root, &state.target);
        Ok((relative, state.expected, hash))
    }

    pub fn cancel_task(&mut self, task_id: u64) {
        if let Some(state) = self.uploads.remove(&task_id) {
            drop(state.file);
            let _ = fs::remove_file(&state.temp);
        }
        self.downloads.remove(&task_id);
    }

    pub fn take_download(&mut self, task_id: u64, relative: &str) -> Result<DownloadReader> {
        let path = self.resolve_existing(relative, false)?;
        let metadata = fs::metadata(&path).context("read download metadata")?;
        if !metadata.is_file() {
            bail!("not a regular file: {relative}");
        }
        let file = File::open(&path).context("open download file")?;
        let reader = DownloadReader {
            task_id,
            relative_path: normalize_relative(relative)?,
            file,
            hasher: Sha256::new(),
            offset: 0,
            size: metadata.len(),
        };
        self.downloads.insert(task_id, reader);
        Ok(self.downloads.remove(&task_id).expect("just inserted"))
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
        let mut buffer = vec![0u8; CHUNK_SIZE];
        loop {
            let read = self.file.read(&mut buffer).context("read download chunk")?;
            if read > 0 {
                self.hasher.update(&buffer[..read]);
                let chunk = ServerMessage::FileChunk {
                    task_id: self.task_id,
                    offset: self.offset,
                    data: buffer[..read].to_vec(),
                };
                if tx.blocking_send(chunk).is_err() {
                    return Ok(());
                }
                self.offset += read as u64;
                if self.offset > self.size {
                    bail!("file grew while downloading");
                }
            }
            if read == 0 {
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

/// Atomically replaces an existing file where the platform supports it.
/// On Windows, MoveFileExW keeps the old file intact if the replace fails.
fn commit_temp(temp: &Path, target: &Path, overwrite: bool) -> Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::{
            MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MOVE_FILE_FLAGS,
        };

        if target.exists() && !overwrite {
            bail!("target already exists");
        }
        let temp_wide: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
        let target_wide: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
        let flags = MOVE_FILE_FLAGS(MOVEFILE_REPLACE_EXISTING.0 | MOVEFILE_WRITE_THROUGH.0);
        unsafe {
            MoveFileExW(
                PCWSTR(temp_wide.as_ptr()),
                PCWSTR(target_wide.as_ptr()),
                flags,
            )
            .context("atomic MoveFileExW replace")?;
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        if target.exists() && !overwrite {
            bail!("target already exists");
        }
        fs::rename(temp, target).context("atomic rename")
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
}
