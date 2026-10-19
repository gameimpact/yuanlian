mod keys;
mod net;
mod quality;

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::Parser;
use minifb::{Key, KeyRepeat, MouseButton, MouseMode, ScaleMode, Window, WindowOptions};
use rayon::prelude::*;
use tracing::{debug, info, warn};
use tracing_subscriber::EnvFilter;

use yl_proto::{
    parse_fingerprint, ClientMessage, CursorState, ErrorCode, FrameMessage, InputEvent, Welcome,
};

use keys::to_windows_vk;
use net::NetEvent;

#[derive(Debug, Parser)]
#[command(name = "yl-viewer", version, about = "远联原生测试查看器（M0 开发版）")]
struct Args {
    /// Host 地址，例如 127.0.0.1:24800。
    #[arg(long)]
    connect: String,
    #[arg(long, default_value="tiles", value_parser=["tiles","flow","quality"])]
    mode: String,
    #[arg(long)]
    moonlight: Option<std::path::PathBuf>,
    #[arg(long)]
    view_only: bool,

    /// Host 控制台打印的 TLS SHA-256 指纹。
    #[arg(long)]
    fingerprint: String,

    /// 显示给 Host 的客户端名称。
    #[arg(long, default_value = "yl-viewer")]
    name: String,

    /// 测试专用：即使 Host 未授权也继续发送输入，用于验证 Host 侧强制拒绝。
    #[arg(long, hide = true)]
    force_input: bool,

    /// 控制服务端签发的短时会话票据（诊断/自动化测试）。
    #[arg(long)]
    ticket: Option<String>,

    /// 与票据绑定的 64 位十六进制连接随机数。
    #[arg(long, default_value = "")]
    nonce: String,
}

fn main() -> Result<()> {
    ensure_dpi_awareness();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("yl_viewer=info,info")),
        )
        .with_target(false)
        .compact()
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();

    let args = Args::parse();
    let fingerprint = parse_fingerprint(&args.fingerprint).context("invalid --fingerprint")?;
    if args.mode == "quality" {
        return quality::run(&args, fingerprint);
    }
    let (events, handle) = net::spawn_connection(
        args.connect.clone(),
        fingerprint,
        args.name.clone(),
        net::SessionAuth {
            mode: args.mode.clone(),
            ticket: args
                .ticket
                .clone()
                .or_else(|| std::env::var("YUANLIAN_SESSION_TICKET").ok()),
            nonce: args.nonce.clone(),
        },
    )?;
    let welcome = match wait_for_welcome(&events, Duration::from_secs(15)) {
        Ok(welcome) => welcome,
        Err(error) => bail!("{error:#}"),
    };
    println!(
        "已连接 {}（Host ID {}），屏幕 {}x{}，模式 {}，授权：{}，输入：{}",
        welcome.host_name,
        welcome.host_id,
        welcome.screen_width,
        welcome.screen_height,
        welcome.mode,
        if welcome.authenticated {
            format!("账号 {} / {}", welcome.account, welcome.auth_mode)
        } else {
            format!("匿名开发模式 / {}", welcome.auth_mode)
        },
        if welcome.input_allowed {
            "允许"
        } else {
            "仅查看（权限或 Host 策略未允许输入）"
        }
    );

    let mut app = App::new(welcome, handle.outbound.clone(), args.force_input)?;
    let result = app.run(&events);
    let _ = handle.outbound.send(ClientMessage::Bye);
    debug!("viewer main loop finished");
    result
}

/// Input mapping and window sizing must use physical pixels; otherwise a
/// DPI-unaware window reports a virtualized client rect and remote pointer
/// coordinates drift. This matches the Host's Per-Monitor-V2 declaration.
fn ensure_dpi_awareness() {
    #[cfg(windows)]
    {
        use windows::Win32::UI::HiDpi::{
            SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        };
        if let Err(error) =
            unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }
        {
            debug!(%error, "SetProcessDpiAwarenessContext was not applied");
        }
    }
}

