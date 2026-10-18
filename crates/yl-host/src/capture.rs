//! Screen capture and delivery loop for the Windows Host.
//!
//! XCap's Windows GDI path is used for the M0 vertical slice. It is real screen
//! content, not a mock, but it is not the final high-performance backend:
//! DXGI Desktop Duplication / Windows Graphics Capture and hardware H.264/HEVC
//! encoding are required for the quality mode.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use image::RgbaImage;
use tokio::sync::mpsc;
use tracing::{info, warn};
use xcap::Monitor;

use yl_proto::{FrameMessage, ServerMessage, TileMessage};
use yl_tiles::{TileDiffer, TileSettings};

use crate::input;

#[derive(Debug, Clone)]
pub struct MonitorInfo {
    /// 1-based display index as shown by `--list-monitors`.
    pub index: usize,
    pub name: String,
    pub width: u32,
    pub height: u32,
    pub origin_x: i32,
    pub origin_y: i32,
    pub primary: bool,
}

pub fn list_monitors() -> Result<Vec<MonitorInfo>> {
    input::ensure_dpi_awareness();
    let monitors = Monitor::all().context("enumerate monitors")?;
    let mut infos = Vec::with_capacity(monitors.len());
    for (position, monitor) in monitors.iter().enumerate() {
        infos.push(info_for(monitor, position + 1)?);
    }
    Ok(infos)
}

/// `index == 0` selects the primary display; `index >= 1` selects the 1-based
/// entry from `--list-monitors`.
pub fn select_monitor(index: usize) -> Result<(Monitor, MonitorInfo)> {
    input::ensure_dpi_awareness();
    let monitors = Monitor::all().context("enumerate monitors")?;
    if monitors.is_empty() {
        anyhow::bail!("no display was found");
    }
    let chosen = if index == 0 {
        monitors
            .iter()
            .position(|m| m.is_primary().unwrap_or(false))
            .unwrap_or(0)
    } else {
        index - 1
    };
    let monitor = monitors
        .into_iter()
        .nth(chosen)
        .with_context(|| format!("monitor {index} does not exist"))?;
    let info = info_for(&monitor, chosen + 1)?;
    Ok((monitor, info))
}

pub fn monitor_info(index: usize) -> Result<MonitorInfo> {
    let (_monitor, info) = select_monitor(index)?;
    Ok(info)
}

fn info_for(monitor: &Monitor, index: usize) -> Result<MonitorInfo> {
    let name = monitor
        .friendly_name()
        .or_else(|_| monitor.name())
        .unwrap_or_else(|_| format!("Display {index}"));
    Ok(MonitorInfo {
        index,
        name,
        width: monitor.width().context("monitor width")?,
        height: monitor.height().context("monitor height")?,
        origin_x: monitor.x().context("monitor x")?,
        origin_y: monitor.y().context("monitor y")?,
        primary: monitor.is_primary().unwrap_or(false),
    })
}

pub fn capture_once(index: usize) -> Result<(MonitorInfo, RgbaImage, Duration)> {
    let (monitor, info) = select_monitor(index)?;
    let started = Instant::now();
    let image = monitor.capture_image().context("capture screen")?;
    let elapsed = started.elapsed();
    Ok((info, image, elapsed))
}

pub struct CaptureOptions {
    pub monitor: usize,
    pub fps: u32,
    pub tile_settings: TileSettings,
}

