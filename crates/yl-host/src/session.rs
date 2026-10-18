//! One viewer connection: TLS handshake, ticket/local authorization, capture,
//! input and file routes.
//!
//! Authorization is the intersection of three independent decisions:
//! 1. the control-plane ticket (account, device, nonce, permissions, expiry),
//! 2. the Host's local policy (`--allow-input`, `--file-root`, read-only),
//! 3. the person at the Host accepting the connection.
//!
//! A missing component denies. Tickets are verified offline against the
//! server's announced Ed25519 keys; the Host still reports the session so the
//! control plane can revoke it.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{bail, Context, Result};
use tokio::io::AsyncWrite;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_rustls::server::TlsStream;
use tracing::{debug, info, warn};

use yl_proto::auth::{SessionClaims, TicketError};
use yl_proto::{
    permission_summary, read_message, write_message, ClientMessage, ErrorCode, ServerMessage,
    Welcome, PERMISSION_CONTROL, PERMISSION_FILE_READ, PERMISSION_FILE_WRITE, PERMISSION_VIEW,
    PROTOCOL_VERSION,
};
use yl_tiles::TileSettings;

use crate::approval;
use crate::capture::{self, CaptureOptions};
use crate::control::{local_permissions, ControlPlane};
use crate::files::FileServer;
use crate::input::{InputInjector, ScreenGeometry};

#[derive(Clone)]
pub struct HostConfig {
    pub host_id: String,
    pub host_name: String,
    pub monitor: usize,
    pub allow_input: bool,
    pub fps: u32,
    pub tile_settings: TileSettings,
    pub file_root: Option<PathBuf>,
    pub file_read_only: bool,
    pub allow_anonymous: bool,
    pub auto_approve: bool,
    pub control_plane: Option<Arc<ControlPlane>>,
}

struct Authorization {
    authenticated: bool,
    account: Option<String>,
    permissions: u32,
    session_id: String,
    ticket_expires_at: i64,
    auth_mode: String,
    claims: Option<SessionClaims>,
}

