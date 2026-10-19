# 远联 YuanLian

跨平台远程控制软件。目标：Windows/Linux/Android 主控以三种模式控制 Windows/Linux Host，并提供可自建的账号、协调、中继与 Web 管理后台。

工作名称：**远联 / YuanLian**。当前源码开发版本 **0.3.0**，协议 **v3**；Linux 控制服务端 0.3.0 已发布并支持一键安装。Windows/Android/Linux 桌面客户端安装资产仍为 **0.2.0 / v2**，必须与配套版本一起使用，不能与 0.3.0 服务端混装。

## 0.3.0：Host 授权质量串流与流畅模式

质量模式使用视频串流。账号与设备页可选择“质量 · 视频串流 · Host 票据授权”，由 Host 验票、本机确认后启动仅信任本次 Moonlight 身份的专用 Sunshine，结束/撤权会关闭它。Host 需配置 `--sunshine <固定版Sunshine.exe路径>`，键鼠另需明确 `--allow-input`。不用读取现有配对私钥或手动 PIN；画面仍在外部窗口。

流畅模式可在连接表单或账号页选择：低带宽渐进图块、控制优先、双向约 1 Mbps 预算、文件限速、背压及阻塞调节。它不承诺 30/60 整屏 FPS，不替代兼顾档性能要求。音频、QUIC 和会话内热切换仍待实现。

已跑通真实 Flutter → Host → Sunshine → Moonlight，截图浮层 1080p HEVC 瞬时 60.06 fps；撤权监听消失 0.526 秒。完整使用方法、构建和测试边界见 [交付证据](docs/evidence/quality-host-flow-2026-10-19.md)。本轮已更新 Linux 控制服务端 0.3.0 一键安装与 GitHub Release；未更新生产服务、桌面/Android 安装包。

## 0.2.0 历史实现与发布资产（2026-10-19）

**已有真实实现**：Windows Host 的画面/输入/文件引擎、Flutter Windows/Android 客户端、持久设备身份、账号登录与设备目录、配对、Ed25519 短时会话票据、Host 二次校验与本机确认、中心撤权、独立控制服务端，以及 Windows/Android/服务端安装产物。

仍**不是完整产品**：Linux 客户端、Android 被控 Host、正式三模式、公网中继、音频/剪贴板/手柄、MFA、完整文件专项与跨物理机验收未完成。质量档以 **Moonlight 社区、非商用预览**单独提供：使用上游 Moonlight-qt 6.2.0 + Sunshine 2026.914.233613 的外部进程，不经过远联账号/票据/本机授权/撤权。完整状态以 [需求追踪表](docs/requirements-traceability.md) 为准；未完成项见 [剩余工作](docs/remaining-work.md)。

### 已实际跑通（本轮）

- 根 Rust：`cargo fmt --check`、`clippy --workspace --all-targets`、28 项测试通过；Host/Viewer release 构建通过。
- Flutter：`dart analyze lib test` 0 issue；48 项测试通过（协议、帧边界、原子提交、服务端客户端、质量预览参数/定位、响应式/平台状态）。
- 服务端：WSL Ubuntu 独立构建；6 项测试通过；`cargo fmt --check`、`clippy -D warnings` 通过；`server/Cargo.lock` 已提交。
- 真实票据 E2E：服务端签发 → Host 离线验签 → 本机确认（测试用 `--auto-approve`）→ Flutter/原生查看器出画；Host 日志显示账号 `admin`、权限“查看、控制、读取文件、写入文件”。
- 撤权 E2E：中心撤销后 Host 在 **0.86–1.17 秒**内结束会话、释放输入并发送 `revoked` 原因（目标 ≤2 秒）。
- 防重放：同一票据第二次连接被 `ticket_replay` 拒绝；票据模式下的匿名连接被 `unauthorized` 拒绝。
- Windows 持久身份：两次启动指纹一致；半缺失身份文件报错而非静默换身份。
- Android：arm64-v8a release APK 使用**独立预览签名**（非 debug 签名），`apksigner` 校验通过；模拟器安装/启动待本轮补充记录。
- 产物：Windows 便携 zip/安装器、Android arm64/universal 预览 APK、Linux 客户端 deb/便携 tar.gz、Linux 服务端 tar.gz 位于 `dist/0.2.0/`；质量预览包位于 `dist/0.2.0/quality-preview/`，主安装器不包含 GPL 二进制。

