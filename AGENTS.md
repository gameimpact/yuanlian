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

**M0（Windows 引擎垂直切片）已完成并实机验证（2026-10-18）**：真实采集、图块差分/精修、TLS 指纹固定、SendInput、原生查看器。证据见 `docs/evidence/m0-results.md`。

**质量档 Moonlight 社区预览（2026-10-19）**：按用户授权直接使用上游 Moonlight-qt 6.2.0 + Sunshine 2026.914.233613（GPL-3.0，固定版本/哈希），作为 Windows 外部进程质量预览；本机回环 1080p60 HEVC 实测约 60 fps，约 5 分钟稳定。它**不经过**远联账号/票据/Host 授权/撤权，未嵌入 Flutter，未做两物理机/跨 NAT/1440p/4K/10 分钟验收；仅社区、非商用，不是正式质量模式。证据见 `docs/evidence/quality-preview-moonlight-2026-10-19.md`。

**阶段 B（账号/设备/配对/短时票据/Host 授权闭环）已完成代码与自动化/本机 E2E（2026-10-18，0.2.0，协议 v2）**：持久设备身份、Ed25519 票据、Host 离线验签/防重放/本机确认、读写权限交集、中心撤权（实测 0.86–1.17 秒）、Flutter 账号/设备/配对 UI。证据见 `docs/evidence/b-auth-ticket-2026-10-18.md`。M1 的 Rust FFI/native texture、Linux/Android Host 与三模式仍未完成；M0/B 都不是完整产品，不要扩大宣称。

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
- 构建：`cd server && cargo fmt -- --check && cargo clippy --release --locked -- -D warnings && cargo test --release --locked && cargo build --release --locked`（在 WSL 执行，`CARGO_TARGET_DIR` 建议放 WSL 文件系统）；部署单元模板在 `server/deploy/`。
- 服务端已提供票据公钥 `/api/v1/server/ticket-key`、`/devices/{id}/session-ticket`、活动会话上报/列表/撤销；Host 已实装离线验签、防重放、权限交集与心跳撤权。Flutter 账号/设备/配对 UI 已接入，但未做真实点击登录 E2E；Host 本地授权为 Windows MessageBox，Session 0 服务不可用。
- 票据私钥存在服务端 SQLite `ticket_keys` 表，不写入日志/仓库；轮换用 `YUANLIAN_ROTATE_TICKET_KEY=1` 启动一次。立即吊销已签发票据走中心撤权，不要等待过期。
- WebUI 管理页使用真实 API/受控轮询；在线只由设备令牌 agent 心跳证明。P2P/ICE/STUN/TURN/中继仍未实现，网络页必须显示真实未实现状态，不能加假测试按钮。

## 工具链（本机）

- Rust：`C:\Users\Lenovo\.cargo\bin\cargo.exe`（1.99+, x86_64-pc-windows-msvc）
- Flutter：`C:\Users\Lenovo\dev\flutter\bin\flutter.bat`（3.47.7 stable；产品工程在 `client/`）
- Windows 构建需 `FLUTTER_CMAKE_PATH=C:\Users\Lenovo\dev\cmake\cmake-4.4.4-windows-x86_64\bin\cmake.exe`（本机 VS 未装 CMake 组件）；中文路径会使 Windows AOT/MSBuild 失败，发布构建在 ASCII 副本 `C:\Users\Lenovo\dev\yuanlian-client-build` 生成，源码仍以仓库为准。
- Android release 签名通过仓库外 `YUANLIAN_KEY_PROPERTIES` 指向 key.properties；密钥/密码不得进仓库、日志或文档。当前产物为**预览签名**。
- VS2022 Build Tools + Windows SDK 10.0.26100；Node 24；Android SDK 在 `%LOCALAPPDATA%\Android\Sdk`
- 磁盘紧张，避免无谓的全量重建；不要提交 `target/`、Flutter 缓存、`artifacts/`、`dist/` 或密钥。

## 构建与测试

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked
cargo test --workspace --locked
cargo build --release --locked -p yl-host -p yl-viewer
target/release/yl-host --capture-test out.jpg
target/release/yl-host --test-input          # 移动鼠标到屏幕中心、校验、复位
target/release/yl-host --print-identity      # 稳定设备 ID / TLS 指纹