pub async fn run_session(
    stream: TlsStream<TcpStream>,
    peer: SocketAddr,
    config: HostConfig,
) -> Result<()> {
    let (mut reader, mut writer) = tokio::io::split(stream);

    let hello = match timeout(
        Duration::from_secs(10),
        read_message::<_, ClientMessage>(&mut reader),
    )
    .await
    {
        Ok(Ok(Some(ClientMessage::Hello(hello)))) => hello,
        Ok(Ok(Some(_))) => {
            reject(
                &mut writer,
                ErrorCode::BadMessage,
                "expected ClientHello as the first message",
            )
            .await?;
            unreachable!()
        }
        Ok(Ok(None)) => bail!("viewer disconnected before ClientHello"),
        Ok(Err(error)) => return Err(error.context("read ClientHello")),
        Err(_) => bail!("timed out waiting for ClientHello"),
    };

    if hello.protocol_version != PROTOCOL_VERSION {
        let message = format!(
            "Host speaks protocol {PROTOCOL_VERSION}, viewer speaks {}",
            hello.protocol_version
        );
        reject(&mut writer, ErrorCode::ProtocolVersion, &message).await?;
        unreachable!()
    }

    let local = local_permissions(
        config.allow_input,
        config.file_root.is_some(),
        config.file_read_only,
    );
    let auth = match authorize(&hello, &config, local) {
        Ok(auth) => auth,
        Err((code, message)) => {
            reject(&mut writer, code, &message).await?;
            unreachable!()
        }
    };

    if !config.auto_approve {
        let account = auth.account.clone();
        let permissions = auth.permissions;
        let approved = tokio::task::spawn_blocking(move || {
            approval::request(peer, account.as_deref(), permissions)
        })
        .await
        .unwrap_or(false);
        if !approved {
            reject(
                &mut writer,
                ErrorCode::Unauthorized,
                "本机用户拒绝了此次连接",
            )
            .await?;
            unreachable!()
        }
    } else {
        warn!("--auto-approve is enabled: local authorization dialog is skipped");
    }

    let input_allowed = hello.request_input && auth.permissions & PERMISSION_CONTROL != 0;
    if let (Some(control), Some(claims)) = (config.control_plane.as_ref(), auth.claims.as_ref()) {
        // Re-check after the local dialog: the account may have been disabled,
        // the device revoked or the ticket expired while the user decided.
        let status = {
            let control = Arc::clone(control);
            let jti = claims.jti.clone();
            tokio::task::spawn_blocking(move || control.check_ticket(&jti)).await
        };
        let status = match status {
            Ok(Ok(status)) => status,
            Ok(Err(error)) => {
                reject(
                    &mut writer,
                    ErrorCode::Internal,
                    &format!("控制面票据校验失败，拒绝开放会话：{error:#}"),
                )
                .await?;
                unreachable!()
            }
            Err(error) => {
                reject(
                    &mut writer,
                    ErrorCode::Internal,
                    &format!("控制面票据校验任务失败：{error}"),
                )
                .await?;
                unreachable!()
            }
        };
        if !status.valid {
            let code = match status.reason.as_str() {
                "ticket_expired" => ErrorCode::TicketExpired,
                "ticket_revoked" | "user_disabled" | "device_revoked" | "owner_disabled"
                | "grant_missing" | "grant_reduced" | "grant_expired" => ErrorCode::Revoked,
                "ticket_already_started" => ErrorCode::TicketReplay,
                _ => ErrorCode::Unauthorized,
            };
            reject(
                &mut writer,
                code,
                &format!("会话票据当前不可用：{}", status.reason),
            )
            .await?;
            unreachable!()
        }
        // The control-plane start confirmation is a prerequisite for opening
        // capture/input/files. A failure is fail-closed, not a logged warning.
        let started = {
            let control = Arc::clone(control);
            let claims = claims.clone();
            let permissions = auth.permissions;
            let request_input = hello.request_input;
            tokio::task::spawn_blocking(move || {
                control.report_start(&claims, permissions, request_input, input_allowed)
            })
            .await
        };
        if let Err(error) = match started {
            Ok(result) => result,
            Err(error) => Err(anyhow::anyhow!("start report task failed: {error}")),
        } {
            let code = if error.to_string().contains("revoked") {
                ErrorCode::Revoked
            } else {
                ErrorCode::Unauthorized
            };
            reject(
                &mut writer,
                code,
                &format!("控制面未确认会话开始，拒绝开放业务：{error:#}"),
            )
            .await?;
            unreachable!()
        }
    }
    let info = capture::monitor_info(config.monitor)?;
    if hello.request_input && !input_allowed {
        warn!(
            peer = %peer,
            "viewer requested input but the effective permissions do not include control"
        );
    }
    let welcome = Welcome {
        protocol_version: PROTOCOL_VERSION,
        host_id: config.host_id.clone(),
        host_name: config.host_name.clone(),
        screen_width: info.width,
        screen_height: info.height,
        input_allowed,
        mode: "tiles".into(),
        tile_size: config.tile_settings.tile_size,
        authenticated: auth.authenticated,
        account: auth.account.clone().unwrap_or_default(),
        permissions: auth.permissions,
        auth_mode: auth.auth_mode.clone(),
        session_id: auth.session_id.clone(),
        ticket_expires_at: auth.ticket_expires_at,
    };
    write_message(&mut writer, &ServerMessage::Welcome(welcome)).await?;

    let file_read = auth.permissions & PERMISSION_FILE_READ != 0;
    let file_write = auth.permissions & PERMISSION_FILE_WRITE != 0;
    let mut files = match config.file_root.as_ref() {
        Some(root) if file_read || file_write => {
            Some(FileServer::new(root).context("open authorized file root")?)
        }
        _ => None,
    };
    let (file_enabled, file_root_label) = files
        .as_ref()
        .map(|server| server.capabilities())
        .unwrap_or((false, String::new()));
    write_message(
        &mut writer,
        &ServerMessage::FileCapabilities {
            enabled: file_enabled,
            root_label: file_root_label,
            read: file_read,
            write: file_write,
            delete: false,
        },
    )
    .await?;
    info!(
        %peer,
        client = %hello.client_name,
        client_id = %hello.client_id,
        authenticated = auth.authenticated,
        account = auth.account.as_deref().unwrap_or("-"),
        permissions = %permission_summary(auth.permissions),
        input_allowed,
        file_read,
        file_write,
        width = info.width,
        height = info.height,
        "viewer session established"
    );
    let geometry = ScreenGeometry {
        x: info.origin_x,
        y: info.origin_y,
        width: info.width,
        height: info.height,
    };
    let mut injector = InputInjector::new(geometry);

    let (tx, rx) = mpsc::channel::<ServerMessage>(24);
    let writer_task = tokio::spawn(writer_loop(writer, rx));

    let stop = Arc::new(AtomicBool::new(false));
    let force_full = Arc::new(AtomicBool::new(true));

    let capture_options = CaptureOptions {
        monitor: config.monitor,
        fps: config.fps,
        tile_settings: config.tile_settings.clone(),
    };
    let capture_tx = tx.clone();
    let capture_stop = stop.clone();
    let capture_force = force_full.clone();
    let capture_task = tokio::task::spawn_blocking(move || {
        if let Err(error) =
            capture::capture_loop(capture_options, capture_tx, capture_stop, capture_force)
        {
            warn!(%error, "capture loop ended");
        }
    });

    let cursor_tx = tx.clone();
    let cursor_stop = stop.clone();
    let cursor_task = tokio::task::spawn_blocking(move || {
        capture::cursor_loop(geometry, cursor_tx, cursor_stop);
    });

    // The reader task owns the read half, so the authorization/revocation
    // checks can run while a read is in progress without cancelling a partial
    // framed message.
    let (message_tx, mut message_rx) = mpsc::channel::<ClientMessage>(32);
    let reader_task = tokio::spawn(async move {
        loop {
            match timeout(
                Duration::from_secs(35),
                read_message::<_, ClientMessage>(&mut reader),
            )
            .await
            {
                Ok(Ok(Some(message))) => {
                    if message_tx.send(message).await.is_err() {
                        break;
                    }
                }
                Ok(Ok(None)) => {
                    info!("viewer closed the connection");
                    break;
                }
                Ok(Err(error)) => {
                    warn!(%error, "viewer protocol error");
                    break;
                }
                Err(_) => {
                    warn!("viewer heartbeat timeout");
                    break;
                }
            }
        }
    });

    let mut denied_notified = false;
    let mut input_events = 0u64;
    let mut end_error: Option<(ErrorCode, String)> = None;
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            message = message_rx.recv() => {
                let Some(message) = message else {
                    break;
                };
                match message {
                    ClientMessage::Input(event) => {
                        input_events += 1;
                        if input_events <= 3 || input_events.is_multiple_of(200) {
                            // Never serialize the event: it contains key codes and
                            // coordinates, which the logging policy forbids.
                            debug!(count = input_events, "viewer input received");
                        }
                        if input_allowed {
                            if let Err(error) = injector.handle(&event) {
                                warn!(%error, "input injection failed");
                                let _ = tx.try_send(ServerMessage::Error {
                                    code: ErrorCode::Internal,
                                    message: format!("input injection failed: {error}"),
                                });
                            }
                        } else if !denied_notified {
                            denied_notified = true;
                            let _ = tx.try_send(ServerMessage::Error {
                                code: ErrorCode::InputDenied,
                                message: "Host did not grant input for this session".into(),
                            });
                        }
                    }
                    ClientMessage::RequestKeyframe => {
                        force_full.store(true, Ordering::Relaxed);
                        info!("viewer requested a full frame");
                    }
                    ClientMessage::Ping { nonce } => {
                        let _ = tx.try_send(ServerMessage::Pong { nonce });
                    }
                    ClientMessage::Bye => {
                        info!("viewer ended the session");
                        break;
                    }
                    ClientMessage::Hello(_) => {
                        let _ = tx.try_send(ServerMessage::Error {
                            code: ErrorCode::BadMessage,
                            message: "duplicate ClientHello".into(),
                        });
                    }
                    ClientMessage::TextInput { text } => {
                        if input_allowed {
                            if text.encode_utf16().count() > 4096 {
                                let _ = tx.try_send(ServerMessage::Error {
                                    code: ErrorCode::BadMessage,
                                    message: "text input is limited to 4096 UTF-16 units".into(),
                                });
                            } else if let Err(error) = injector.send_text(&text) {
                                warn!(%error, "text injection failed");
                                let _ = tx.try_send(ServerMessage::Error {
                                    code: ErrorCode::Internal,
                                    message: format!("text injection failed: {error}"),
                                });
                            } else {
                                debug!(
                                    units = text.encode_utf16().count(),
                                    "viewer text input injected"
                                );
                            }
                        } else if !denied_notified {
                            denied_notified = true;
                            let _ = tx.try_send(ServerMessage::Error {
                                code: ErrorCode::InputDenied,
                                message: "Host did not grant input for this session".into(),
                            });
                        }
                    }
                    message => {
                        handle_file_message(
                            message,
                            &mut files,
                            &tx,
                            file_read,
                            file_write,
                        )
                        .await;
                    }
                }
            }
            _ = tick.tick() => {
                if stop.load(Ordering::Relaxed) {
                    break;
                }
                if let Some(control) = config.control_plane.as_ref() {
                    if control.session_revoked(&auth.session_id) {
                        end_error = Some((
                            ErrorCode::Revoked,
                            "授权已被账号、设备或管理员撤销".into(),
                        ));
                        break;
                    }
                }
                if auth.ticket_expires_at > 0 && unix_now() >= auth.ticket_expires_at {
                    end_error = Some((
                        ErrorCode::TicketExpired,
                        "会话票据已过期，请重新授权".into(),
                    ));
                    break;
                }
            }
        }
    }

    stop.store(true, Ordering::Relaxed);
    injector.release_all();
    if let Some(files) = files.as_mut() {
        files.cancel_all_downloads();
    }
    if let Some(control) = config.control_plane.as_ref() {
        if auth.authenticated {
            let end_reason = end_error
                .as_ref()
                .map(|(code, _)| code.as_str())
                .unwrap_or("host_ended");
            control.report_end(&auth.session_id, end_reason);
        }
    }
    let bye_reason = end_error
        .as_ref()
        .map(|(_, message)| message.clone())
        .unwrap_or_else(|| "session ended".into());
    if let Some((code, message)) = end_error {
        let _ = tx.try_send(ServerMessage::Error { code, message });
    }
    let _ = tx.try_send(ServerMessage::Bye { reason: bye_reason });
    tokio::time::sleep(Duration::from_millis(80)).await;
    writer_task.abort();
    reader_task.abort();
    let _ = timeout(Duration::from_secs(3), capture_task).await;
    let _ = timeout(Duration::from_secs(3), cursor_task).await;
    info!(%peer, "session closed and held keys released");
    Ok(())
}

