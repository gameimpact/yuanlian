//! TLS identity for the development Host.
//!
//! A fresh self-signed certificate is generated at every launch. The Host
//! prints its SHA-256 fingerprint; the viewer pins that fingerprint. This is a
//! development trust-on-first-use scheme, not the final device pairing design.

use std::sync::Arc;

use anyhow::{Context, Result};
use rcgen::{CertificateParams, DnType, IsCa, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;

use yl_proto::{cert_fingerprint_hex, parse_fingerprint, ALPN, TLS_SERVER_NAME};

pub struct TlsIdentity {
    pub config: Arc<ServerConfig>,
    pub fingerprint: [u8; 32],
}

pub fn generate_identity() -> Result<TlsIdentity> {
    let key_pair = KeyPair::generate().context("generate TLS key pair")?;
    let mut params = CertificateParams::new(vec![TLS_SERVER_NAME.to_owned()])
        .context("build certificate parameters")?;
    params
        .distinguished_name
        .push(DnType::CommonName, "YuanLian Development Host");
    params.is_ca = IsCa::NoCa;
    let certificate = params
        .self_signed(&key_pair)
        .context("self-sign certificate")?;

    let cert_der = CertificateDer::from(certificate.der().to_vec());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_pair.serialize_der()));

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
