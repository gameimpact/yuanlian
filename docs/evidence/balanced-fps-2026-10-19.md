# 兼顾档 30/60 fps 实测记录（2026-10-19）

结论先行：**Host 管线在 3200×2000 全屏动态素材上可做到 30 档平均约 33 fps；60 档 Host 管线约 54.7 fps，未达到“60 档平均 ≥55 fps”的发布门槛；回环端到端 30 档呈现约 33 fps，60 档呈现仅 37–45 fps，未通过。** 本轮没有第二台物理设备、没有 1080p/1440p 独立显示源、没有 10 分钟完整窗口/95% 统计和输入延迟，因此不能把 30 档标为完整验收，也不能把 60 档标为通过。

## 环境

| 项目 | 值 |
|---|---|
| 主机 | Lenovo，Windows 11 26H2 build 26300 x64 |
| CPU | Intel Core Ultra 9 285H，16 核/16 逻辑处理器 |
| GPU | NVIDIA GeForce RTX 5060 Laptop，驱动 32.0.15.7301；另有 GameViewer Virtual Display Adapter |
| 显示 | 3200×2000，165 Hz（当前主显示器） |
| 内存 | 32 GB |
| 采集 | Windows Graphics Capture（`windows-capture` 2.0.1，Rgba8，无光标；光标独立通道） |
| 编码 | 每图块 JPEG，质量 85/95；`yl-tiles` 图块哈希与 JPEG 编码 rayon 并行 |
| 解码/呈现 | 原生查看器 image crate JPEG 解码（rayon 并行）+ minifb；Flutter 统计已改为实际应用帧 |
| 链路 | 同一主机 loopback（不是两台物理设备，不是跨 NAT） |
| 构建 | Rust 1.99.1 release；Host/Viewer 0.2.0 |

动态素材：PowerShell WinForms 无边框全屏窗口，16 ms 定时器重绘渐变背景、24 个移动圆和帧号；真实显示在 Host 屏幕，经 WGC 采集、JPEG 图块编码和 TLS 传输。测试窗口本身会占用 CPU，结果包含该开销。

## 1. Host 采集+编码管线（600 帧，全屏动态）

`yl-host --capture-bench 600 --fps 30|60`，不连接查看器；每帧使用 WGC 源帧，图块差分后编码。`one_second_windows` 是从处理完成时间计算的非重叠 1 秒窗口。

| 请求 | 平均 pipeline fps | 源 fps | ≥阈值窗口 | 最低窗口 | 帧间隔 p50/p95 | 编码 p50/p95 | 数据量 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 30 | 33.1 | 33.1 | 18/18 ≥30 | 33 | 30.24 / 33.18 ms | 7.95 / 14.04 ms | 263,066,347 B / 18.13 s |
| 60 | 54.7 | 54.7 | 7/10 ≥55 | 53 | 18.22 / 22.24 ms | 9.57 / 17.46 ms | 245,118,042 B / 10.97 s |

原始 JSON：`artifacts/bench-wgc-30e.json`、`artifacts/bench-wgc-60f.json`（本机忽略目录）。另测 256 px 图块：30 档 33.0 fps，60 档 54.7 fps，未改善 60 结果。

**判定**：30 档 Host 管线达标（短时、loopback、合成全屏动态）；60 档未达平均 ≥55，记录为失败。Host 管线不是端到端呈现，不能替代客户端验收。

## 2. 回环端到端（Host WGC → TLS → 原生查看器）

查看器 `set_target_fps(60)`；`presented_fps` 只在 `update_with_buffer` 成功后、且本循环有新帧时计数；`applied_fps` 是解码并写入图块缓存的帧率。查看器窗口 960×600（更小窗口用于减少本机合成开销）。

| 请求 | Host 发送 fps | 查看器 applied fps | 查看器 presented fps | 带宽 |
|---|---:|---:|---:|---:|
| 30 | 33.0 | 32.5–32.9 | **33.0–33.2** | 13.0 MiB/s |
| 60 | 53.7–55.0 | 50.2–55.0 | **36.9–44.5** | 13–20 MiB/s |

30 档两个连续 5 秒样本均 ≥33；60 档多个 5 秒样本均低于 55，最低约 37。60 档失败发生在查看器呈现阶段（同机 Host 编码、动画和查看器共享 16 核），不能证明两台物理设备也会失败，但本轮必须按失败记录。日志：`artifacts/e2e-final-host30.log`、`e2e-final-viewer30.log`、`e2e-final-host60.log`、`e2e-final-viewer60*.log`。

## 3. 已实现的性能代码

- `crates/yl-host/src/wgc.rs`：Windows Graphics Capture 后台采集、无光标帧、2 帧有界通道；WGC 不可用时回退 GDI/XCap。
- `crates/yl-host/src/fast_capture.rs`：持久 HDC/DIB GDI 后端（3200×2000 BitBlt 约 38 ms，不足以单独支撑 30 fps，保留 fallback）。
- `crates/yl-tiles/src/lib.rs`：图块哈希与 JPEG 编码 rayon 并行；测试 5 项通过。
- `crates/yl-host/src/capture.rs`：WGC 消费与编码/发送分离；`--capture-bench` 输出原始 JSON 与 1 秒窗口。
- `crates/yl-viewer/src/main.rs`：60 fps 目标、并行 JPEG 解码、真实呈现计数。
- Flutter `workspace_page.dart`：状态栏 FPS 改为实际应用帧计数（不再是 `framesReceived`）。

## 4. 未达到/未验证

- 60 档端到端 presented fps 未达 ≥55；Host 管线也仅约 54.7。
- 30/60 均未跑到 10 分钟；未做 95% 1 秒窗口的完整 10 分钟统计。
- 没有两台物理设备、没有独立 1080p/1440p 显示源；3200×2000 结果不能外推所有配置。
- 没有输入到可见变化延迟、CPU/GPU 占用、队列深度、弱网/丢包、2 小时稳定性。
- Flutter 产品端未做 30/60 动态画面呈现实测；Rust FFI/native texture 仍未实现，Dart 合成路径不是最终性能形态。
- 60 档 3200×2000 全屏动态约 18–20 MiB/s，明显超过 100 Mbps；若要求 60 档需更高带宽或更小分辨率/更强压缩，必须用户可见选择。
- 质量档/流畅档、模式协商/回滚未实现；当前只有 Host `--fps` 请求值（默认 30），没有客户端三档 UI。
