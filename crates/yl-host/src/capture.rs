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

use crate::fast_capture::FastCapture;
use crate::input;
use crate::wgc;

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
    let image = match FastCapture::new(info.width, info.height, info.origin_x, info.origin_y) {
        Ok(mut fast) => fast.capture().context("fast capture screen")?,
        Err(error) => {
            warn!(%error, "fast GDI capture unavailable; using XCap fallback");
            monitor.capture_image().context("capture screen")?
        }
    };
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
    // Prefer Windows Graphics Capture: the compositor provides frames without
    // a GDI readback. If WGC is unavailable, keep the persistent GDI path.
    match wgc::start(info.index, options.fps, stop.clone()) {
        Ok((receiver, control)) => {
            return run_wgc_loop(options, info, receiver, control, tx, stop, force_full);
        }
        Err(error) => {
            warn!(%error, "Windows Graphics Capture unavailable; using GDI capture");
        }
    }
    let mut fast = match FastCapture::new(info.width, info.height, info.origin_x, info.origin_y) {
        Ok(fast) => Some(fast),
        Err(error) => {
            warn!(%error, "fast GDI capture unavailable; using XCap fallback");
            None
        }
    };
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
        let captured = if let Some(fast_capture) = fast.as_mut() {
            match fast_capture.capture() {
                Ok(image) => Ok(image),
                Err(error) => {
                    warn!(%error, "fast GDI capture failed; switching to XCap");
                    fast = None;
                    monitor.capture_image().map_err(anyhow::Error::from)
                }
            }
        } else {
            monitor.capture_image().map_err(anyhow::Error::from)
        };
        let image = match captured {
            Ok(image) => image,
            Err(error) => {
                warn!(%error, "screen capture failed");
                let _ = tx.blocking_send(ServerMessage::Error {
                    code: yl_proto::ErrorCode::ScreenUnavailable,
                    message: format!("screen capture failed: {error}"),
                });
                return Err(error);
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

fn benchmark_wgc(
    info: MonitorInfo,
    frames: u64,
    fps: u32,
    settings: TileSettings,
    force_all: bool,
    receiver: std::sync::mpsc::Receiver<wgc::CapturedFrame>,
    control: wgc::WgcControl,
) -> Result<()> {
    let mut differ = TileDiffer::new(info.width, info.height, settings)?;
    let mut source_frames = 0u64;
    let mut processed = 0u64;
    let mut update_frames = 0u64;
    let mut tiles = 0u64;
    let mut bytes = 0u64;
    let mut encode_ms = Vec::new();
    let mut processed_times: Vec<Instant> = Vec::new();
    let started = Instant::now();
    while processed < frames {
        let frame = match receiver.recv_timeout(Duration::from_secs(2)) {
            Ok(frame) => frame,
            Err(_) => break,
        };
        source_frames += 1;
        let expected = info.width as usize * info.height as usize * 4;
        if frame.pixels.len() != expected {
            continue;
        }
        let image = match RgbaImage::from_raw(frame.width, frame.height, frame.pixels) {
            Some(image) => image,
            None => continue,
        };
        let encode_started = Instant::now();
        let update = differ.update(&image, force_all || processed == 0)?;
        encode_ms.push(encode_started.elapsed().as_secs_f64() * 1000.0);
        processed += 1;
        processed_times.push(Instant::now());
        if let Some(update) = update {
            update_frames += 1;
            tiles += update.tiles.len() as u64;
            bytes += update.encoded_bytes() as u64;
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    let _ = control.stop();
    encode_ms.sort_by(f64::total_cmp);
    let percentile = |values: &[f64], p: f64| -> f64 {
        if values.is_empty() {
            return 0.0;
        }
        let index = ((values.len() - 1) as f64 * p).round() as usize;
        values[index]
    };
    let avg = |values: &[f64]| -> f64 {
        if values.is_empty() {
            0.0
        } else {
            values.iter().sum::<f64>() / values.len() as f64
        }
    };
    let threshold = if fps >= 60 { 55.0 } else { 30.0 };
    let whole_seconds = elapsed.floor() as usize;
    let mut windows = vec![0u32; whole_seconds];
    for at in &processed_times {
        let second = at.duration_since(started).as_secs() as usize;
        if second < windows.len() {
            windows[second] += 1;
        }
    }
    let windows_ge = windows
        .iter()
        .filter(|count| **count as f64 >= threshold)
        .count();
    let mut interval_ms = processed_times
        .windows(2)
        .map(|pair| pair[1].duration_since(pair[0]).as_secs_f64() * 1000.0)
        .collect::<Vec<_>>();
    interval_ms.sort_by(f64::total_cmp);
    let min_window = windows.iter().min().copied().unwrap_or(0);
    println!(
        "{{\"display\":{},\"name\":\"{}\",\"width\":{},\"height\":{},\"requested_fps\":{},\
         \"force_full\":{},\"capture_backend\":\"wgc\",\"frames\":{},\"source_frames\":{},\
         \"update_frames\":{},\"effective_pipeline_fps\":{:.1},\"source_fps\":{:.1},\
         \"capture_ms_avg\":null,\"capture_ms_p50\":null,\"capture_ms_p95\":null,\
         \"encode_ms_avg\":{:.2},\"encode_ms_p50\":{:.2},\"encode_ms_p95\":{:.2},\
         \"tiles\":{},\"encoded_bytes\":{},\"elapsed_secs\":{:.3},\"one_second_windows\":{},\"one_second_windows_ge_threshold\":{},\"one_second_min_fps\":{},\"frame_interval_ms_p50\":{:.2},\"frame_interval_ms_p95\":{:.2}}}",
        info.index,
        info.name.replace('"', "'"),
        info.width,
        info.height,
        fps.clamp(1, 60),
        force_all,
        processed,
        source_frames,
        update_frames,
        processed as f64 / elapsed.max(0.001),
        source_frames as f64 / elapsed.max(0.001),
        avg(&encode_ms),
        percentile(&encode_ms, 0.50),
        percentile(&encode_ms, 0.95),
        tiles,
        bytes,
        elapsed,
        windows.len(),
        windows_ge,
        min_window,
        percentile(&interval_ms, 0.50),
        percentile(&interval_ms, 0.95)
    );
    Ok(())
}

fn run_wgc_loop(
    options: CaptureOptions,
    info: MonitorInfo,
    receiver: std::sync::mpsc::Receiver<wgc::CapturedFrame>,
    control: wgc::WgcControl,
    tx: mpsc::Sender<ServerMessage>,
    stop: Arc<AtomicBool>,
    force_full: Arc<AtomicBool>,
) -> Result<()> {
    let mut differ = TileDiffer::new(info.width, info.height, options.tile_settings)
        .context("initialise tile engine")?;
    let mut seq = 0u64;
    let mut first = true;
    let mut source_frames = 0u64;
    let mut frames_sent = 0u64;
    let mut tiles_sent = 0u64;
    let mut bytes_sent = 0u64;
    let mut encode_total = Duration::ZERO;
    let mut encode_frames = 0u64;
    let mut stats_at = Instant::now();
    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let frame = match receiver.recv_timeout(Duration::from_millis(200)) {
            Ok(frame) => frame,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        };
        source_frames += 1;
        let expected = info.width as usize * info.height as usize * 4;
        if frame.width != info.width
            || frame.height != info.height
            || frame.pixels.len() != expected
        {
            continue;
        }
        let image = match RgbaImage::from_raw(frame.width, frame.height, frame.pixels) {
            Some(image) => image,
            None => continue,
        };
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
                let _ = control.stop();
                return Err(error);
            }
        };
        encode_total += encode_started.elapsed();
        encode_frames += 1;
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
                break;
            }
            frames_sent += 1;
            tiles_sent += tile_count as u64;
            bytes_sent += encoded as u64;
        }
        if stats_at.elapsed() >= Duration::from_secs(5) {
            let elapsed = stats_at.elapsed().as_secs_f64();
            let encode_ms = encode_total.as_secs_f64() * 1000.0 / encode_frames.max(1) as f64;
            info!(
                capture_backend = "wgc",
                source_frames,
                frames = frames_sent,
                fps = format!("{:.1}", frames_sent as f64 / elapsed),
                tiles = tiles_sent,
                mib = format!("{:.2}", bytes_sent as f64 / 1_048_576.0),
                encode_ms = format!("{encode_ms:.1}"),
                "capture stats"
            );
            source_frames = 0;
            frames_sent = 0;
            tiles_sent = 0;
            bytes_sent = 0;
            encode_total = Duration::ZERO;
            encode_frames = 0;
            stats_at = Instant::now();
        }
    }
    stop.store(true, Ordering::Relaxed);
    let _ = control.stop();
    Ok(())
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