cd client
dart analyze lib test
flutter test --no-pub
FLUTTER_CMAKE_PATH=... flutter build windows --release --no-pub

# 质量预览（社区/非商用；需先按 third_party/moonlight/README.md 放好两个官方 zip）
powershell -ExecutionPolicy Bypass -File packaging/quality/build-quality-preview.ps1 -Version 0.2.0

# 独立服务端（WSL Ubuntu；不能以根 workspace 测试代替）
cd server
cargo fmt -- --check
cargo clippy --release --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
```

实机验证查看器时，用 PowerShell 截屏确认窗口非空白；不要只凭进程存活判断成功。查看器→Host 鼠标链路可用 `scripts/test-viewer-mouse.ps1`（DPI 感知；先启动 Host `--allow-input` 与查看器并确认窗口存在）。同机键盘会产生输入回环，禁止用同机查看器做按键 E2E。票据 E2E 使用 `yl-viewer --ticket <ticket> --nonce <nonce>`；验证撤权要记录 API 时间与 Host 日志时间差，目标 ≤2 秒。

## 代码约定

- Rust 2021，错误用 `anyhow`（应用层）或明确的错误类型（核心/协议层）。
- 协议改动必须升版本并同步 `docs/protocol.md`；消息长度、解压后尺寸、缓存大小必须有上限。
- 采集、编码、网络、UI 不共享无限阻塞队列；输入优先级高于画面。
- 图块坐标是整数像素；屏幕代际变化时清空缓存并全量刷新。
- 关键路径写单元测试：图块差分/缓存、协议编解码、权限与路径校验。
- 中文文档；代码标识符用英文；注释解释约束，不写“这行做了什么”。

## 当前已知边界

- Windows Host + Windows/Android 主控；单显示器、单会话；Host 顺序处理连接。
- Host TLS 身份持久化；无票据连接默认拒绝，只有显式 `--allow-anonymous` 才进入匿名开发模式。自签名指纹仍需首次人工核对。
- 画面走 TCP，存在队头阻塞；输入/画面/文件共用连接。
- 采集后端主路径为 WGC（`windows-capture` 2.0.1），GDI/XCap 回退；Host `--fps` 默认 30，可请求 60。3200×2000 全屏动态：30 档 Host 管线约 33 fps，60 档约 54.7 fps；回环端到端 30 档约 33 fps，60 档 presented 37–45 fps，未达 60 门槛。不得把 Host 管线或单机 loopback 当作两台物理设备验收；证据见 `docs/evidence/balanced-fps-2026-10-19.md`。
- 图块精修是 JPEG 85→95，不是无损；无滚动复用、块版本/TTL、无损文字。图块哈希/编码已 rayon 并行，查看器 JPEG 解码已并行。
- Host 与查看器均为 Per-Monitor-V2；混合 DPI 未实测。
- 键盘映射为虚拟键码；Unicode/中文通过 `TextInput` 注入，不是远端 IME；同机键盘 E2E 会回环。
- 票据默认 1 小时；Host 心跳每 1 秒，控制面断联 30 秒后租约失效并结束票据会话。服务端票据私钥在 SQLite，未做 HSM/加密存储。
- 本机授权是 MessageBox；无托盘/服务安装/无人值守；Session 0 服务不能显示桌面对话框，必须拒绝而非绕过。
- 质量模式目前只有外部 Moonlight/Sunshine 社区非商用预览，未接入远联票据/撤权、未嵌入 Flutter、未两机验收；完整兼顾/流畅参数、中继、E2EE、Linux 客户端/Host、Android Host、完整文件专项均未实现。
- 文件传输：Host 用 `--file-root` 显式授权单目录；Flutter 支持单文件双向校验、无覆盖原子提交、下载取消、读/写权限；无目录/拖放/续传/SAF/ACL/删除；故障注入仅覆盖单元测试场景。
- Android：release APK 为独立预览签名；捏合/IME/SAF/实体触控未验收；无 Android Host。Windows Mica 仅请求真实 DWM，Flutter 不透明表面下不能宣称整窗材质。
