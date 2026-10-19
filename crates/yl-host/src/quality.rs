//! A private Sunshine instance exists only for one authorized control lease.
use crate::control::ControlPlane;
use anyhow::{bail, Context, Result};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};
use tokio::net::TcpStream;
use tokio_rustls::server::TlsStream;
use yl_proto::{read_message, write_message, ClientMessage, ErrorCode, ServerMessage};
use yl_runtime::OwnedProcess;

#[derive(Clone)]
pub struct QualityConfig {
    pub executable: PathBuf,
    pub bind: std::net::IpAddr,
    pub port: u16,
}

pub struct QualityHost {
    // Drop process before directory: the runtime must not retain certificate files.
    child: OwnedProcess,
    _directory: tempfile::TempDir,
    pub certificate: String,
    pub uuid: String,
}

impl QualityHost {
    pub fn start(
        config: &QualityConfig,
        certificate: &str,
        input: bool,
        live: impl Fn() -> bool,
    ) -> Result<Self> {
        if certificate.len() > 8192
            || !certificate.starts_with("-----BEGIN CERTIFICATE-----")
            || !certificate
                .trim_end()
                .ends_with("-----END CERTIFICATE-----")
            || certificate.contains("PRIVATE KEY")
        {
            bail!("invalid Moonlight public certificate");
        }
        if config.port < 1025 || config.port > 65000 {
            bail!("invalid quality base port");
        }
        yl_runtime::verify_component(&config.executable, "sunshine")?;
        let base = crate::tls::default_identity_directory()
            .parent()
            .context("identity parent")?
            .join("quality-sessions");
        std::fs::create_dir_all(&base)?;
        let directory = tempfile::Builder::new()
            .prefix("session-")
            .tempdir_in(base)?;
        let root = directory.path();
        // Unpredictable session identity and inaccessible WebUI credentials.
        let random = rcgen::KeyPair::generate()?.serialize_der();
        let seed = hex::encode(Sha256::digest(&random));
        let uuid = format!(
            "{}-{}-{}-{}-{}",
            &seed[..8],
            &seed[8..12],
            &seed[12..16],
            &seed[16..20],
            &seed[20..32]
        );
        let state = json!({"root": {"uniqueid": uuid, "named_devices": [{"name":"YuanLian ticket client", "uuid":uuid,"cert":certificate,"enabled":true}]},
            "username":"yuanlian-session", "salt":&seed[..16],
            "password":hex::encode(Sha256::digest([random.as_slice(),&seed.as_bytes()[..16]].concat()))});
        std::fs::write(root.join("state.json"), serde_json::to_vec(&state)?)?;
        std::fs::write(
            root.join("apps.json"),
            br#"{"env":{},"apps":[{"name":"Desktop","image-path":"","auto-detach":true}]}"#,
        )?;
        let local_path = |name: &str| -> Result<String> {
            let path = root.join(name).to_string_lossy().replace('\\', "/");
            if path.contains(['\n', '\r', '#']) {
                bail!("unsupported runtime path");
            }
            Ok(path)
        };
        let configuration = format!("sunshine_name = YuanLian authorized quality\nport = {}\nbind_address = {}\naddress_family = ipv4\nupnp = disabled\norigin_web_ui_allowed = pc\nlan_encryption_mode = 2\nwan_encryption_mode = 2\nkeyboard = {}\nmouse = {}\ncontroller = disabled\nnative_pen_touch = disabled\ndd_configuration_option = disabled\nmin_log_level = 6\nfile_state = {}\ncredentials_file = {}\nfile_apps = {}\ncert = {}\npkey = {}\nlog_path = {}\n", config.port, config.bind,
            if input {"enabled"} else {"disabled"}, if input {"enabled"} else {"disabled"},
            local_path("state.json")?,local_path("state.json")?,local_path("apps.json")?,
            local_path("host-cert.pem")?,local_path("host-key.pem")?,local_path("runtime.log")?);
        std::fs::write(root.join("sunshine.conf"), configuration)?;
        let cwd = config.executable.parent().context("Sunshine directory")?;
        if !live() {
            bail!("quality authorization ended before startup");
        }
        let child = OwnedProcess::start(
            &config.executable,
            &[root.join("sunshine.conf").to_string_lossy().into_owned()],
            cwd,
            false,
        )?;
        let mut host = Self {
            child,
            _directory: directory,
            certificate: String::new(),
            uuid,
        };
        let bind = if config.bind.is_unspecified() {
            "127.0.0.1".to_string()
        } else {
            config.bind.to_string()
        };
        let deadline = Instant::now() + Duration::from_secs(30);
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_millis(350))
            .build();
        while Instant::now() < deadline {
            if !live() {
                bail!("quality authorization ended during startup");
            }
            if let Some(code) = host.child.poll()? {
                bail!("dedicated Sunshine exited ({code})");
            }
            // Verify our unpredictable UUID, never accept a different process on the port.
            if let Ok(response) = agent
                .get(&format!("http://{bind}:{}/serverinfo", config.port))
                .call()
            {
                use std::io::Read;
                let mut data = String::new();
                response
                    .into_reader()
                    .take(32768)
                    .read_to_string(&mut data)?;
                if data.contains(&format!("<uniqueid>{}</uniqueid>", host.uuid)) {
                    host.certificate =
                        std::fs::read_to_string(host._directory.path().join("host-cert.pem"))?;
                    if host.certificate.len() > 8192 {
                        bail!("invalid Sunshine certificate size");
                    }
                    return Ok(host);
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        bail!("dedicated Sunshine readiness timed out")
    }
}

struct ReaderGuard {
    task: tokio::task::JoinHandle<()>,
    cancel: Arc<AtomicBool>,
}
impl Drop for ReaderGuard {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
        self.task.abort();
    }
}
#[allow(clippy::too_many_arguments)]
pub async fn serve(
    stream: TlsStream<TcpStream>,
    config: QualityConfig,
    certificate: String,
    control: Arc<ControlPlane>,
    session: String,
    expires: i64,
    permissions: u32,
    input_allowed: bool,
) -> Result<()> {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let cancel = Arc::new(AtomicBool::new(false));
    let read_cancel = cancel.clone();
    let (tx, mut rx) = tokio::sync::mpsc::channel(8);
    let task = tokio::spawn(async move {
        while let Ok(Ok(Some(message))) = tokio::time::timeout(
            Duration::from_secs(50),
            read_message::<_, ClientMessage>(&mut reader),
        )
        .await
        {
            if tx.send(message).await.is_err() {
                break;
            }
        }
        read_cancel.store(true, Ordering::Relaxed);
    });
    let _reader_guard = ReaderGuard {
        task,
        cancel: cancel.clone(),
    };
    let worker_control = control.clone();
    let worker_session = session.clone();
    let worker_cancel = cancel.clone();
    let port = config.port;
    let mut startup = tokio::task::spawn_blocking(move || {
        QualityHost::start(&config, &certificate, input_allowed, move || {
            !worker_cancel.load(Ordering::Relaxed)
                && !worker_control.session_revoked(&worker_session)
                && super::session::unix_now() < expires
        })
    });
    let mut host = loop {
        tokio::select! {
            result=&mut startup=>match result{
                Ok(Ok(host))=>break host,
                _=>{
                    let _=tokio::time::timeout(Duration::from_millis(500),write_message(&mut writer,&ServerMessage::Error{code:ErrorCode::Internal,message:"Dedicated Sunshine startup failed or authorization ended".into()})).await;
                    bail!("dedicated quality startup failed or authorization ended");
                }
            },
            message=rx.recv()=>match message{
                Some(ClientMessage::Ping{nonce})=>{tokio::time::timeout(Duration::from_millis(500),write_message(&mut writer,&ServerMessage::Pong{nonce})).await??;},
                _=>bail!("quality client ended during startup"),
            },
        }
    };
    if control.session_revoked(&session) || super::session::unix_now() >= expires {
        bail!("quality authorization ended during startup");
    }
    tokio::time::timeout(
        Duration::from_millis(500),
        write_message(
            &mut writer,
            &ServerMessage::QualityReady {
                port,
                server_certificate: host.certificate.clone(),
                server_uuid: host.uuid.clone(),
                permissions,
                input_allowed,
            },
        ),
    )
    .await??;
    let mut timer = tokio::time::interval(Duration::from_millis(100));
    let mut last_client = Instant::now();
    let reason = loop {
        tokio::select! {
            message=rx.recv()=>match message{
                Some(ClientMessage::Ping{nonce})=>{
                    last_client=Instant::now();
                    if !matches!(tokio::time::timeout(Duration::from_millis(500),write_message(&mut writer,&ServerMessage::Pong{nonce})).await,Ok(Ok(()))){break "client_disconnected";}
                },
                Some(ClientMessage::Bye)|None=>break "client_disconnected",
                _=>break "bad_message",
            },
            _=timer.tick()=>{
                if control.session_revoked(&session){break "revoked";}
                if super::session::unix_now()>=expires{break "ticket_expired";}
                if last_client.elapsed()>Duration::from_secs(12){break "client_heartbeat_lost";}
                if !matches!(host.child.poll(),Ok(None)){break "quality_process_ended";}
            }
        }
    };
    drop(host);
    control.report_end(&session, reason);
    let _ = tokio::time::timeout(
        Duration::from_millis(500),
        write_message(
            &mut writer,
            &ServerMessage::Error {
                code: ErrorCode::Revoked,
                message: reason.into(),
            },
        ),
    )
    .await;
    Ok(())
}
