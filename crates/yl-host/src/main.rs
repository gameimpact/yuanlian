mod capture;
mod files;
mod input;
mod session;
mod tls;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::Parser;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

use yl_proto::format_fingerprint;
use yl_tiles::{TileDiffer, TileSettings};

use session::HostConfig;

#[derive(Debug, Parser)]
#[command(name = "yl-host", version, about = "远联 Windows 被控端（M0 开发版）")]
struct Args {
    /// 监听地址。局域网测试用 0.0.0.0:24800；默认只监听本机。
    #[arg(long, default_value = "127.0.0.1:24800")]
    listen: String,

    /// 允许主控注入键鼠。默认只读；Host 会在会话层拒绝输入。
    #[arg(long)]
    allow_input: bool,

    /// 显示编号：0 = 主显示器，1..N = --list-monitors 的编号。
    #[arg(long, default_value_t = 0)]
    monitor: usize,

    /// 画面采集上限帧率（1-60）。
    #[arg(long, default_value_t = 15)]
    fps: u32,

    /// 变化图块 JPEG 质量（1-100）。
    #[arg(long, default_value_t = 85)]
    quality: u8,

    /// 图块边长（64-256 px）。
    #[arg(long, default_value_t = 128)]
    tile_size: u32,

    /// 静止画面精修质量（1-100）。
    #[arg(long, default_value_t = 95)]
    refine_quality: u8,

    /// 静止多久后精修，毫秒。
    #[arg(long, default_value_t = 600)]
    refine_delay_ms: u64,

    /// 授权给远控文件访问的根目录。未指定时文件功能关闭。
    #[arg(long, value_name = "DIR")]
    file_root: Option<PathBuf>,

    /// 列出显示器及坐标后退出。
    #[arg(long)]
    list_monitors: bool,

    /// 抓取一帧并保存（按扩展名 .png/.jpg），用于验证真实采集。
    #[arg(long, value_name = "FILE")]
    capture_test: Option<PathBuf>,

    /// 移动鼠标到屏幕中心并校验后复位，用于验证 SendInput。
    #[arg(long)]
    test_input: bool,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("yl_host=info,info")),
        )
        .with_target(false)
        .compact()
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();
    input::ensure_dpi_awareness();

    let args = Args::parse();
    if let Some(root) = args.file_root.as_ref() {
        let canonical = std::fs::canonicalize(root)
            .with_context(|| format!("文件根目录无效: {}", root.display()))?;
        if !canonical.is_dir() {
            anyhow::bail!("--file-root 必须是目录: {}", canonical.display());
        }
    }
    if args.list_monitors {
        for monitor in capture::list_monitors()? {
            println!(
                "#{} {}{}  {}x{}  origin=({}, {})",
                monitor.index,
                monitor.name,
                if monitor.primary { " [primary]" } else { "" },
                monitor.width,
                monitor.height,
                monitor.origin_x,
                monitor.origin_y
            );
        }
        return Ok(());
    }

    let tile_settings = TileSettings {
        tile_size: args.tile_size,
        quality: args.quality,
        refine_quality: args.refine_quality,
        refine_delay: Duration::from_millis(args.refine_delay_ms),
    };

    if let Some(path) = &args.capture_test {
        return run_capture_test(path, args.monitor, &tile_settings);
    }
    if args.test_input {
        let info = capture::monitor_info(args.monitor)?;
        return input::verify_mouse_injection(input::ScreenGeometry {
            x: info.origin_x,
            y: info.origin_y,
            width: info.width,
            height: info.height,
        });
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("build Tokio runtime")?;
    runtime.block_on(run_server(args, tile_settings))
}

fn run_capture_test(path: &Path, monitor: usize, settings: &TileSettings) -> Result<()> {
    let (info, image, capture_elapsed) = capture::capture_once(monitor)?;
    let started = Instant::now();
    let mut differ = TileDiffer::new(info.width, info.height, settings.clone())?;
    let update = differ
        .update(&image, true)?
        .context("initial full frame was empty")?;
    let encode_elapsed = started.elapsed();
    save_screenshot(&image, path)?;
    println!(
        "capture OK: display #{} \"{}\" {}x{} origin=({}, {}), capture {:.1} ms; \
         full frame {} tiles, {:.2} MiB JPEG in {:.1} ms; saved {}",
        info.index,
        info.name,
        info.width,
        info.height,
        info.origin_x,
        info.origin_y,
        capture_elapsed.as_secs_f64() * 1000.0,
        update.tiles.len(),
        update.encoded_bytes() as f64 / 1_048_576.0,
        encode_elapsed.as_secs_f64() * 1000.0,
        path.display()
    );
    Ok(())
}

fn save_screenshot(image: &image::RgbaImage, path: &std::path::Path) -> Result<()> {
    let is_jpeg = path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| matches!(extension.to_ascii_lowercase().as_str(), "jpg" | "jpeg"))
        .unwrap_or(false);
    if is_jpeg {
        image::DynamicImage::ImageRgba8(image.clone())
            .to_rgb8()
            .save(path)
            .with_context(|| format!("save JPEG capture to {}", path.display()))?;
    } else {
        image
            .save(path)
            .with_context(|| format!("save capture to {}", path.display()))?;
    }
    Ok(())
}

async fn run_server(args: Args, tile_settings: TileSettings) -> Result<()> {
    let listen: SocketAddr = args
        .listen
        .parse()
        .with_context(|| format!("invalid listen address: {}", args.listen))?;
    let identity = tls::generate_identity()?;
    let fingerprint = format_fingerprint(&identity.fingerprint);
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "windows-host".into());
    let host_id = fingerprint[..16].to_lowercase();

    println!("远联 Host（M0 开发版）");
    println!("设备名: {host_name}");
    println!("TLS SHA-256 指纹: {fingerprint}");
    println!("查看器命令: yl-viewer --connect {listen} --fingerprint {fingerprint}");
    if args.allow_input {
        println!("输入注入: 已启用（--allow-input）");
    } else {
        println!("输入注入: 未启用（仅查看）");
    }
    match args.file_root.as_ref() {
        Some(root) => {
            let canonical = std::fs::canonicalize(root)
                .with_context(|| format!("文件根目录无效: {}", root.display()))?;
            println!("文件访问: 已授权 {}", canonical.display());
        }
        None => println!("文件访问: 未授权（未指定 --file-root）"),
    }

    let listener = TcpListener::bind(listen)
        .await
        .with_context(|| format!("bind {listen}"))?;
    let local = listener.local_addr()?;
    info!(%local, "listening for TLS viewers");

    let acceptor = TlsAcceptor::from(identity.config.clone());
    let config = HostConfig {
        host_id,
        host_name,
        monitor: args.monitor,
        allow_input: args.allow_input,
        fps: args.fps.clamp(1, 60),
        tile_settings,
        file_root: args.file_root.clone(),
    };

    loop {
        let (tcp, peer) = listener.accept().await.context("accept viewer")?;
        info!(%peer, "incoming connection");
        let accept_result =
            tokio::time::timeout(Duration::from_secs(15), acceptor.accept(tcp)).await;
        match accept_result {
            Ok(Ok(stream)) => {
                if let Err(error) = session::run_session(stream, peer, config.clone()).await {
                    warn!(%error, "session failed");
                }
            }
            Ok(Err(error)) => warn!(%error, "TLS handshake failed"),
            Err(_) => warn!(%peer, "TLS handshake timed out"),
        }
        println!("等待下一个查看器连接（端口 {}）", local.port());
    }
}
