//! Owned Windows processes and fixed upstream component verification.
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::path::Path;

#[cfg(windows)]
mod process {
    use super::*;
    use std::ffi::{c_void, OsStr};
    use std::os::windows::ffi::OsStrExt;
    unsafe extern "C" {
        fn yl_process_start(
            exe: *const u16,
            args: *const *const u16,
            count: usize,
            cwd: *const u16,
            capture: bool,
            error: *mut u32,
        ) -> *mut c_void;
        fn yl_process_poll(process: *mut c_void, code: *mut u32, error: *mut u32) -> i32;
        fn yl_process_output(process: *mut c_void, size: *mut usize) -> *const u8;
        fn yl_process_free(process: *mut c_void);
        fn yl_process_close(process: *mut c_void);
        fn yl_process_pid(process: *mut c_void) -> u32;
    }
    pub struct OwnedProcess(*mut c_void);
    // Ownership never shared; the C++ process/Job handles are not thread-affine.
    unsafe impl Send for OwnedProcess {}
    fn wide(value: &OsStr) -> Result<Vec<u16>> {
        let mut value: Vec<_> = value.encode_wide().collect();
        if value.contains(&0) {
            bail!("NUL in process argument");
        }
        value.push(0);
        Ok(value)
    }
    impl OwnedProcess {
        pub fn pid(&self) -> u32 {
            unsafe { yl_process_pid(self.0) }
        }
        pub fn request_close(&self) {
            unsafe {
                yl_process_close(self.0);
            }
        }
        pub fn start(exe: &Path, args: &[String], cwd: &Path, capture: bool) -> Result<Self> {
            let exe = wide(exe.as_os_str())?;
            let cwd = wide(cwd.as_os_str())?;
            let args = args
                .iter()
                .map(|s| wide(OsStr::new(s)))
                .collect::<Result<Vec<_>>>()?;
            let pointers: Vec<_> = args.iter().map(|s| s.as_ptr()).collect();
            let mut error = 0;
            let process = unsafe {
                yl_process_start(
                    exe.as_ptr(),
                    pointers.as_ptr(),
                    pointers.len(),
                    cwd.as_ptr(),
                    capture,
                    &mut error,
                )
            };
            if process.is_null() {
                bail!("owned process creation failed: Windows {error}");
            }
            Ok(Self(process))
        }
        pub fn poll(&mut self) -> Result<Option<u32>> {
            let (mut code, mut error) = (0, 0);
            let running = unsafe { yl_process_poll(self.0, &mut code, &mut error) } != 0;
            if error != 0 {
                bail!("owned process poll failed: Windows {error}");
            }
            Ok(if running { None } else { Some(code) })
        }
        pub fn output(&self) -> Vec<u8> {
            let mut size = 0;
            let data = unsafe { yl_process_output(self.0, &mut size) };
            unsafe { std::slice::from_raw_parts(data, size) }.to_vec()
        }
    }
    impl Drop for OwnedProcess {
        fn drop(&mut self) {
            unsafe {
                yl_process_free(self.0);
            }
        }
    }
}
#[cfg(windows)]
pub use process::OwnedProcess;

pub fn verify_component(exe: &Path, component: &str) -> Result<()> {
    let source = match component {
        "moonlight" => include_str!("../../../client/assets/quality/moonlight-6.2.0.json"),
        "sunshine" => include_str!("../../../client/assets/quality/sunshine-2026.914.233613.json"),
        _ => bail!("unknown component"),
    };
    let manifest: serde_json::Value = serde_json::from_str(source)?;
    let root = exe
        .parent()
        .context("component root missing")?
        .canonicalize()?;
    let expected_exe = if component == "moonlight" {
        "Moonlight.exe"
    } else {
        "sunshine.exe"
    };
    if !exe
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case(expected_exe))
    {
        bail!("unexpected component executable");
    }
    let mut expected = std::collections::HashSet::new();
    for row in manifest["files"]
        .as_array()
        .context("invalid embedded manifest")?
    {
        let name = row["path"].as_str().context("invalid manifest path")?;
        let file = root.join(name);
        if name.contains(['\\', ':']) || name.split('/').any(|p| p.is_empty() || p == "..") {
            bail!("unsafe manifest path");
        }
        expected.insert(name.to_lowercase());
        let meta = std::fs::symlink_metadata(&file).context("component file missing")?;
        if meta.file_type().is_symlink()
            || !meta.is_file()
            || meta.len() != row["size"].as_u64().unwrap_or(u64::MAX)
            || !file.canonicalize()?.starts_with(&root)
        {
            bail!("component integrity failed");
        }
        let mut reader = std::fs::File::open(file)?;
        let mut digest = Sha256::new();
        std::io::copy(&mut reader, &mut digest)?;
        if hex::encode(digest.finalize()) != row["sha256"].as_str().unwrap_or("") {
            bail!("component digest mismatch");
        }
    }
    let mut pending = vec![root.clone()];
    let mut count = 0;
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            count += 1;
            if count > 4096 {
                bail!("component tree limit");
            }
            let path = entry.path();
            let meta = entry.metadata()?;
            if entry.file_type()?.is_symlink() || !path.canonicalize()?.starts_with(&root) {
                bail!("component link rejected");
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if meta.file_attributes() & 0x400 != 0 {
                    bail!("component reparse point rejected");
                }
            }
            if meta.is_dir() {
                pending.push(path);
                continue;
            }
            let relative = path
                .strip_prefix(&root)?
                .to_string_lossy()
                .replace('\\', "/")
                .to_lowercase();
            // Only known upstream runtime state may coexist; never read it.
            let state = relative == "moonlight.ini"
                || relative == "moonlight game streaming project/moonlight.ini"
                || relative == "moonlight.log"
                || (relative.starts_with("moonlight-") && relative.ends_with(".log"))
                || (component == "sunshine"
                    && relative.starts_with("config/")
                    && !relative.ends_with(".dll")
                    && !relative.ends_with(".exe"));
            if !expected.contains(&relative) && !state {
                bail!("unexpected component file");
            }
        }
    }
    Ok(())
}

/// QSettings IniFormat QByteArray. Only PEM (public cert or local key) is accepted.
pub fn qt_bytes(pem: &str) -> String {
    format!(
        "@ByteArray({})",
        pem.replace('\\', "\\\\")
            .replace('\r', "\\r")
            .replace('\n', "\\n")
            .replace(')', "\\)")
    )
}
pub fn public_certificate(ini: &Path) -> Result<String> {
    use std::io::BufRead;
    if std::fs::metadata(ini)?.len() > 65536 {
        bail!("Moonlight identity exceeds limit");
    }
    for line in std::io::BufReader::new(std::fs::File::open(ini)?).lines() {
        let line = line?;
        if let Some(value) = line.strip_prefix("certificate=") {
            let value = value
                .trim_matches('"')
                .strip_prefix("@ByteArray(")
                .and_then(|v| v.strip_suffix(')'))
                .context("unsupported public certificate format")?;
            let cert = value
                .replace("\\r", "\r")
                .replace("\\n", "\n")
                .replace("\\)", ")");
            if cert.len() > 8192
                || !cert.starts_with("-----BEGIN CERTIFICATE-----")
                || !cert.contains("-----END CERTIFICATE-----")
            {
                bail!("invalid public certificate");
            }
            return Ok(cert);
        }
    }
    bail!("Moonlight has not generated a public identity")
}
