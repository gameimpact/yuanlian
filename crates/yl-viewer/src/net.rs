//! TLS client and message pump for the native viewer.
//!
//! The Host certificate is pinned by SHA-256 fingerprint. Handshake
//! signatures are still verified with rustls' ring provider, so pinning does
//! not disable certificate proof-of-possession.

use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, SignatureScheme};
use sha2::{Digest, Sha256};
use tokio::io::split;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_rustls::TlsConnector;
use tracing::{debug, info, warn};

use yl_proto::{
    read_message, write_message, ClientHello, ClientMessage, CursorState, ErrorCode, FrameMessage,
    ServerMessage, Welcome, ALPN, PROTOCOL_VERSION, TLS_SERVER_NAME,
};

#[derive(Debug)]
pub enum NetEvent {
    Welcome(Welcome),
    Frame(FrameMessage),
    Cursor(CursorState),
    Error(ErrorCode, String),
    Disconnected(String),
}

pub struct NetHandle {
    pub outbound: mpsc::UnboundedSender<ClientMessage>,
    pub _thread: JoinHandle<()>,
}

/// Starts the network thread. It performs the TLS handshake and waits for the
/// Welcome message before any frames are forwarded.
pub struct SessionAuth {
    pub ticket: Option<String>,
    pub nonce: String,
}

pub fn spawn_connection(
    address: String,
    fingerprint: [u8; 32],
    client_name: String,
    auth: SessionAuth,
) -> Result<(Receiver<NetEvent>, NetHandle)> {
    let (event_tx, event_rx) = std::sync::mpsc::channel();
    let (outbound, outbound_rx) = mpsc::unbounded_channel();
    let ping_tx = outbound.clone();
    let thread = std::thread::Builder::new()
        .name("yl-viewer-net".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    let _ = event_tx.send(NetEvent::Disconnected(format!(
                        "failed to build network runtime: {error}"
                    )));
                    return;
                }
            };
            if let Err(error) = runtime.block_on(net_main(
                address,
                fingerprint,
                client_name,
                auth,
                event_tx.clone(),
                outbound_rx,
                ping_tx,
            )) {
                let _ = event_tx.send(NetEvent::Disconnected(format!("{error:#}")));
            }
        })
        .context("spawn network thread")?;
    Ok((
        event_rx,
        NetHandle {
            outbound,
            _thread: thread,
        },
    ))
}