/// Captures frames until `stop` is set or the viewer disconnects. Runs on a
/// blocking thread: capture and JPEG encoding never block the async runtime.
pub fn capture_loop(
    options: CaptureOptions,
    tx: mpsc::Sender<ServerMessage>,
    stop: Arc<AtomicBool>,
    force_full: Arc<AtomicBool>,
) -> Result<()> {
    let (monitor, info) = select_monitor(options.monitor)?;
    info!(
        display = info.index,
        name = %info.name,
        width = info.width,
        height = info.height,
        origin_x = info.origin_x,
        origin_y = info.origin_y,
        "capture source selected"
    );
    let mut differ = TileDiffer::new(info.width, info.height, options.tile_settings)
        .context("initialise tile engine")?;
    let interval = Duration::from_millis((1000 / options.fps.clamp(1, 60)) as u64);
    let mut seq = 0u64;
    let mut first = true;
    let mut next_frame = Instant::now();

    let mut frames_sent = 0u64;
    let mut captures_done = 0u64;
    let mut tiles_sent = 0u64;
    let mut bytes_sent = 0u64;
    let mut capture_total = Duration::ZERO;
    let mut encode_total = Duration::ZERO;
    let mut stats_at = Instant::now();

    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let capture_started = Instant::now();
        let image = match monitor.capture_image() {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "screen capture failed");
                let _ = tx.blocking_send(ServerMessage::Error {
                    code: yl_proto::ErrorCode::ScreenUnavailable,
                    message: format!("screen capture failed: {error}"),
                });
                return Err(error.into());
            }
        };
        capture_total += capture_started.elapsed();
        captures_done += 1;

        let force = force_full.swap(false, Ordering::Relaxed) || first;
        first = false;
        let encode_started = Instant::now();
        let update = match differ.update(&image, force) {
            Ok(update) => update,
            Err(error) => {
                let _ = tx.blocking_send(ServerMessage::Error {
                    code: yl_proto::ErrorCode::Internal,
                    message: format!("tile encoding failed: {error}"),
                });
                return Err(error);
            }
        };
        encode_total += encode_started.elapsed();

        if let Some(update) = update {
            let tile_count = update.tiles.len();
            let encoded = update.encoded_bytes();
            seq = seq.wrapping_add(1);
            let frame = FrameMessage {
                seq,
                screen_generation: update.generation,
                full: update.full,
                width: update.width,
                height: update.height,
                tiles: update
                    .tiles
                    .into_iter()
                    .map(|tile| TileMessage {
                        x: tile.rect.x,
                        y: tile.rect.y,
                        width: tile.rect.width,
                        height: tile.rect.height,
                        jpeg: tile.jpeg,
                    })
                    .collect(),
            };
            if tx.blocking_send(ServerMessage::Frame(frame)).is_err() {
                return Ok(());
            }
            frames_sent += 1;
            tiles_sent += tile_count as u64;
            bytes_sent += encoded as u64;
        }

        if stats_at.elapsed() >= Duration::from_secs(5) {
            let elapsed = stats_at.elapsed().as_secs_f64();
            let capture_ms = capture_total.as_secs_f64() * 1000.0 / captures_done.max(1) as f64;
            let encode_ms = encode_total.as_secs_f64() * 1000.0 / captures_done.max(1) as f64;
            info!(
                frames = frames_sent,
                fps = format!("{:.1}", frames_sent as f64 / elapsed),
                tiles = tiles_sent,
                mib = format!("{:.2}", bytes_sent as f64 / 1_048_576.0),
                capture_ms = format!("{capture_ms:.1}"),
                encode_ms = format!("{encode_ms:.1}"),
                "capture stats"
            );
            frames_sent = 0;
            captures_done = 0;
            tiles_sent = 0;
            bytes_sent = 0;
            capture_total = Duration::ZERO;
            encode_total = Duration::ZERO;
            stats_at = Instant::now();
        }

        next_frame += interval;
        let now = Instant::now();
        if next_frame > now {
            sleep(next_frame - now);
        } else {
            next_frame = now + interval;
        }
    }
}

/// Sends cursor position changes at ~60 Hz, separately from pixel updates.
pub fn cursor_loop(
    geometry: input::ScreenGeometry,
    tx: mpsc::Sender<ServerMessage>,
    stop: Arc<AtomicBool>,
) {
    let mut previous: Option<yl_proto::CursorState> = None;
    while !stop.load(Ordering::Relaxed) {
        if let Some((x, y)) = input::cursor_position() {
            let local_x = x - geometry.x;
            let local_y = y - geometry.y;
            let visible = local_x >= 0
                && local_y >= 0
                && local_x < geometry.width as i32
                && local_y < geometry.height as i32;
            let state = yl_proto::CursorState {
                x: local_x,
                y: local_y,
                visible,
            };
            if previous != Some(state) {
                if tx.blocking_send(ServerMessage::Cursor(state)).is_err() {
                    return;
                }
                previous = Some(state);
            }
        }
        sleep(Duration::from_millis(16));
    }
}