fn authorize(
    hello: &yl_proto::ClientHello,
    config: &HostConfig,
    local: u32,
) -> Result<Authorization, (ErrorCode, String)> {
    let (authenticated, account, ticket_permissions, session_id, expires, auth_mode, claims) =
        match (&hello.session_ticket, config.control_plane.as_ref()) {
            (Some(token), Some(control)) => {
                if !is_nonce(&hello.session_nonce) {
                    return Err((
                        ErrorCode::Unauthorized,
                        "会话随机数必须是 64 个十六进制字符".into(),
                    ));
                }
                if !control.owner_active() {
                    return Err((
                        ErrorCode::Unauthorized,
                        "账号或设备已被停用，控制服务拒绝新会话".into(),
                    ));
                }
                let claims =
                    control
                        .verify_ticket(token, &hello.session_nonce)
                        .map_err(|error| {
                            let code = match error {
                                TicketError::Expired | TicketError::NotYetValid => {
                                    ErrorCode::TicketExpired
                                }
                                _ => ErrorCode::Unauthorized,
                            };
                            (code, format!("会话票据无效：{error}"))
                        })?;
                if !control.claim_ticket(&claims) {
                    return Err((
                        ErrorCode::TicketReplay,
                        "会话票据已被使用（防重放拒绝）".into(),
                    ));
                }
                (
                    true,
                    Some(claims.user.clone()),
                    claims.permissions,
                    claims.jti.clone(),
                    claims.exp,
                    "ticket".to_string(),
                    Some(claims),
                )
            }
            (Some(_), None) => {
                return Err((
                    ErrorCode::Unauthorized,
                    "Host 未配置控制服务端，无法校验会话票据".into(),
                ));
            }
            (None, _) if config.allow_anonymous => (
                false,
                None,
                yl_proto::PERMISSION_ALL,
                "anonymous".to_string(),
                0,
                "anonymous-development".to_string(),
                None,
            ),
            (None, _) => {
                return Err((
                    ErrorCode::Unauthorized,
                    "需要账号/配对签发的会话票据；Host 未允许匿名直连".into(),
                ));
            }
        };

    let permissions = if authenticated {
        ticket_permissions & local
    } else {
        local
    };
    if permissions & PERMISSION_VIEW == 0 {
        return Err((
            ErrorCode::PermissionDenied,
            "有效权限不包含查看，连接被拒绝".into(),
        ));
    }
    Ok(Authorization {
        authenticated,
        account,
        permissions,
        session_id,
        ticket_expires_at: expires,
        auth_mode,
        claims,
    })
}

