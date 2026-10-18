# M0 实机验证记录（Windows）

日期：2026-10-18。所有结果来自本机真实运行，不是模拟或编造。测试机：Windows 10.0.26300 x64，NVIDIA RTX 5060 Laptop GPU，显示器 B160QAN04.U 3200×2000（主屏），Rust 1.99.1 MSVC，Flutter 3.47.7 已安装但尚未接入产品 UI。

## 构建与单元测试

```
cargo check --workspace   -> 通过，无警告
cargo test --workspace    -> 9 passed, 0 failed
cargo build --release -p yl-host -p yl-viewer -> 成功
```

单元测试覆盖：协议帧往返、超长消息拒绝、指纹解析；图块首帧全量/静态空帧、仅变化块、静止精修一次、尺寸变化代际递增；按键映射。

## 真实采集

```
yl-host --capture-test capture-test.jpg
```

结果：`display #1 "B160QAN04.U" 3200x2000 origin=(0,0)`，单次采集 60.3 ms；全屏 400 个 128px 图块，JPEG 85 共 0.69 MiB，编码 91.4 ms。保存的截图经人工检查为真实当前桌面（非黑屏/占位图）。

## 真实输入注入

```
yl-host --test-input
```

结果：`SendInput OK: cursor moved to (1600,1000), error 0x0 px, restored to (2521,1368)`。

## TLS + 画面端到端

本机 Host（`--allow-input`）与原生查看器通过 `127.0.0.1:24800` 连接：

- 查看器日志：TLS 指纹固定成功；Welcome 显示 3200×2000、`mode=tiles`、输入允许。
- 首帧 `full=true`，查看器成功解码/合成并在窗口中显示真实桌面（同机出现递归镜像，属预期）。
- Host 统计（约 10 fps 目标，镜像画面持续变化）：9.0 fps，5 秒 2008 块/5.09 MiB，采集约 53.4 ms/帧，编码约 30.0 ms/帧。
- 截图证据：`artifacts/m0/viewer-screen.png`（未纳入版本库，避免桌面内容外泄）。

## 查看器 → Host 输入链路

DPI Per-Monitor-V2 下，把本地鼠标放到查看器窗口客户区中心（客户区 1440×900，窗口原点 (62,107)）：

- 期望远端坐标：`(1600,1000)`。
- 连续 8 次采样（每 150 ms）实际光标：`(1600,1000)`，无漂移。
- 结论：minifb 坐标 → 查看器映射 → TLS ClientMessage::Input → Host SendInput 全链路真实工作，误差 0 px。

## 安全边界

1. **错误指纹**：用全 `AA` 指纹连接，查看器报
   `TLS handshake failed: ... Host certificate fingerprint mismatch`，连接失败；Host 记录 `received fatal alert: HandshakeFailure`。
2. **Host 未授权输入**：Host 不带 `--allow-input` 启动，查看器正常连接但 Welcome 为仅查看；用测试专用 `--force-input` 绕过客户端限制，Host 仍不注入，光标停在本地目标 `(1027,802)`，查看器收到 `InputDenied` 并记录日志。
3. **按键释放代码路径**：会话结束时 Host 调用 `InputInjector::release_all` 并记录“held keys released”。同机键盘回环无法可靠实测按键全释放，标记为待专项验证。

## 尚未验证/不可宣称

- 跨物理设备、局域网、公网、中继、IPv6/CGNAT。以上均为本机 loopback。
- 键盘实际输入、中文 IME、剪贴板、音频、文件、手柄。
- 静态画面真实零更新率（测试时查看器窗口自身在变化，未取得安静桌面统计）。
- 静止精修在真实屏幕上的视觉一致性（仅单元测试）。
- 2 小时稳定性、内存增长、多显示器/混合 DPI/旋转、质量模式与 Moonlight/Sunshine。
