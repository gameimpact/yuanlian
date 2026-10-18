//! One viewer connection: TLS handshake, authorization, capture and input.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use tokio::io::AsyncWrite;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_rustls::server::TlsStream;
use tracing::{debug, info, warn};

use yl_proto::{
    read_message, write_message, ClientMessage, ErrorCode, ServerMessage, Welcome, PROTOCOL_VERSION,
};
use yl_tiles::TileSettings;

use crate::capture::{self, CaptureOptions};
use crate::files::FileServer;
use crate::input::{InputInjector, ScreenGeometry};

#[derive(Debug, Clone)]
pub struct HostConfig {
    pub host_id: String,
    pub host_name: String,
    pub monitor: usize,
    pub allow_input: bool,
    pub fps: u32,
    pub tile_settings: TileSettings,
    pub file_root: Option<PathBuf>,
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
            let _ = write_message(
                &mut writer,
                &ServerMessage::Error {
                    code: ErrorCode::BadMessage,
                    message: "expected ClientHello as the first message".into(),
                },
            )
            .await;
            bail!("viewer did not start with ClientHello");
        }
        Ok(Ok(None)) => bail!("viewer disconnected before ClientHello"),
        Ok(Err(error)) => return Err(error.context("read ClientHello")),
        Err(_) => bail!("timed out waiting for ClientHello"),
    };

    if hello.protocol_version != PROTOCOL_VERSION {
        let message = ServerMessage::Error {
            code: ErrorCode::ProtocolVersion,
            message: format!(
                "Host speaks protocol {PROTOCOL_VERSION}, viewer speaks {}",
                hello.protocol_version
            ),
        };
        let _ = write_message(&mut writer, &message).await;
        bail!(
            "protocol version mismatch: viewer {}",
            hello.protocol_version
        );
    }

    let info = capture::monitor_info(config.monitor)?;
    let input_allowed = config.allow_input && hello.request_input;
    if hello.request_input && !config.allow_input {
        warn!(peer = %peer, "viewer requested input but Host was started without --allow-input");
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
    };
    write_message(&mut writer, &ServerMessage::Welcome(welcome)).await?;
    let mut files = match config.file_root.as_ref() {
        Some(root) => Some(FileServer::new(root).context("open authorized file root")?),
        None => None,
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
        },
    )
    .await?;
    info!(
        %peer,
        client = %hello.client_name,
        client_id = %hello.client_id,
        input_allowed,
        file_enabled,
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

    let mut denied_notified = false;
    let mut input_events = 0u64;
    loop {
        let message = match timeout(
            Duration::from_secs(35),
            read_message::<_, ClientMessage>(&mut reader),
        )
        .await
        {
            Ok(Ok(Some(message))) => message,
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
        };

        match message {
            ClientMessage::Input(event) => {
                input_events += 1;
                if input_events <= 3 || input_events.is_multiple_of(200) {
                    debug!(count = input_events, ?event, "viewer input received");
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
                handle_file_message(message, &mut files, &tx).await;
            }
        }
    }

    stop.store(true, Ordering::Relaxed);
    injector.release_all();
    let _ = tx.try_send(ServerMessage::Bye {
        reason: "session ended".into(),
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    writer_task.abort();
    let _ = timeout(Duration::from_secs(3), capture_task).await;
    let _ = timeout(Duration::from_secs(3), cursor_task).await;
    info!(%peer, "session closed and held keys released");
    Ok(())
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
) {
    match message {
        ClientMessage::FileList { request_id, path } => {
            let result = match files.as_ref() {
                Some(server) => server.list(&path),
                None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
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
            let result = match files.as_mut() {
                Some(server) => server.take_download(task_id, &path),
                None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
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
            let result = match files.as_mut() {
                Some(server) => server.begin_upload(task_id, &path, size, overwrite),
                None => Err(anyhow::anyhow!("文件访问未授权：Host 未配置 --file-root")),
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
            let result = files
                .as_mut()
                .map(|server| server.write_upload_chunk(task_id, offset, &data))
                .unwrap_or_else(|| Err(anyhow::anyhow!("文件访问未授权")));
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
            let result = files
                .as_mut()
                .map(|server| server.finish_upload(task_id))
                .unwrap_or_else(|| Err(anyhow::anyhow!("文件访问未授权")));
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