质量档社区预览：同机回环 1920x1080 60 fps HEVC、20 Mbps，约 5 分钟官方浮层 60.05 fps，Host 处理延迟 1.7/4.6/2.0 ms，丢帧约 0.002%；未做两物理机/跨 NAT/1440p/4K/10 分钟验收，且不经过远联安全闭环。证据：[质量预览](docs/evidence/quality-preview-moonlight-2026-10-19.md)。

证据：[阶段 B 证据](docs/evidence/b-auth-ticket-2026-10-18.md)、[M0 引擎](docs/evidence/m0-results.md)、[M1 Flutter](docs/evidence/m1-flutter-client.md)、[Android](docs/evidence/m1-android-client.md)、[文件传输](docs/evidence/m2-file-transfer.md)、[平台 UI](docs/evidence/m3-platform-ui.md)。

### 未实现（不得对外宣称）

- 正式/嵌入式的质量模式：当前只有外部 Moonlight 社区预览，未接入远联票据/撤权、未嵌入 Flutter、未做两机验收；完整兼顾/流畅模式与模式切换仍未实现。
- Linux 客户端/Host 的构建与实机；Android 被控 Host；Android 完整 SAF/IME/实体触控验收。
- NAT 穿透、授权中继、QUIC、面向中继的端到端加密；2 小时/弱网/4 GiB 文件等完整验收。
- 音频、麦克风、剪贴板、手柄、相对鼠标、完整多显示器/混合 DPI。
- MFA/恢复码、完整 S01–S10 后台、策略下发/回滚、备份恢复、告警。
- Linux 实机验收（已在 WSL 构建出客户端 deb/便携包并做 ldd/Xvfb 检查，但没有真实 X11/Wayland 桌面；Host 未实现）。

### 质量模式使用视频串流（Moonlight 社区预览，仅 Windows）

质量预览单独分发，主安装器不含 GPL 二进制：

1. 解压 `dist/0.2.0/quality-preview/yuanlian-quality-preview-0.2.0-windows-x64.zip` 到远联安装目录的 `quality-preview`；
2. 被控机运行 `sunshine\sunshine.exe`，在 Moonlight 中完成 PIN 配对；
3. 打开远联 → 首页 → 模式与开发计划 → 质量模式（视频串流 · Moonlight 社区预览）→ 打开预览；阅读并勾选外部串流安全边界。
4. 可点击“打开 Moonlight 配对与应用列表”在上游完成配对，关闭该窗口，再填写实际被控机地址，选择请求参数并启动串流。实际 FPS/编码/解码以 Moonlight 性能浮层为准。
5. 每次启动先核对客户端内置的固定组件清单；配对后可“读取 Host 应用列表”选择真实应用，也可手动输入。查询支持取消与超时。
6. 可结束本页启动的 Moonlight，正常返回也会提示结束；Windows Job 保证远联异常退出时清理受管客户端。不会关闭其他客户端、Sunshine 或远端应用。进程运行不代表已连接/出画，也不代表中心撤权已覆盖。

它使用 Moonlight 自己的配对/加密，不经过远联账号、票据、Host 本机确认和中心撤权；仅限可信局域网、社区非商用。详见 `packaging/quality/README.zh-CN.md`。

