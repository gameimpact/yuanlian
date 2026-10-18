# 远联 YuanLian

跨平台远程控制软件。目标：Windows/Linux/Android 主控以三种模式控制 Windows/Linux Host，并提供可自建的账号、协调、中继与 Web 管理后台。

工作名称：**远联 / YuanLian**。产品名、包名、服务器名集中配置。

## 当前状态（2026-10-18）

**已完成并实机验证：M0 Windows 引擎、M1 Flutter Windows/Android 直连客户端（部分）、基础文件传输。** 仍不是完整产品；完整状态以 [需求追踪表](docs/requirements-traceability.md) 为准。

已实际跑通：

- Rust workspace：协议、图块差分引擎、Windows Host、原生测试查看器；Rust 15 项测试、Flutter 8 项协议测试通过。
- Windows Host：真实采集当前桌面（实测 3200×2000，GDI），变化图块 JPEG 编码，静止 600 ms 后更高清精修；TLS + SHA-256 指纹固定；SendInput 真实鼠标注入；Host 侧强制输入授权。
- Flutter Windows 客户端：真实连接、实时图块画面、鼠标映射（本地 (598.5,370) → Host (1496,1090)，与视口缩放一致）、错误指纹 UI、连接进度、地址簿、设置、会话详情；同机测试出现递归镜像属预期。
- Flutter Android 客户端（部分）：release/debug APK 构建成功；debug APK 在 Android 14 模拟器通过 `10.0.2.2` 连接 Windows Host，真实桌面、5 fps、RTT 5–7 ms；移动端工具栏/状态栏已适配。
- 基础文件传输：Host `--file-root` 显式授权单目录；Flutter 双栏浏览、单文件上传/下载、覆盖确认、SHA-256 校验。实测下载/上传哈希均与源文件一致。
- 安全边界：错误指纹被拒绝；Host 未 `--allow-input` 时，即使客户端强制发送输入，Host 也拒绝并回 `input_denied`。
- 发布构建：Windows release 客户端、Android release APK、Host/原生查看器已放入 `dist/`，附 SHA256SUMS。

证据：[M0 引擎](docs/evidence/m0-results.md)、[M1 Flutter](docs/evidence/m1-flutter-client.md)、[Android](docs/evidence/m1-android-client.md)、[文件传输](docs/evidence/m2-file-transfer.md)。

未实现（不得对外宣称）：账号/设备/配对服务、NAT 穿透/中继、Moonlight/Sunshine 质量模式、Linux 客户端、Android 被控 Host、完整文件专项（目录/拖放/断点续传/权限弹窗）、音频、剪贴板、无人值守、管理后台、正式签名安装器。当前只做直连；测试限本机与模拟器，未做跨物理机/公网。

## 控制服务端

- 代码在 `server/`（独立 Rust 二进制，独立于 Flutter/Rust 客户端的 workspace）。
- 已部署到内网 `192.168.9.66` 的 `/opt/yuanlian`，systemd 仅监听 `127.0.0.1:18080`；通过 SSH 隧道访问 `http://127.0.0.1:18080/admin`。
- 提供账号、邀请码注册、Argon2id 登录会话、设备目录、一次性设备令牌、配对码授权、审计和 Web 管理后台。
- 尚未配置 HTTPS/外网端口；未修改 nginx、防火墙、Docker、ikev2。暴露前必须加 TLS 反向代理。
- Flutter 客户端尚未接入登录/设备目录/配对；详见 [server/README.md](server/README.md) 与 [M4 证据](docs/evidence/m4-control-server.md)。

## 开发构建产物

- `dist/windows/yuanlian_client.exe`：Flutter Windows release 客户端。
- `dist/windows/yl-host.exe`：Windows 被控 Host（M0 引擎）。
- `dist/windows/yl-viewer.exe`：原生测试查看器（诊断用）。
- `dist/android/yuanlian_client-release.apk`：Android 主控；**使用 debug 签名，仅开发测试**。
- `dist/SHA256SUMS`、`dist/yuanlian-m1-win-android.zip`。

中文项目路径会使 Windows release AOT / Gradle 构建失败；发布构建从 ASCII 路径副本生成（当前 `C:/Users/Lenovo/dev/yuanlian-client-build`）。仓库源码仍是唯一事实来源。平台化 UI 改造见 [M3 证据](docs/evidence/m3-platform-ui.md)，Codex 交叉审查见 [Codex 报告](docs/review/codex-cross-review.md)。

