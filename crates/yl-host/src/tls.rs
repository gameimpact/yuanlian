//! Persistent TLS identity for the Host.
//!
//! The self-signed certificate and its private key are generated once and
//! stored in the Host identity directory. Restarting the Host must not change
//! its certificate fingerprint or device id, because pairing, grants and
//! session tickets are bound to them. The private key is never logged.
//!
//! This is still a self-signed, certificate-pinned trust model; it is not a
//! public CA identity. The certificate is public, the key file is private.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use rcgen::{CertificateParams, DnType, IsCa, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;

use yl_proto::{cert_fingerprint_hex, parse_fingerprint, ALPN, TLS_SERVER_NAME};

const CERT_FILE: &str = "host-cert.der";
const KEY_FILE: &str = "host-key.der";

pub struct TlsIdentity {
    pub config: Arc<ServerConfig>,
    pub fingerprint: [u8; 32],
}

/// Loads the certificate/key pair from `directory`, generating both only when
/// neither exists. A half-present identity is an error rather than a silent
/// regeneration, because changing the identity would orphan pairings.
pub fn load_or_create_identity(directory: &Path) -> Result<TlsIdentity> {
    fs::create_dir_all(directory)
        .with_context(|| format!("create identity directory {}", directory.display()))?;
    let cert_path = directory.join(CERT_FILE);
    let key_path = directory.join(KEY_FILE);
    let cert_exists = cert_path.exists();
    let key_exists = key_path.exists();
    if cert_exists != key_exists {
        bail!(
            "incomplete TLS identity in {}: certificate and key must both exist or both be absent",
            directory.display()
        );
    }
    let (cert_der, key_der) = if cert_exists {
        let cert = fs::read(&cert_path).with_context(|| format!("read {}", cert_path.display()))?;
        let key = fs::read(&key_path).with_context(|| format!("read {}", key_path.display()))?;
        (cert, key)
    } else {
        let (cert, key) = generate_material()?;
        write_identity_files(&cert_path, &key_path, &cert, &key)?;
        (cert, key)
    };
    build_identity(cert_der, key_der)
}

fn write_identity_files(cert_path: &Path, key_path: &Path, cert: &[u8], key: &[u8]) -> Result<()> {
    // `create_new` refuses to clobber a concurrent enrollment; the private key
    // is written with owner-only permissions where the platform supports it.
    let mut key_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(key_path)
        .with_context(|| format!("create private key {}", key_path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = key_file.set_permissions(fs::Permissions::from_mode(0o600));
    }
    let result = (|| -> Result<()> {
        key_file.write_all(key)?;
        key_file.sync_all()?;
        drop(key_file);
        let mut cert_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(cert_path)
            .with_context(|| format!("create certificate {}", cert_path.display()))?;
        cert_file.write_all(cert)?;
        cert_file.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(key_path);
        let _ = fs::remove_file(cert_path);
    }
    result
}

fn generate_material() -> Result<(Vec<u8>, Vec<u8>)> {
    let key_pair = KeyPair::generate().context("generate TLS key pair")?;
    let mut params = CertificateParams::new(vec![TLS_SERVER_NAME.to_owned()])
        .context("build certificate parameters")?;
    params
        .distinguished_name
        .push(DnType::CommonName, "YuanLian Host");
    params.is_ca = IsCa::NoCa;
    let certificate = params
        .self_signed(&key_pair)
        .context("self-sign certificate")?;
    Ok((certificate.der().to_vec(), key_pair.serialize_der()))
}

fn build_identity(cert_der: Vec<u8>, key_der: Vec<u8>) -> Result<TlsIdentity> {
    let cert_der = CertificateDer::from(cert_der);
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der));
    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert_der.clone()], key_der)
        .context("build TLS server configuration")?;
    config.alpn_protocols = vec![ALPN.to_vec()];
    let fingerprint = parse_fingerprint(&cert_fingerprint_hex(cert_der.as_ref()))
        .expect("64 hex characters always parse");
    Ok(TlsIdentity {
        config: Arc::new(config),
        fingerprint,
    })
}

/// Default identity location on Windows. It is user-scoped so the Host does
/// not need administrative rights just to keep a stable identity.
pub fn default_identity_directory() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .or_else(|| std::env::var_os("APPDATA"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("YuanLian").join("identity")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_is_stable_across_restarts() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let dir = tempfile::tempdir().unwrap();
        let first = load_or_create_identity(dir.path()).unwrap();
        let second = load_or_create_identity(dir.path()).unwrap();
        assert_eq!(first.fingerprint, second.fingerprint);
        assert_eq!(
            cert_fingerprint_hex(&first.fingerprint),
            cert_fingerprint_hex(&second.fingerprint)
        );
        assert!(dir.path().join(CERT_FILE).exists());
        assert!(dir.path().join(KEY_FILE).exists());
    }

    #[test]
    fn incomplete_identity_is_reported_not_regenerated() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join(CERT_FILE), b"not a certificate").unwrap();
        let error = match load_or_create_identity(dir.path()) {
            Ok(_) => panic!("incomplete identity unexpectedly loaded"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("incomplete"), "{error}");
    }
}