启动器修复与修改顺序见 [质量串流审查报告](docs/review/quality-streaming-review-2026-10-19.md)，后续 [加固证据](docs/evidence/quality-hardening-2026-10-19.md) 记录 Job、284 文件完整性、真实应用查询及安全打包。Dart analyze 无问题、Flutter 69 项、独立 server 12 项、原生/打包测试与 Windows Release 构建通过；没有重测串流性能或替换既有安装包。正式 Host 授权桥尚缺，控制面拒绝非 tiles 票据申请。

## 控制服务端

- 代码在 `server/`，独立 Cargo 项目；在 WSL Ubuntu 构建 Linux 二进制。
- 已部署内网 `192.168.9.66` 的 `/opt/yuanlian`，只监听 `127.0.0.1:18080`；通过 SSH 隧道访问 `/admin`。本轮未操作该服务器。
- 账号、邀请注册、Argon2id、Bearer 会话、设备目录、一次性设备令牌、配对、grant、审计、Web 后台。
- **0.2.0 新增**：Ed25519 票据密钥与 `/api/v1/server/ticket-key`、`/devices/{id}/session-ticket`、活动会话上报/列表/撤销；心跳返回 `revoked_sessions` 与 `owner_active`。
- 尚未配置 HTTPS/外网端口；生产必须加 TLS 反向代理。部署包见 `dist/0.2.0/server-linux-x86_64/`。

## 快速开始

2026-10-19 源码复核与后续开发要求见 [未实现功能续开发提示词](未实现功能_续开发提示词_2026-10-19.md)：33 组未完成/待验收项、逐页任务、兼顾档真实 30–60 fps 门槛，以及暂时无法交付的原因与前置条件。该文档不代表所列新功能已经实现。

### Windows Host（票据模式）

1. 启动控制服务端，客户端登录后“登记被控设备”，填写 Host 地址与指纹；页面只显示一次设备令牌。
2. 在 Host 上获取稳定身份并启动：

```powershell
target\release\yl-host.exe --print-identity
$env:YUANLIAN_DEVICE_TOKEN = "<设备令牌>"
target\release\yl-host.exe --listen 0.0.0.0:24800 `
  --server-url http://<服务端>:18080 `
  --allow-input --file-root "C:\授权目录"
```

Host 启动时会拉取票据公钥并检查设备注册；票据校验、权限交集和本机授权对话框都通过后才出画。默认不自动放开输入/文件；`--file-read-only` 只允许读取。

### 开发期匿名直连（仅本机测试）

```powershell
target\release\yl-host.exe --listen 127.0.0.1:24800 --allow-anonymous --auto-approve `
  --allow-input --file-root "C:\授权目录"
```

未显式 `--allow-anonymous` 时 Host 拒绝所有无票据连接。`--auto-approve` 只用于隔离测试/专用主机，会打印告警。

### Flutter Windows 客户端

本机 VS Build Tools 缺 CMake 组件，使用便携 CMake（Flutter SDK 已打补丁读取 `FLUTTER_CMAKE_PATH`）：

```powershell
$env:FLUTTER_CMAKE_PATH = "C:/Users/Lenovo/dev/cmake/cmake-4.4.4-windows-x86_64/bin/cmake.exe"
cd client
dart analyze lib test
flutter test
flutter build windows --release --no-pub
```

中文路径仍会导致 Windows AOT/MSBuild 路径乱码，发布构建在 ASCII 副本 `C:/Users/Lenovo/dev/yuanlian-client-build` 生成；源码是本仓库。

### Android 客户端

```powershell
# 签名配置在仓库外，通过环境变量指向 key.properties
$env:YUANLIAN_KEY_PROPERTIES = "C:/Users/Lenovo/dev/yuanlian-keys/key.properties"
flutter build apk --release --target-platform android-arm64
```

APK 使用独立预览签名；正式发布前必须由用户提供并保管正式密钥。签名变更不能静默覆盖安装清数据。

### Linux 控制服务端：一键安装

