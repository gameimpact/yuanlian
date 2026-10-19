mod approval;
mod capture;
mod control;
mod fast_capture;
mod files;
mod flow;
mod input;
mod quality;
mod session;
mod tls;
mod wgc;

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use clap::Parser;
use tokio::net::TcpListener;
use tokio_rustls::TlsAcceptor;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

use yl_proto::{device_id_from_fingerprint, format_fingerprint};
use yl_tiles::{TileDiffer, TileSettings};

use control::ControlPlane;
use session::HostConfig;

#[derive(Debug, Parser)]
#[command(name = "yl-host", version, about = "远联 Windows 被控端（M0 开发版）")]
struct Args {
    /// 监听地址。局域网测试用 0.0.0.0:24800；默认只监听本机。
    #[arg(long, default_value = "127.0.0.1:24800")]
    listen: String,
    /// 固定官方 Sunshine.exe；仅在 quality 票据授权期间启动专用实例。
    #[arg(long)]
    sunshine: Option<PathBuf>,
    #[arg(long, default_value_t = 48189)]
    quality_port: u16,

    /// 允许主控注入键鼠。默认只读；Host 会在会话层拒绝输入。
    #[arg(long)]
    allow_input: bool,

    /// 显示编号：0 = 主显示器，1..N = --list-monitors 的编号。
    #[arg(long, default_value_t = 0)]
    monitor: usize,

    /// 画面采集上限帧率（1-60）。
    #[arg(long, default_value_t = 30)]
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

    /// 文件只读：仍然允许列目录/下载，禁止上传与覆盖。
    #[arg(long)]
    file_read_only: bool,

    /// 控制服务端基础地址，例如 http://127.0.0.1:18080。
    #[arg(long, value_name = "URL")]
    server_url: Option<String>,

    /// 控制服务端签发的设备令牌。优先使用环境变量 YUANLIAN_DEVICE_TOKEN，
    /// 避免出现在 shell 历史/进程列表中。
    #[arg(long, value_name = "TOKEN")]
    device_token: Option<String>,

    /// 允许未经账号/配对票据的匿名直连。仅用于开发，启动时会明确告警。
    #[arg(long)]
    allow_anonymous: bool,

    /// 跳过本机授权对话框。仅用于自动化测试/专用主机，必须显式开启。
    #[arg(long)]
    auto_approve: bool,

    /// TLS 身份目录；默认 %LOCALAPPDATA%\YuanLian\identity。身份在重启间保持不变。
    #[arg(long, value_name = "DIR")]
    identity_dir: Option<PathBuf>,

    /// 打印持久设备 ID 与 TLS 指纹后退出，用于在控制服务端登记设备。
    #[arg(long)]
    print_identity: bool,

    /// 列出显示器及坐标后退出。
    #[arg(long)]
    list_monitors: bool,

    /// 抓取一帧并保存（按扩展名 .png/.jpg），用于验证真实采集。
    #[arg(long, value_name = "FILE")]
    capture_test: Option<PathBuf>,

    /// 运行 Host 侧采集+图块差分管线基准并输出 JSON，不连接查看器。
    #[arg(long, value_name = "FRAMES")]
    capture_bench: Option<u64>,

    /// 基准时每帧强制全量编码，用于测量最坏情况；不代表真实变化率。
    #[arg(long)]
    capture_bench_full: bool,

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
    if let Some(frames) = args.capture_bench {
        return capture::benchmark(
            args.monitor,
            frames,
            args.fps,
            tile_settings,
            args.capture_bench_full,
        );
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

    if args.auto_approve {
        warn!("--auto-approve 已开启：本机授权对话框会被跳过，仅应用于隔离测试/专用主机");
    }
    if args.file_read_only && args.file_root.is_none() {
        warn!("--file-read-only 未配合 --file-root，文件功能仍关闭");
    }
    let identity_dir = args
        .identity_dir
        .clone()
        .unwrap_or_else(tls::default_identity_directory);
    let identity = tls::load_or_create_identity(&identity_dir)?;
    let fingerprint = format_fingerprint(&identity.fingerprint);
    let device_id = device_id_from_fingerprint(&fingerprint);
    println!("远联 Host 设备 ID: {device_id}");
    println!("TLS SHA-256 指纹: {fingerprint}");
    if args.print_identity {
        println!("身份目录: {}", identity_dir.display());
        return Ok(());
    }
    let device_token = args
        .device_token
        .clone()
        .or_else(|| std::env::var("YUANLIAN_DEVICE_TOKEN").ok());
    let control = match args.server_url.as_deref() {
        Some(url) => {
            let token = device_token
                .as_deref()
                .context("--server-url 需要 --device-token 或环境变量 YUANLIAN_DEVICE_TOKEN")?;
            Some(ControlPlane::connect(url, token, &device_id)?)
        }
        None => {
            if !args.allow_anonymous {
                bail!(
                    "未配置 --server-url，且未显式指定 --allow-anonymous；\
                     为安全默认拒绝所有连接。开发期直连请显式加 --allow-anonymous。"
                );
            }
            None
        }
    };
    if args.server_url.is_some() && args.allow_anonymous {
        warn!("已同时启用票据校验与匿名直连；匿名连接会明确标记为开发模式");
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("build Tokio runtime")?;
    runtime.block_on(run_server(args, tile_settings, identity, control))
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

async fn run_server(
    args: Args,
    tile_settings: TileSettings,
    identity: tls::TlsIdentity,
    control: Option<Arc<ControlPlane>>,
) -> Result<()> {
    let listen: SocketAddr = args
        .listen
        .parse()
        .with_context(|| format!("invalid listen address: {}", args.listen))?;
    let fingerprint = format_fingerprint(&identity.fingerprint);
    let host_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "windows-host".into());
    let host_id = device_id_from_fingerprint(&fingerprint);
    if let Some(control) = control.as_ref() {
        if control.device_id() != host_id {
            bail!(
                "控制服务设备 ID 与本地身份不一致：server={} local={host_id}",
                control.device_id()
            );
        }
    }

    println!("远联 Host（阶段 B 开发版）");
    println!("设备名: {host_name}");
    println!("设备 ID: {host_id}");
    println!("TLS SHA-256 指纹: {fingerprint}");
    println!("查看器命令: yl-viewer --connect {listen} --fingerprint {fingerprint}");
    println!(
        "授权模式: {}",
        if control.is_some() {
            "账号/配对签发的短时会话票据 + 本机确认"
        } else {
            "匿名开发直连（--allow-anonymous，未经账号/配对授权）"
        }
    );
    if args.allow_input {
        println!("输入注入: 已启用（--allow-input），仍需票据/本机权限允许");
    } else {
        println!("输入注入: 未启用（仅查看）");
    }
    match args.file_root.as_ref() {
        Some(root) => {
            let canonical = std::fs::canonicalize(root)
                .with_context(|| format!("文件根目录无效: {}", root.display()))?;
            println!(
                "文件访问: {} {}",
                if args.file_read_only {
                    "只读"
                } else {
                    "读取+写入"
                },
                canonical.display()
            );
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
        file_read_only: args.file_read_only,
        allow_anonymous: args.allow_anonymous,
        auto_approve: args.auto_approve,
        control_plane: control,
        quality: args.sunshine.as_ref().map(|exe| quality::QualityConfig {
            executable: exe.clone(),
            bind: listen.ip(),
            port: args.quality_port,
        }),
    };

    loop {
        let (tcp, peer) = listener.accept().await.context("accept viewer")?;
        tcp.set_nodelay(true)?;
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