async fn net_main(
    address: String,
    fingerprint: [u8; 32],
    client_name: String,
    auth: SessionAuth,
    events: Sender<NetEvent>,
    outbound_rx: mpsc::UnboundedReceiver<ClientMessage>,
    ping_tx: mpsc::UnboundedSender<ClientMessage>,
) -> Result<()> {
    let tcp = TcpStream::connect(&address)
        .await
        .with_context(|| format!("connect to {address}"))?;
    tcp.set_nodelay(true)?;

    let config = client_config(fingerprint)?;
    let connector = TlsConnector::from(config);
    let server_name = ServerName::try_from(TLS_SERVER_NAME.to_string())?.to_owned();
    let tls = tokio::time::timeout(Duration::from_secs(10), connector.connect(server_name, tcp))
        .await
        .context("TLS handshake timed out")?
        .context("TLS handshake failed")?;
    if tls.get_ref().1.alpn_protocol() != Some(ALPN) {
        bail!(
            "Host did not negotiate ALPN {}",
            String::from_utf8_lossy(ALPN)
        );
    }
    info!(%address, "TLS connected, certificate fingerprint pinned");

    let (mut reader, mut writer) = split(tls);
    let hello = ClientMessage::Hello(ClientHello {
        protocol_version: PROTOCOL_VERSION,
        client_name,
        client_id: format!(
            "{}-{}",
            std::env::var("COMPUTERNAME").unwrap_or_else(|_| "viewer".into()),
            std::process::id()
        ),
        request_input: true,
        features: if auth.ticket.is_some() {
            yl_proto::FEATURE_SESSION_TICKET
        } else {
            0
        },
        session_ticket: auth.ticket,
        session_nonce: auth.nonce,
    });
    write_message(&mut writer, &hello).await?;

    let welcome = match tokio::time::timeout(
        Duration::from_secs(10),
        read_message::<_, ServerMessage>(&mut reader),
    )
    .await
    {
        Err(_) => bail!("timed out waiting for Welcome"),
        Ok(Err(error)) => return Err(error.context("read Welcome")),
        Ok(Ok(None)) => bail!("Host closed the connection before Welcome"),
        Ok(Ok(Some(ServerMessage::Welcome(welcome)))) => welcome,
        Ok(Ok(Some(ServerMessage::Error { code, message }))) => {
            bail!("Host rejected the connection [{:?}]: {message}", code)
        }
        Ok(Ok(Some(_))) => bail!("Host sent a non-Welcome message before Welcome"),
    };
    if welcome.protocol_version != PROTOCOL_VERSION {
        bail!(
            "protocol mismatch: Host {}, viewer {}",
            welcome.protocol_version,
            PROTOCOL_VERSION
        );
    }
    events
        .send(NetEvent::Welcome(welcome))
        .map_err(|_| anyhow::anyhow!("viewer UI closed"))?;

    let writer_task = tokio::spawn(async move {
        let mut outbound_rx = outbound_rx;
        while let Some(message) = outbound_rx.recv().await {
            write_message(&mut writer, &message).await?;
        }
        Ok::<(), anyhow::Error>(())
    });

    let (in_tx, mut in_rx) = mpsc::channel::<Result<ServerMessage, String>>(32);
    let reader_task = tokio::spawn(async move {
        loop {
            match read_message::<_, ServerMessage>(&mut reader).await {
                Ok(Some(message)) => {
                    if in_tx.send(Ok(message)).await.is_err() {
                        break;
                    }
                }
                Ok(None) => {
                    let _ = in_tx.send(Err("Host closed the connection".into())).await;
                    break;
                }
                Err(error) => {
                    let _ = in_tx.send(Err(format!("{error:#}"))).await;
                    break;
                }
            }
        }
    });

    let mut heartbeat = tokio::time::interval(Duration::from_secs(5));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    heartbeat.tick().await;
    let mut last_activity = Instant::now();
    let mut nonce = 0u64;
    let mut ended = false;

    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                if last_activity.elapsed() > Duration::from_secs(30) {
                    let _ = events.send(NetEvent::Disconnected("heartbeat timeout (30 s)".into()));
                    ended = true;
                    break;
                }
                nonce = nonce.wrapping_add(1);
                if ping_tx.send(ClientMessage::Ping { nonce }).is_err() {
                    break;
                }
            }
            message = in_rx.recv() => {
                match message {
                    Some(Ok(ServerMessage::Frame(frame))) => {
                        last_activity = Instant::now();
                        if events.send(NetEvent::Frame(frame)).is_err() {
                            break;
                        }
                    }
                    Some(Ok(ServerMessage::Cursor(cursor))) => {
                        last_activity = Instant::now();
                        if events.send(NetEvent::Cursor(cursor)).is_err() {
                            break;
                        }
                    }
                    Some(Ok(ServerMessage::Error { code, message })) => {
                        last_activity = Instant::now();
                        warn!(?code, %message, "Host reported an error");
                        if events.send(NetEvent::Error(code, message)).is_err() {
                            break;
                        }
                    }
                    Some(Ok(ServerMessage::Pong { nonce: _ })) => {
                        last_activity = Instant::now();
                    }
                    Some(Ok(ServerMessage::Bye { reason })) => {
                        let _ = events.send(NetEvent::Disconnected(format!("Host ended the session: {reason}")));
                        ended = true;
                        break;
                    }
                    Some(Ok(ServerMessage::Welcome(_))) => {
                        let _ = events.send(NetEvent::Disconnected("duplicate Welcome".into()));
                        ended = true;
                        break;
                    }
                    Some(Ok(_)) => {
                        // File/capability messages are ignored by the M0 viewer.
                    }
                    Some(Err(error)) => {
                        let _ = events.send(NetEvent::Disconnected(error));
                        ended = true;
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    reader_task.abort();
    writer_task.abort();
    if !ended {
        let _ = events.send(NetEvent::Disconnected("connection closed".into()));
    }
    debug!("network thread finished");
    Ok(())
}

fn client_config(fingerprint: [u8; 32]) -> Result<Arc<ClientConfig>> {
    let mut config = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedVerifier { fingerprint }))
        .with_no_client_auth();
    config.alpn_protocols = vec![ALPN.to_vec()];
    Ok(Arc::new(config))
}

#[derive(Debug)]
struct PinnedVerifier {
    fingerprint: [u8; 32],
}

impl ServerCertVerifier for PinnedVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let digest = Sha256::digest(end_entity.as_ref());
        if digest.as_slice() == self.fingerprint {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General(
                "Host certificate fingerprint mismatch".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