**这是服务端**，提供账号、设备、授权和 Web 管理后台。适用于运行 systemd 的 Ubuntu/Debian x86_64；使用预编译包，无需 Rust/Flutter/Docker。

在线一键安装（Linux 控制服务端）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gameimpact/yuanlian/v0.3.0/install.sh)
```

脚本下载 v0.3.0 服务端包、核对发布清单中的 SHA-256、调用安装脚本并检查 systemd 与 `/health`。需要时自动调用 sudo；已有部署会提示备份和手动升级。可在命令末尾加 `--check`，只下载校验，不安装。

v0.3.0 Release 目前只提供 Linux 控制服务端；Windows/Android/Linux 桌面客户端安装包仍为 v0.2.0，不能与 0.3.0 服务端混装。

离线安装：将 `dist/0.3.0/server-linux-x86_64/yl-server-0.3.0-linux-x86_64.tar.gz` 复制到 Linux 当前目录，然后执行：

```bash
tar -xzf yl-server-0.3.0-linux-x86_64.tar.gz && sudo bash ./yl-server-0.3.0-linux-x86_64/scripts/install.sh
```

安装后检查：`curl --fail http://127.0.0.1:18080/health`。默认只监听本机；远程管理通过 SSH 隧道访问 `/admin`。详细步骤见 [服务端安装说明](packaging/server/README.zh-CN.md)。Linux 桌面客户端另行安装，Linux 被控 Host 尚未实现。

## 控制服务端源码构建（开发用）

```bash
cd server
cargo fmt -- --check
cargo clippy --release --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
YUANLIAN_DB=/var/lib/yuanlian/yuanlian.db YUANLIAN_BIND=127.0.0.1:18080 ./target/release/yl-server
```

部署单元与脚本见 `server/deploy/`、`dist/0.2.0/server-linux-x86_64/`。

## 目录

```
crates/yl-proto     协议 v2、权限位、Ed25519 票据 claims/验签
crates/yl-tiles     图块网格、差分、JPEG、静止精修
crates/yl-host      Windows 被控端：持久身份、票据校验、本机授权、采集/输入/文件、撤销心跳
crates/yl-viewer    原生测试查看器（支持 --ticket/--nonce 诊断）
client/             Flutter Windows/Android 主控：账号/设备/配对、票据连接、工作区、文件
docs/               协议、路线图、追踪表、证据、审查
server/             独立控制服务端（账号/设备/配对/票据/撤销/后台）
packaging/          可重复打包脚本（Windows NSIS、Android、服务端）
dist/               本地产物（gitignore）
```

## 已知限制

- Flutter 画面/解码仍在 Dart；Rust FFI + native texture 未完成。
- 采集主路径为 WGC；60 档端到端未达标，详见 `docs/evidence/balanced-fps-2026-10-19.md`。
- 单显示器、单会话、顺序处理连接；画面/输入/文件共用 TCP。
- 文件单根目录、单文件、无续传/目录/拖放/SAF；删除权限未开放。
- Host 的本机授权是 Windows MessageBox；尚未做托盘/服务/无人值守策略。Session 0 服务无法显示桌面对话框，会被拒绝。
- Android 双指捏合、完整 IME/SAF、实体触控未验收；无 Android Host。
- 账号 UI 已实现并有组件/HTTP mock 测试，但本轮未做“真实点击登录→配对→连接”的完整 UI 自动化；服务端 API 与票据连接已实测。
- 安装包未做代码签名（Windows），Android 仅预览签名。

## 许可证

项目采用 AGPL-3.0-or-later，以兼容后续集成的 Sunshine（GPL-3.0）与 moonlight-common-c（GPL-3.0），并保留 RustDesk（AGPL）参考路径。闭源商业发行需另行评估。依赖清单见 [THIRD_PARTY.md](THIRD_PARTY.md)，架构决策见 [ADR-0001](docs/adr/0001-architecture-and-license.md)。