fn wait_for_welcome(events: &Receiver<NetEvent>, limit: Duration) -> Result<Welcome> {
    let deadline = Instant::now() + limit;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            bail!("timed out waiting for the Host Welcome message");
        }
        match events.recv_timeout(remaining) {
            Ok(NetEvent::Welcome(welcome)) => return Ok(welcome),
            Ok(NetEvent::Disconnected(reason)) => bail!("connection failed: {reason}"),
            Ok(NetEvent::Error(_, message)) => bail!("Host rejected the session: {message}"),
            Ok(_) => continue,
            Err(RecvTimeoutError::Timeout) => {
                bail!("timed out waiting for the Host Welcome message")
            }
            Err(RecvTimeoutError::Disconnected) => bail!("network thread stopped unexpectedly"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Layout {
    offset_x: i32,
    offset_y: i32,
    draw_w: i32,
    draw_h: i32,
}

fn layout_for(remote_w: u32, remote_h: u32, window_w: usize, window_h: usize) -> Layout {
    if remote_w == 0 || remote_h == 0 || window_w == 0 || window_h == 0 {
        return Layout {
            offset_x: 0,
            offset_y: 0,
            draw_w: 0,
            draw_h: 0,
        };
    }
    let scale = (window_w as f64 / remote_w as f64)
        .min(window_h as f64 / remote_h as f64)
        .max(0.0);
    let draw_w = (remote_w as f64 * scale).round().max(1.0) as i32;
    let draw_h = (remote_h as f64 * scale).round().max(1.0) as i32;
    Layout {
        offset_x: ((window_w as i32 - draw_w) / 2).max(0),
        offset_y: ((window_h as i32 - draw_h) / 2).max(0),
        draw_w: draw_w.min(window_w as i32),
        draw_h: draw_h.min(window_h as i32),
    }
}

#[derive(Debug, Default)]
struct RateStats {
    frames: u64,
    bytes: u64,
    since: Option<Instant>,
}

struct App {
    window: Window,
    outbound: tokio::sync::mpsc::UnboundedSender<ClientMessage>,
    remote_w: u32,
    remote_h: u32,
    remote: Vec<u32>,
    screen_generation: u32,
    display: Vec<u32>,
    dirty: bool,
    layout: Layout,
    connected: bool,
    disconnected_reported: bool,
    disconnect_reason: String,
    input_allowed: bool,
    inactive: bool,
    buttons: [bool; 5],
    last_sent_mouse: Option<(i32, i32)>,
    cursor: Option<CursorState>,
    host_name: String,
    stats: RateStats,
    last_title_update: Instant,
    stats_log_at: Instant,
    presented_frames: u64,
    presented_at: Instant,
    frame_ready: bool,
    force_input: bool,
}

impl App {
    fn new(
        welcome: Welcome,
        outbound: tokio::sync::mpsc::UnboundedSender<ClientMessage>,
        force_input: bool,
    ) -> Result<Self> {
        let remote_w = welcome.screen_width.max(1);
        let remote_h = welcome.screen_height.max(1);
        let (window_w, window_h) = fit_window(remote_w, remote_h);
        let title = format!(
            "远联 | {} | {}x{} | 连接中 | {}",
            welcome.host_name,
            remote_w,
            remote_h,
            if welcome.input_allowed {
                "可控制"
            } else {
                "仅查看"
            }
        );
        let mut window = Window::new(
            &title,
            window_w,
            window_h,
            WindowOptions {
                resize: true,
                scale: minifb::Scale::X1,
                scale_mode: ScaleMode::AspectRatioStretch,
                ..Default::default()
            },
        )
        .context("create viewer window")?;
        window.set_target_fps(60);
        // The remote cursor is drawn from Host cursor updates; keeping the
        // local cursor visible would show two pointers.
        window.set_cursor_visibility(false);

        Ok(Self {
            window,
            outbound,
            remote_w,
            remote_h,
            remote: vec![0x000000; (remote_w * remote_h) as usize],
            screen_generation: 0,
            display: Vec::new(),
            dirty: true,
            layout: Layout {
                offset_x: 0,
                offset_y: 0,
                draw_w: 0,
                draw_h: 0,
            },
            connected: true,
            disconnected_reported: false,
            disconnect_reason: String::new(),
            input_allowed: welcome.input_allowed,
            inactive: false,
            buttons: [false; 5],
            last_sent_mouse: None,
            cursor: None,
            host_name: welcome.host_name,
            stats: RateStats {
                frames: 0,
                bytes: 0,
                since: Some(Instant::now()),
            },
            last_title_update: Instant::now(),
            stats_log_at: Instant::now(),
            presented_frames: 0,
            presented_at: Instant::now(),
            frame_ready: false,
            force_input,
        })
    }

    fn run(&mut self, events: &Receiver<NetEvent>) -> Result<()> {
        let mut last_size = (0usize, 0usize);
        while self.window.is_open() {
            self.pump_network(events);

            if self.quit_hotkey() {
                info!("local quit hotkey pressed");
                break;
            }
            self.forward_input();

            let size = self.window.get_size();
            if size != last_size {
                last_size = size;
                self.dirty = true;
            }
            if size.0 > 0 && size.1 > 0 {
                if self.dirty {
                    self.composite(size.0, size.1);
                    self.dirty = false;
                }
                self.window
                    .update_with_buffer(&self.display, size.0, size.1)
                    .context("present viewer frame")?;
                if self.frame_ready {
                    self.frame_ready = false;
                    self.presented_frames += 1;
                }
            }
            self.update_title();
        }

        self.send_release_all();
        self.window.set_cursor_visibility(true);
        info!("viewer window closed");
        Ok(())
    }

    fn pump_network(&mut self, events: &Receiver<NetEvent>) {
        while let Ok(event) = events.try_recv() {
            match event {
                NetEvent::Frame(frame) => self.apply_frame(frame),
                NetEvent::Cursor(cursor) => {
                    if self.cursor != Some(cursor) {
                        self.cursor = Some(cursor);
                        self.dirty = true;
                    }
                }
                NetEvent::Error(code, message) => {
                    warn!(?code, %message, "Host error");
                    if code == ErrorCode::InputDenied {
                        self.input_allowed = false;
                        self.send_release_all();
                    }
                }
                NetEvent::Disconnected(reason) => {
                    if !self.disconnected_reported {
                        self.disconnected_reported = true;
                        self.connected = false;
                        self.disconnect_reason = reason.clone();
                        self.input_allowed = false;
                        self.send_release_all();
                        println!("连接中断：{reason}");
                        warn!(%reason, "connection lost");
                    }
                }
                NetEvent::Welcome(_) => {
                    debug!("ignoring duplicate Welcome");
                }
            }
        }
    }

    fn apply_frame(&mut self, frame: FrameMessage) {
        if frame.width == 0
            || frame.height == 0
            || frame.width as u64 * frame.height as u64 > 64_000_000
        {
            warn!(
                width = frame.width,
                height = frame.height,
                "ignoring frame with invalid geometry"
            );
            return;
        }
        let reset = frame.full
            || frame.width != self.remote_w
            || frame.height != self.remote_h
            || frame.screen_generation != self.screen_generation;
        if reset {
            self.remote_w = frame.width;
            self.remote_h = frame.height;
            self.remote = vec![0x000000; (self.remote_w * self.remote_h) as usize];
            self.screen_generation = frame.screen_generation;
            self.last_sent_mouse = None;
            self.dirty = true;
            info!(
                width = self.remote_w,
                height = self.remote_h,
                generation = self.screen_generation,
                full = frame.full,
                "screen generation reset"
            );
        }

        self.stats.frames += 1;
        self.frame_ready = true;
        self.stats.bytes += frame
            .tiles
            .iter()
            .map(|tile| tile.jpeg.len() as u64)
            .sum::<u64>();

        let remote_w = self.remote_w as usize;
        let remote_h = self.remote_h as usize;
        // Decode independent JPEG tiles in parallel; at 60 fps a
        // 3200x2000 update can contain hundreds of tiles and sequential
        // decode becomes the viewer bottleneck.
        let decoded = frame
            .tiles
            .into_par_iter()
            .filter_map(|tile| {
                let tile_w = tile.width as usize;
                let tile_h = tile.height as usize;
                if tile_w == 0 || tile_h == 0 || tile.jpeg.is_empty() {
                    return None;
                }
                let x = tile.x as usize;
                let y = tile.y as usize;
                if x + tile_w > remote_w || y + tile_h > remote_h {
                    warn!(
                        x = tile.x,
                        y = tile.y,
                        tile_w,
                        tile_h,
                        "tile outside screen bounds"
                    );
                    return None;
                }
                let decoded =
                    match image::load_from_memory_with_format(&tile.jpeg, image::ImageFormat::Jpeg)
                    {
                        Ok(image) => image.to_rgb8(),
                        Err(error) => {
                            warn!(%error, x = tile.x, y = tile.y, "tile JPEG decode failed");
                            return None;
                        }
                    };
                if decoded.width() as usize != tile_w || decoded.height() as usize != tile_h {
                    warn!(
                        decoded = format!("{}x{}", decoded.width(), decoded.height()),
                        x = tile.x,
                        y = tile.y,
                        expected = format!("{tile_w}x{tile_h}"),
                        "tile dimensions mismatch"
                    );
                    return None;
                }
                Some((tile, decoded))
            })
            .collect::<Vec<_>>();
        for (tile, decoded) in decoded {
            let tile_w = tile.width as usize;
            let tile_h = tile.height as usize;
            let x = tile.x as usize;
            let y = tile.y as usize;
            let rgb = decoded.as_raw();
            for row in 0..tile_h {
                let dst_y = y + row;
                let src_start = row * tile_w * 3;
                let dst_start = dst_y * remote_w + x;
                for col in 0..tile_w {
                    let index = src_start + col * 3;
                    let pixel = ((rgb[index] as u32) << 16)
                        | ((rgb[index + 1] as u32) << 8)
                        | rgb[index + 2] as u32;
                    self.remote[dst_start + col] = pixel;
                }
            }
            self.dirty = true;
        }
    }

    fn composite(&mut self, window_w: usize, window_h: usize) {
        self.display = vec![0x00101418; window_w * window_h];
        let layout = layout_for(self.remote_w, self.remote_h, window_w, window_h);
        self.layout = layout;
        if layout.draw_w <= 0 || layout.draw_h <= 0 {
            return;
        }
        let rw = self.remote_w as usize;
        let rh = self.remote_h as usize;
        let draw_w = layout.draw_w as usize;
        let draw_h = layout.draw_h as usize;
        let xmap: Vec<usize> = (0..draw_w)
            .map(|dx| ((dx as u64 * rw as u64) / draw_w as u64).min((rw - 1) as u64) as usize)
            .collect();
        for dy in 0..draw_h {
            let sy = ((dy as u64 * rh as u64) / draw_h as u64).min((rh - 1) as u64) as usize;
            let src_row = sy * rw;
            let dst_row = (layout.offset_y as usize + dy) * window_w + layout.offset_x as usize;
            for (dx, sx) in xmap.iter().enumerate() {
                self.display[dst_row + dx] = self.remote[src_row + sx];
            }
        }
        self.draw_cursor(window_w, window_h);
    }

    fn draw_cursor(&mut self, window_w: usize, window_h: usize) {
        let Some(cursor) = self.cursor else {
            return;
        };
        if !cursor.visible || self.layout.draw_w <= 0 || self.layout.draw_h <= 0 {
            return;
        }
        if cursor.x < 0
            || cursor.y < 0
            || cursor.x >= self.remote_w as i32
            || cursor.y >= self.remote_h as i32
        {
            return;
        }
        let px = self.layout.offset_x
            + ((cursor.x as i64 * self.layout.draw_w as i64) / self.remote_w as i64) as i32;
        let py = self.layout.offset_y
            + ((cursor.y as i64 * self.layout.draw_h as i64) / self.remote_h as i64) as i32;
        const SHAPE: [&str; 11] = [
            "X......", "XX.....", "X#X....", "X##X...", "X###X..", "X####X.", "X##XXX.", "X#X#X..",
            "XX..#X.", "X....X.", ".....X.",
        ];
        for (row, line) in SHAPE.iter().enumerate() {
            for (col, ch) in line.chars().enumerate() {
                let x = px + col as i32;
                let y = py + row as i32;
                if x < 0 || y < 0 || x >= window_w as i32 || y >= window_h as i32 {
                    continue;
                }
                let color = match ch {
                    'X' => 0x000000,
                    '#' => 0x00FFFFFF,
                    _ => continue,
                };
                self.display[y as usize * window_w + x as usize] = color;
            }
        }
    }

    fn quit_hotkey(&self) -> bool {
        let keys = self.window.get_keys();
        let ctrl = keys.contains(&Key::LeftCtrl) || keys.contains(&Key::RightCtrl);
        let alt = keys.contains(&Key::LeftAlt) || keys.contains(&Key::RightAlt);
        ctrl && alt && keys.contains(&Key::Q)
    }

    fn forward_input(&mut self) {
        if !self.connected {
            return;
        }
        if !self.window.is_active() {
            if !self.inactive {
                self.inactive = true;
                self.send_release_all();
            }
            return;
        }
        self.inactive = false;
        if !self.input_allowed && !self.force_input {
            return;
        }

        let (window_w, window_h) = self.window.get_size();
        let layout = layout_for(self.remote_w, self.remote_h, window_w, window_h);
        let cursor = self.window.get_mouse_pos(MouseMode::Discard);
        let inside = cursor.is_some_and(|(x, y)| {
            x >= layout.offset_x as f32
                && y >= layout.offset_y as f32
                && x < (layout.offset_x + layout.draw_w) as f32
                && y < (layout.offset_y + layout.draw_h) as f32
        });

        if let Some((mouse_x, mouse_y)) = cursor {
            if inside {
                let relative_x = mouse_x - layout.offset_x as f32;
                let relative_y = mouse_y - layout.offset_y as f32;
                let remote_x = ((relative_x as f64 * self.remote_w as f64 / layout.draw_w as f64)
                    as i32)
                    .clamp(0, self.remote_w as i32 - 1);
                let remote_y = ((relative_y as f64 * self.remote_h as f64 / layout.draw_h as f64)
                    as i32)
                    .clamp(0, self.remote_h as i32 - 1);
                if self.last_sent_mouse != Some((remote_x, remote_y)) {
                    self.last_sent_mouse = Some((remote_x, remote_y));
                    self.send(ClientMessage::Input(InputEvent::MouseMove {
                        x: remote_x,
                        y: remote_y,
                    }));
                }
            } else {
                self.release_mouse_buttons();
                self.last_sent_mouse = None;
            }
        } else {
            self.release_mouse_buttons();
            self.last_sent_mouse = None;
        }

        for (index, (local, protocol)) in [
            (MouseButton::Left, yl_proto::MouseButton::Left),
            (MouseButton::Right, yl_proto::MouseButton::Right),
            (MouseButton::Middle, yl_proto::MouseButton::Middle),
            (MouseButton::Back, yl_proto::MouseButton::Back),
            (MouseButton::Forward, yl_proto::MouseButton::Forward),
        ]
        .into_iter()
        .enumerate()
        {
            let down = self.window.get_mouse_down(local);
            if down && inside && !self.buttons[index] {
                self.buttons[index] = true;
                self.send(ClientMessage::Input(InputEvent::MouseButton {
                    button: protocol,
                    down: true,
                }));
            } else if !down && self.buttons[index] {
                self.buttons[index] = false;
                self.send(ClientMessage::Input(InputEvent::MouseButton {
                    button: protocol,
                    down: false,
                }));
            }
        }

        if let Some((horizontal, vertical)) = self.window.get_scroll_wheel() {
            let vertical = (vertical * 120.0).round() as i32;
            let horizontal = (horizontal * 120.0).round() as i32;
            if vertical != 0 || horizontal != 0 {
                self.send(ClientMessage::Input(InputEvent::Wheel {
                    vertical,
                    horizontal,
                }));
            }
        }

        for key in self.window.get_keys_pressed(KeyRepeat::Yes) {
            if let Some((vk, extended)) = to_windows_vk(key) {
                self.send(ClientMessage::Input(InputEvent::Key {
                    vk,
                    down: true,
                    extended,
                }));
            }
        }
        for key in self.window.get_keys_released() {
            if let Some((vk, extended)) = to_windows_vk(key) {
                self.send(ClientMessage::Input(InputEvent::Key {
                    vk,
                    down: false,
                    extended,
                }));
            }
        }
    }

    fn release_mouse_buttons(&mut self) {
        for (index, (_, protocol)) in [
            (MouseButton::Left, yl_proto::MouseButton::Left),
            (MouseButton::Right, yl_proto::MouseButton::Right),
            (MouseButton::Middle, yl_proto::MouseButton::Middle),
            (MouseButton::Back, yl_proto::MouseButton::Back),
            (MouseButton::Forward, yl_proto::MouseButton::Forward),
        ]
        .into_iter()
        .enumerate()
        {
            if self.buttons[index] {
                self.buttons[index] = false;
                self.send(ClientMessage::Input(InputEvent::MouseButton {
                    button: protocol,
                    down: false,
                }));
            }
        }
    }

    fn send_release_all(&mut self) {
        self.release_mouse_buttons();
        self.send(ClientMessage::Input(InputEvent::ReleaseAll));
    }

    fn send(&self, message: ClientMessage) {
        if self.outbound.send(message).is_err() {
            debug!("network task already stopped; dropping input event");
        }
    }

    fn update_title(&mut self) {
        if self.last_title_update.elapsed() < Duration::from_secs(1) {
            return;
        }
        let since = self.stats.since.unwrap_or_else(Instant::now);
        let elapsed = since.elapsed().as_secs_f64().max(0.001);
        let fps = self.stats.frames as f64 / elapsed;
        let mib_per_second = self.stats.bytes as f64 / 1_048_576.0 / elapsed;
        let status = if self.connected {
            format!("{fps:.0} fps · {mib_per_second:.2} MiB/s")
        } else {
            "连接中断".to_string()
        };
        let input = if self.connected && self.input_allowed {
            "可控制"
        } else if self.connected {
            "仅查看"
        } else {
            &self.disconnect_reason
        };
        self.window.set_title(&format!(
            "远联 | {} | {}x{} | {} | {} | TLS 已固定",
            self.host_name, self.remote_w, self.remote_h, status, input
        ));
        if self.stats_log_at.elapsed() >= Duration::from_secs(5) {
            let presented_elapsed = self.presented_at.elapsed().as_secs_f64().max(0.001);
            info!(
                presented_fps = format!("{:.1}", self.presented_frames as f64 / presented_elapsed),
                applied_fps = format!("{fps:.1}"),
                mib_per_second = format!("{mib_per_second:.2}"),
                applied_frames = self.stats.frames,
                presented_frames = self.presented_frames,
                "viewer presentation stats"
            );
            self.stats_log_at = Instant::now();
            self.presented_at = Instant::now();
            self.presented_frames = 0;
        }
        self.stats.frames = 0;
        self.stats.bytes = 0;
        self.stats.since = Some(Instant::now());
        self.last_title_update = Instant::now();
    }
}

fn fit_window(remote_w: u32, remote_h: u32) -> (usize, usize) {
    let max_w = 960.0;
    let max_h = 600.0;
    let scale = (max_w / remote_w as f64)
        .min(max_h / remote_h as f64)
        .clamp(0.25, 1.0);
    (
        (remote_w as f64 * scale).round().max(320.0) as usize,
        (remote_h as f64 * scale).round().max(240.0) as usize,
    )
}