fn is_nonce(value: &str) -> bool {
    value.len() == 64 && value.chars().all(|character| character.is_ascii_hexdigit())
}

async fn reject<W>(writer: &mut W, code: ErrorCode, message: &str) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let _ = write_message(
        writer,
        &ServerMessage::Error {
            code,
            message: message.to_string(),
        },
    )
    .await;
    bail!("{message}")
}

async fn writer_loop<W>(mut writer: W, mut rx: mpsc::Receiver<ServerMessage>) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    while let Some(message) = rx.recv().await {
        write_message(&mut writer, &message)
            .await
            .context("write to viewer")?;
    }
    Ok(())
}

async fn handle_file_message(
    message: ClientMessage,
    files: &mut Option<FileServer>,
    tx: &mpsc::Sender<ServerMessage>,
    file_read: bool,
    file_write: bool,
) {
    let read_denied = || anyhow::anyhow!("会话没有文件读取权限");
    let write_denied = || anyhow::anyhow!("会话没有文件写入权限");
    match message {
        ClientMessage::FileList { request_id, path } => {
            let result = if !file_read {
                Err(read_denied())
            } else {
                match files.as_ref() {
                    Some(server) => server.list(&path),
                    None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
                }
            };
            match result {
                Ok(entries) => {
                    let _ = tx
                        .send(ServerMessage::DirListing {
                            request_id,
                            path,
                            entries,
                        })
                        .await;
                }
                Err(error) => {
                    send_file_error(tx, request_id, 0, format!("{error:#}")).await;
                }
            }
        }
        ClientMessage::FileDownload { task_id, path } => {
            let result = if !file_read {
                Err(read_denied())
            } else {
                match files.as_mut() {
                    Some(server) => server.take_download(task_id, &path),
                    None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
                }
            };
            match result {
                Ok(reader) => {
                    let download_tx = tx.clone();
                    let display_path = path.clone();
                    tokio::task::spawn_blocking(move || {
                        if let Err(error) = reader.stream(download_tx.clone()) {
                            warn!(%error, %display_path, "download failed");
                            let _ = download_tx.blocking_send(ServerMessage::FileError {
                                request_id: 0,
                                task_id,
                                message: format!("{error:#}"),
                            });
                        }
                    });
                }
                Err(error) => {
                    send_file_error(tx, 0, task_id, format!("{error:#}")).await;
                }
            }
        }
        ClientMessage::FileUploadStart {
            task_id,
            path,
            size,
            overwrite,
        } => {
            let result = if !file_write {
                Err(write_denied())
            } else {
                match files.as_mut() {
                    Some(server) => server.begin_upload(task_id, &path, size, overwrite),
                    None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
                }
            };
            match result {
                Ok(()) => {
                    let _ = tx
                        .send(ServerMessage::FileUploadAck {
                            task_id,
                            received: 0,
                        })
                        .await;
                }
                Err(error) => {
                    send_file_error(tx, 0, task_id, format!("{error:#}")).await;
                }
            }
        }
        ClientMessage::FileUploadChunk {
            task_id,
            offset,
            data,
        } => {
            let result = if !file_write {
                Err(write_denied())
            } else {
                files
                    .as_mut()
                    .map(|server| server.write_upload_chunk(task_id, offset, &data))
                    .unwrap_or_else(|| Err(anyhow::anyhow!("文件访问未授权")))
            };
            match result {
                Ok(received) => {
                    let _ = tx
                        .send(ServerMessage::FileUploadAck { task_id, received })
                        .await;
                }
                Err(error) => {
                    if let Some(server) = files.as_mut() {
                        server.cancel_task(task_id);
                    }
                    send_file_error(tx, 0, task_id, format!("{error:#}")).await;
                }
            }
        }
        ClientMessage::FileUploadFinish { task_id } => {
            let result = if !file_write {
                Err(write_denied())
            } else {
                files
                    .as_mut()
                    .map(|server| server.finish_upload(task_id))
                    .unwrap_or_else(|| Err(anyhow::anyhow!("文件访问未授权")))
            };
            match result {
                Ok((path, size, sha256)) => {
                    let _ = tx
                        .send(ServerMessage::FileDone {
                            task_id,
                            path,
                            size,
                            sha256,
                        })
                        .await;
                }
                Err(error) => {
                    send_file_error(tx, 0, task_id, format!("{error:#}")).await;
                }
            }
        }
        ClientMessage::FileCancel { task_id } => {
            if let Some(server) = files.as_mut() {
                server.cancel_task(task_id);
            }
            info!(task_id, "file task cancelled");
        }
        _ => {}
    }
}

async fn send_file_error(
    tx: &mpsc::Sender<ServerMessage>,
    request_id: u64,
    task_id: u64,
    message: String,
) {
    let _ = tx
        .send(ServerMessage::FileError {
            request_id,
            task_id,
            message,
        })
        .await;
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}