/// Measures the Host-side capture + tile-diff/encode pipeline without a
/// viewer. This is deliberately not an end-to-end presentation benchmark; it
/// reports raw pipeline percentiles so 30/60 claims can be separated from
/// network/decode/present costs.
pub fn benchmark(
    monitor_index: usize,
    frames: u64,
    fps: u32,
    settings: TileSettings,
    force_all: bool,
) -> Result<()> {
    let (monitor, info) = select_monitor(monitor_index)?;
    let stop = Arc::new(AtomicBool::new(false));
    if let Ok((receiver, control)) = wgc::start(info.index, fps, stop.clone()) {
        return benchmark_wgc(info, frames, fps, settings, force_all, receiver, control);
    }
    let mut fast = match FastCapture::new(info.width, info.height, info.origin_x, info.origin_y) {
        Ok(fast) => Some(fast),
        Err(error) => {
            warn!(%error, "fast GDI capture unavailable; using XCap fallback");
            None
        }
    };
    let mut differ = TileDiffer::new(info.width, info.height, settings)?;
    let mut capture_ms = Vec::with_capacity(frames as usize);
    let mut encode_ms = Vec::with_capacity(frames as usize);
    let mut update_frames = 0u64;
    let mut tiles = 0u64;
    let mut bytes = 0u64;
    let started = Instant::now();
    let interval = Duration::from_millis((1000 / fps.clamp(1, 60)) as u64);
    let mut next = Instant::now();
    for index in 0..frames {
        let capture_started = Instant::now();
        let image = if let Some(capture) = fast.as_mut() {
            match capture.capture() {
                Ok(image) => image,
                Err(error) => {
                    warn!(%error, "fast capture failed in benchmark; using XCap");
                    fast = None;
                    monitor.capture_image().map_err(anyhow::Error::from)?
                }
            }
        } else {
            monitor.capture_image().map_err(anyhow::Error::from)?
        };
        capture_ms.push(capture_started.elapsed().as_secs_f64() * 1000.0);
        let encode_started = Instant::now();
        let update = differ.update(&image, force_all || index == 0)?;
        encode_ms.push(encode_started.elapsed().as_secs_f64() * 1000.0);
        if let Some(update) = update {
            update_frames += 1;
            tiles += update.tiles.len() as u64;
            bytes += update.encoded_bytes() as u64;
        }
        next += interval;
        let now = Instant::now();
        if next > now {
            sleep(next - now);
        } else {
            next = now + interval;
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    capture_ms.sort_by(f64::total_cmp);
    encode_ms.sort_by(f64::total_cmp);
    let percentile = |values: &[f64], p: f64| -> f64 {
        if values.is_empty() {
            return 0.0;
        }
        let index = ((values.len() - 1) as f64 * p).round() as usize;
        values[index]
    };
    let avg = |values: &[f64]| -> f64 {
        if values.is_empty() {
            0.0
        } else {
            values.iter().sum::<f64>() / values.len() as f64
        }
    };
    println!(
        "{{\"display\":{},\"name\":\"{}\",\"width\":{},\"height\":{},\"requested_fps\":{},\"force_full\":{},\
         \"frames\":{},\"update_frames\":{},\"effective_pipeline_fps\":{:.1},\
         \"capture_ms_avg\":{:.2},\"capture_ms_p50\":{:.2},\"capture_ms_p95\":{:.2},\
         \"encode_ms_avg\":{:.2},\"encode_ms_p50\":{:.2},\"encode_ms_p95\":{:.2},\
         \"tiles\":{},\"encoded_bytes\":{},\"elapsed_secs\":{:.3}}}",
        info.index,
        info.name.replace('"', "'"),
        info.width,
        info.height,
        fps.clamp(1, 60),
        force_all,
        frames,
        update_frames,
        frames as f64 / elapsed.max(0.001),
        avg(&capture_ms),
        percentile(&capture_ms, 0.50),
        percentile(&capture_ms, 0.95),
        avg(&encode_ms),
        percentile(&encode_ms, 0.50),
        percentile(&encode_ms, 0.95),
        tiles,
        bytes,
        elapsed
    );
    Ok(())
}
