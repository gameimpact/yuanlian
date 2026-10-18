# AGENTS.md — 远联开发约束

给后续接手的开发 AI / 工程师。先读本文件、`docs/requirements-traceability.md`、`docs/protocol.md` 和 `docs/roadmap.md`。

## 绝对约束

1. **禁止伪造功能**：不得用假设备、假登录、假进度、静态截图或本地模拟画面冒充真实远控。每个按钮必须有真实业务行为；做不到就显示原因。
2. **状态以证据为准**：只有实际构建并通过的项才可标“已实现并实测”。构建通过、单元测试通过、实机通过分别记录，不能互相替代。
3. **更新追踪表**：每次交付同步更新 `docs/requirements-traceability.md`，写明实现文件、测试环境、结果与剩余问题。
4. **安全权限**：读取、写入、删除是不同权限；Host 必须二次校验。不要把设备 ID 当认证凭据。日志不得记录按键、剪贴板、文件内容、令牌或私钥。
5. **加密**：不得自创加密算法。正式数据面必须端到端加密；中继只能看到密文。M0 的 TLS 指纹固定仅是开发期方案。
6. **许可证**：集成 Sunshine/moonlight-common-c 时保留上游声明，锁定版本/子模块，提供对应源码与修改。不要假设进程隔离自动消除许可证义务。

## 当前里程碑

**M0（Windows 引擎垂直切片）已完成并实机验证（2026-10-18）**：真实采集、图块差分/精修、TLS 指纹固定、SendInput、原生查看器。证据见 `docs/evidence/m0-results.md`。下一阶段 M1 是 Flutter 产品 UI + Rust FFI/纹理桥 + 账号/配对/文件基础，见 `docs/roadmap.md`。M0 不是完整产品，不要扩大宣称。

## 平台 UI 约定（M3）

- 颜色/圆角/控件尺寸只通过 `client/lib/src/ui/design_tokens.dart` 与 `platform_theme.dart`；不要把 Material 默认颜色散落到页面。
- Windows：Fluent 风格（Segoe UI Variable、NavigationView/CommandBar、32–36px 控件、4/8px 圆角、原生标题栏、Ctrl+L/Ctrl+,/F1）；Android：AOSP Material 3（edge-to-edge、TopAppBar/NavigationBar、48dp、安全区）。
- 所有页面改动后至少跑 `flutter test test/responsive_test.dart`（1280×800 与 360dp + 1.3 字体）；Android 工作区不得出现 RenderFlex overflow。
- 未实现的缩放方式（如双指捏合）必须在文档/UI 中明确，不要静默宣称支持。
- Codex 交叉验证报告和 Part B 提示词归档在 `docs/review/`；执行改动前先看 `baseline-audit.md`，不要把它人的截图结论当成源码证据。

## 控制服务端（已部署）

- 代码在 `server/`，是独立 Cargo 项目（根 workspace 已 exclude）；在 WSL Ubuntu 24.04 构建 Linux 二进制，再上传到内网服务器，**不要在服务器安装 Rust/大型依赖**（根分区只剩约 540 MB）。
- 服务器 `192.168.9.66` 上只允许操作 `/opt/yuanlian` 和 `yuanlian-server.service`；服务只监听 `127.0.0.1:18080`。**禁止触碰 ikev2/charon（UDP 500/4500）、nginx、Docker、Postgres/Redis/Casdoor、防火墙**。
- 不要在没有 TLS 反向代理时绑定 `0.0.0.0` 或暴露外网；管理员密码不得写入仓库、脚本、日志或文档，只能私下交付。
- 构建：`cd server && cargo fmt && cargo clippy --release -- -D warnings && cargo test --release && cargo build --release`（在 WSL 执行）；部署单元模板在 `server/deploy/`。
- 当前 API/后台已实测；Flutter 登录/设备目录/配对 UI 尚未接入，Host 尚未校验服务端票据。

## 工具链（本机）

- Rust：`C:\Users\Lenovo\.cargo\bin\cargo.exe`（1.99+, x86_64-pc-windows-msvc）
- Flutter：`C:\Users\Lenovo\dev\flutter\bin\flutter.bat`（3.47.7 stable，已解压；产品工程尚未创建）
- VS2022 Build Tools + Windows SDK 10.0.26100；Node 24；Android SDK 在 `%LOCALAPPDATA%\Android\Sdk`
- 磁盘紧张，避免无谓的全量重建；不要提交 `target/`、Flutter 缓存、`artifacts/` 或大文件。

## 构建与测试

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cargo test --workspace
cargo build --release -p yl-host -p yl-viewer
target/release/yl-host --capture-test out.jpg
target/release/yl-host --test-input          # 移动鼠标到屏幕中心、校验、复位
```

实机验证查看器时，用 PowerShell 截屏确认窗口非空白；不要只凭进程存活判断成功。查看器→Host 鼠标链路可用 `scripts/test-viewer-mouse.ps1`（DPI 感知；先启动 Host `--allow-input` 与查看器并确认窗口存在）。同机键盘会产生输入回环，禁止用同机查看器做按键 E2E。

## 代码约定

- Rust 2021，错误用 `anyhow`（应用层）或明确的错误类型（核心/协议层）。
- 协议改动必须升版本并同步 `docs/protocol.md`；消息长度、解压后尺寸、缓存大小必须有上限。
- 采集、编码、网络、UI 不共享无限阻塞队列；输入优先级高于画面。
- 图块坐标是整数像素；屏幕代际变化时清空缓存并全量刷新。
- 关键路径写单元测试：图块差分/缓存、协议编解码、权限与路径校验。
- 中文文档；代码标识符用英文；注释解释约束，不写“这行做了什么”。

## M0 已知边界

- 仅 Windows Host + Windows 原生查看器；单显示器、单查看者；Host 顺序处理会话（第二个连接要等前一个结束）。
- TLS 自签名 + 每次启动重新生成 + 指纹人工核对；无账号/配对/按会话权限。
- 画面走 TCP，存在队头阻塞；输入与画面共用连接。
- 采集后端为 XCap（Windows GDI 路径）；3200×2000 实测约 9 fps、采集约 53 ms/帧、编码约 30 ms/帧。后续替换/补充 DXGI Desktop Duplication 或 Windows Graphics Capture。
- 图块精修是 JPEG 85→95，不是无损；无滚动复用、块版本/TTL、无损文字。
- Host 与查看器均为 Per-Monitor-V2；混合 DPI 未实测。
- 键盘映射仅虚拟键码；中文 IME/Unicode 未实现；同机键盘 E2E 会回环。
- `--force-input` 是隐藏测试开关，仅用于验证 Host 侧拒绝，不得作为产品功能。
- 质量模式（Moonlight/Sunshine）、完整兼顾/流畅参数、服务端、完整文件专项、Linux/Android 均未实现。
- 文件传输：Host 用 `--file-root` 显式授权单目录；Flutter 文件页支持单文件双向校验。无目录传输、拖放、续传、ACL/审计；Windows 覆盖使用 MoveFileExW，故障注入未实测。
- Android：查看/缩放菜单/拖动平移/双指捏合代码；捏合未实机手势验证，IME/SAF 未实现；无 Android Host。Windows Mica 仅请求真实 DWM，Flutter 不透明表面下不能宣称整窗材质。