## 快速开始

### Windows Host

```bash
cargo build --release
target/release/yl-host --capture-test out.jpg   # 真实采集自检
target/release/yl-host --test-input             # SendInput 自检并复位
target/release/yl-host --listen 127.0.0.1:24800 --allow-input --file-root "C:/授权目录"
```

控制台打印本次启动的 TLS SHA-256 指纹。`--file-root` 可选；未指定时文件功能关闭。开发版证书每次启动重新生成，这是 TOFU，不是最终设备身份方案。

### Flutter Windows 客户端

本机缺少 VS CMake 组件，使用便携 CMake + 本机 Flutter SDK 补丁（仅开发环境）：

```powershell
$env:PATH = "C:/Users/Lenovo/dev/cmake/cmake-4.4.4-windows-x86_64/bin;$env:PATH"
$env:FLUTTER_CMAKE_PATH = "C:/Users/Lenovo/dev/cmake/cmake-4.4.4-windows-x86_64/bin/cmake.exe"
cd client
dart analyze
flutter test
flutter build windows --debug
build/windows/x64/runner/Debug/yuanlian_client.exe
```

开发直连参数（可跳过手工输入）：

```powershell
yuanlian_client.exe --auto-connect-address 127.0.0.1:24800 `
  --auto-connect-fingerprint <64位指纹> --auto-connect-name "开发主机"
```

也可加 `--auto-open-files` 验证文件页。查看器/客户端退出或断线时 Host 释放按键。不要把开发版暴露到公网。

### Android 客户端（开发）

```powershell
cd client
flutter build apk --debug `
  --dart-define=YUANLIAN_AUTO_ADDRESS=10.0.2.2:24800 `
  --dart-define=YUANLIAN_AUTO_FINGERPRINT=<64位指纹>
```

Android 模拟器通过 `10.0.2.2` 访问宿主机；中文路径需 `android/gradle.properties` 的 `android.overridePathCheck=true`。当前 Android 只验证了画面与重试，触摸/IME/SAF 与 Android Host 未完成。

## 目录

```
crates/yl-proto     线上协议（画面/输入/TLS/文件消息）
crates/yl-tiles     图块网格、差分、JPEG、静止精修
crates/yl-host      Windows 被控端（采集/输入/TLS/文件服务）
crates/yl-viewer    原生测试查看器（诊断用）
client/             Flutter Windows/Android 主控（直连 M0 引擎）
docs/adr            架构与许可证决策
docs/protocol.md    协议草案
docs/requirements-traceability.md  需求状态（唯一事实来源）
docs/roadmap.md     阶段路线与风险
server/             独立控制服务端（账号/设备/配对/管理后台）
docs/design         Flutter/Rust 纹理桥设计
docs/review         Codex 交叉审查报告、实施提示词与 Phase 0 源码审计
docs/evidence       M0 / M1 / Android / 文件传输实机记录
scripts             鼠标与文件传输端到端测试脚本
dist/               开发构建产物（已 gitignore）
```

## 已知限制

- 当前客户端直接用 Dart 实现协议与 JPEG 图块合成，是临时方案；正式版必须替换为 Rust 核心 + native texture，避免逐帧 Dart 大对象。
- Windows 采集仍是 GDI；质量模式未实现；3200×2000 实测约 5 fps（Host 限 5 fps 时），不是性能验收数据。
- 单显示器、单会话、顺序处理连接；第二个连接要等前一个结束。
- 文件仅单文件、单目录根、无断点续传/拖放/目录传输/独立文件权限；Windows 覆盖已用 MoveFileExW，但故障注入未实测。
- Android 支持查看/缩放菜单/拖动平移/双指捏合代码；双指捏合未实机手势验证，中文 IME、SAF 文件选择器未实现；Android Host 未实现。
- 键盘映射已实现但同机 E2E 会形成输入回环，未做真实按键验证；中文/emoji 文本提交已实测，完整远端 IME 组合仍未实现。
- Android 触摸输入未验证，Android Host 未实现，APK 非生产签名。

## 许可证

项目采用 AGPL-3.0-or-later，以兼容后续集成的 Sunshine（GPL-3.0）与 moonlight-common-c（GPL-3.0），并保留 RustDesk（AGPL）参考路径。闭源商业发行需另行评估。依赖清单见 [THIRD_PARTY.md](THIRD_PARTY.md)，架构决策见 [ADR-0001](docs/adr/0001-architecture-and-license.md)。
