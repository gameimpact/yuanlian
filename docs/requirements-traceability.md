# 需求追踪表

状态图例：**已实现并实测** / **已实现待实测** / **部分实现** / **未实现** / **平台不支持**。

最后更新：2026-10-18。此表是唯一事实来源；不得用“代码存在”代替实机结果。当前完成 **M0 Windows 引擎、M1 Flutter Windows/Android 直连客户端（部分）、基础文件传输与平台化 UI 改造**，仍不是完整产品。证据见 [M0](evidence/m0-results.md)、[M1 Flutter](evidence/m1-flutter-client.md)、[Android](evidence/m1-android-client.md)、[文件](evidence/m2-file-transfer.md)、[平台 UI](evidence/m3-platform-ui.md) 与 [Codex 交叉审查](review/codex-cross-review.md)。

## 1. 平台与角色

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| Windows 主控（Flutter 产品壳） | 部分实现（M1 已实测） | `client/`：真实连接/画面/指针/错误处理/主题/地址簿；直连 TLS | Dart 临时协议与 JPEG 合成，未用 Rust FFI 纹理；无账号/设备目录/文件；键盘 E2E 未测 |
| Windows 主控（原生测试查看器） | 部分实现（M0 已实测） | `crates/yl-viewer`：引擎验证工具 | 不是产品 UI，保留用于诊断 |
| Windows 被控 Host | 部分实现（M0 已实测） | `crates/yl-host`：真实采集、图块编码、SendInput、TLS | 非系统服务；无本机授权弹窗/托盘/无人值守；顺序处理单会话 |
| Linux 主控/Host | 未实现 | — | X11/Wayland Portal、PipeWire、systemd |
| Android 主控（Flutter） | 部分实现（模拟器已实测画面）：AOSP M3 TopAppBar/NavigationBar、edge-to-edge、真实桌面、缩放/查看模式、单栏文件页、重试 UI | 触摸输入/IME/SAF/双指捏合未验证；release 仍 debug 签名；无 Android Host |
| Android 被控 Host | 未实现 | — | MediaProjection、输入授权、前台服务、SAF |
| 账号/设备/授权服务 | 部分实现（已部署内网）：邀请码注册、Argon2id 登录、Bearer 会话、设备目录、设备令牌心跳、配对码/授权、审计、Web 后台 | 无 MFA、无 Host 端票据强制、无策略下发/回滚、无备份；Flutter 客户端未接入 |
| 发现/穿透/中继 | 未实现 | — | 后续 M3；M0 仅本机 loopback 实测 |
| Web 管理后台（服务端） | 部分实现（已实测）：设置/登录/邀请/用户/设备/配对码/审计 | 单页开发版，无域名/TLS/CSRF 表单、备份与策略编辑器 |
| Host 本地管理 UI | 未实现 | — | 当前命令行参数 |

## 2. 三种模式

| 需求 | 状态 | 说明 |
|---|---|---|
| 质量模式（Moonlight + Sunshine） | 未实现 | 未集成；不得宣称可用 |
| 兼顾模式（非视频图块、清晰文字、静止精修） | 部分实现 | 图块差分 + JPEG 85 + 600ms 后 JPEG 95 精修（精修仅单元测试）；无无损文字、滚动复用、块版本/TTL、提交呈现策略 |
| 流畅模式（1 Mbps 会话预算、低更新率） | 部分实现 | 静态不发图块；无总预算/拥塞控制/音频/文件分账 |
| 三模式切换、代际、回滚 | 未实现 | 仅单一 `tiles` 模式 |
| 模式内部自动调节 | 未实现 | 固定 CLI 参数 |

## 3. 画面、输入与性能

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| 真实屏幕采集（非模拟） | 已实现并实测 | XCap/GDI；3200×2000 采集 60.3 ms；截图人工确认真实桌面 | GDI 高 CPU；高安全窗口可能黑屏；未做 DXGI/WGC |
| 硬件编码/解码 | 未实现 | — | 当前 JPEG；质量模式需硬编硬解 |
| 多显示器 | 部分实现 | 可选择单个显示器，坐标带原点 | 未做同屏多显/热插拔/负坐标完整测试 |
| 混合 DPI/缩放 | 部分实现 | Host/Viewer 均 Per-Monitor-V2；本机 3200×2000 实测坐标准确 | 混合 DPI、不同缩放比例未实测 |
| 光标独立传输 | 已实现并实测 | 60 Hz `Cursor` 通道；查看器绘制；输入映射 0 px 误差 | 未传光标形状/热点/可见性细节 |
| 鼠标绝对定位/按键/滚轮 | 部分实现 | 绝对坐标、五键、滚轮代码完成；绝对定位已实测 | 按键/滚轮实际点击未做端到端验证；无相对鼠标/拖拽捕获 |
| 键盘注入 | 部分实现 | VK 映射单元测试；Host SendInput 路径已验证 | 同机键盘会导致回环，未做真实按键 E2E；完整远端 IME 组合未实现 |
| Unicode/中文文本提交 | 已实现并实测 | `TextInput` + Windows `SendInput(KEYEVENTF_UNICODE)`；中文+emoji 注入到前台文本框；4096 单元上限、Host 权限校验 | 仅本地文本提交，不是远端 IME 候选窗；Android 软键盘/剪贴板路径未单独实测 |
| 手柄 | 未实现 | — | 后续 |
| 音频/麦克风 | 未实现 | — | 后续 |
| 剪贴板 | 未实现 | — | 后续 |
| 输入权限 Host 侧强制 | 已实现并实测 | 未加 `--allow-input` 时，即使客户端 `--force-input` 也被拒绝，回 `input_denied`，光标不动 | 无按会话权限勾选/弹窗 |
| 断线/失焦/Android 生命周期释放输入 | 已实现待实测 | Host `release_all`；Dart 失焦/路由退出/Android paused 发送 ReleaseAll；恢复默认查看模式 | 同机回环无法可靠验证按键全释放；故障注入未做 |
| Flutter 画面端到端 | 已实现并实测 | Flutter 客户端真实 TLS、首帧、图块显示、错误指纹 UI；约 5 fps、RTT 1 ms（Host 限 5 fps） | Dart JPEG 合成是临时方案；未跨物理机/局域网 |
| Flutter 指针映射 | 已实现并实测 | local(598.5,370) → Host(1496,1090)，与视口 scale 0.33925 一致 | 真实按键/拖拽/滚轮 E2E 未测 |
| Flutter 界面页面 | 部分实现（M3 已实测） | 连接/进度/工作区/文件/设置；Windows Fluent 与 Android AOSP 分支；模式与开发计划；地址簿 | C01/C02 完整校验、C03/C05/C06/C08/C11–C16 未实现 |
| 画面端到端（原生） | 已实现并实测 | 本机 TLS 连接、首帧全量、查看器显示真实桌面（递归镜像） | 未跨物理机/局域网 |
| 采集/编码性能 | 已实测（M0 基线） | 3200×2000、JPEG：9 fps，采集 53.4 ms/帧、编码 30.0 ms/帧，5 秒 5.09 MiB | 远低于质量模式目标；非 1080p 参考数据 |
| 静态零更新 | 已实现待实测 | 图块差分单元测试 | 真实桌面因查看器窗口变化未取得安静统计 |

## 4. 安全与身份

| 需求 | 状态 | 说明 |
|---|---|---|
| TLS 传输加密 | 已实现并实测 | rustls/ring，ALPN `yuanlian/1` |
| Host 证书指纹固定 | 已实现并实测 | 错误指纹连接被明确拒绝（`fingerprint mismatch`） |
| 设备身份/账号/配对 | 未实现 | 证书每次启动临时生成；TOFU 人工核对 |
| 会话票据/防重放/中继令牌 | 未实现 | — |
| 端到端加密（中继不可见明文） | 未实现 | 无中继；TLS 终止于 Host |
| 权限模型（读/写/删除分离等） | 未实现 | 仅“输入允许/仅查看” |
| 撤销 2 秒内生效 | 未实现 | 断开连接会释放输入；无中心撤销 |
| 日志脱敏 | 部分实现 | 不记录键鼠内容；审计/导出未实现 |
| 无人值守/白名单/时段 | 未实现 | — |

## 5. 文件、服务端与运维

| 需求 | 状态 |
|---|---|
| 双栏文件管理、拖放上传 | 未实现 |
| 断点续传/块校验/冲突/幂等 | 未实现 |
| 账号登录/邀请 | 部分实现：Argon2id、邀请码、会话/刷新、停用、密码修改；MFA/恢复码未实现 |
| 策略/配置下发/回滚 | 未实现 |
| 中继与容量管理 | 未实现 |
| 服务端 GUI（S01–S10） | 未实现 |
| 安装包/服务/Docker/备份 | 部分实现：Windows release 目录 + Android release APK + SHA256SUMS；控制服务 systemd 已部署；无正式签名安装器/Docker Compose/备份恢复 |

| Windows Fluent 壳层 | 已实现并实测 | 240/64px NavigationView、48px CommandBar、Segoe UI、32–36px 控件、Mica 请求、最小窗口、快捷键 | 高对比主题/混合 DPI 截图未全部覆盖 |
| Android AOSP 壳层 | 已实现并实测 | edge-to-edge、透明系统栏、TopAppBar + NavigationBar、48dp、安全区 | predictive back/IME 全量未验证 |
| Android 工作区 overflow | 已修复并测试 | 360dp、1.3 字体 widget 测试通过；模拟器实机无黄黑条 | 2.0 字体未截图 |
| Android 缩放/平移 | 部分实现 | 查看/控制模式、放大/缩小/适应、查看模式拖动平移、缩放百分比、双指捏合代码 | 双指捏合未实机手势验证 |
| Windows 上传原子替换 | 已实现并测试 | 同目录临时文件 + flush/sync + SHA-256 + MoveFileExW；6 项文件测试通过 | 旧文件在故障注入下保留未实测 |

## 6. 本轮验证记录

| 测试 | 命令/方式 | 结果 |
|---|---|---|
| Rust 单元测试 | `cargo test --workspace` | 16 passed，0 failed（proto 3、tiles 5、viewer 1、files 6、input 1） |
| 编译 | `cargo check --workspace` | 通过，无警告 |
| 真实采集 | `yl-host --capture-test capture-test.jpg` | 3200×2000，60.3 ms，400 块/0.69 MiB，截图确认真实桌面 |
| SendInput | `yl-host --test-input` | 光标 (1600,1000)，误差 0 px，已复位 |
| TLS + 画面 | Host + 查看器 loopback | 指纹固定成功；首帧全量；窗口显示真实桌面 |
| 输入端到端 | 查看器本地中心 → 远端 | 期望 (1600,1000)，8 次采样均为 (1600,1000) |
| 错误指纹 | 全 AA 指纹 | 明确拒绝：fingerprint mismatch |
| View-only 强制 | `--force-input` + Host 无 `--allow-input` | 光标不动；查看器收到 `InputDenied` |
| 性能基线 | Host 统计 | 约 9 fps、采集 53.4 ms、编码 30.0 ms（原生查看器，3200×2000） |
| Flutter 构建/静态检查 | `dart analyze`, `flutter test`, `flutter build windows` | 0 issue；协议 9 + 响应式 4 全部通过；Windows/Android debug 构建成功 |
| Flutter 输入端到端 | 自检 + 相对指针事件 | (10,10) 精确；指针映射与视口计算一致 |
| Flutter 错误指纹 | 全 AA 指纹 | 进度页标红，错误码 `fingerprint_mismatch` |
| Host 文件路径安全 | `cargo test -p yl-host` | 6 项通过：逃逸/偏移/覆盖/取消清理 |
| Dart 文件协议布局 | `flutter test` | 8 项通过（新增文件消息） |
| Flutter 文件下载 | UI 点击 hello.txt | 本地 SHA-256 `7166d1fa…` 与 Host 一致 |
| Flutter 文件上传 | UI 点击 upload-test.txt | Host 文件 SHA-256 `926eb324…` 与本地一致 |
| Android APK 构建 | `flutter build apk --debug` | 成功（Gradle 路径检查需本机 override） |
| Android 模拟器连接 | 10.0.2.2:24808 | TLS 固定成功；3200×2000 画面；5 fps、RTT 5–7 ms |
| Android 重试 | Host busy → 失败；释放后重连 | 错误页与重试成功 |
| Release 构建（改造前） | ASCII 路径副本 + `flutter build --release` | Windows 客户端已连接验证；APK 49.2 MB 可安装启动；APK 为 debug 签名 |
| Unicode 文本提交 | 自建 Windows 文本框 + Host 日志 | 中文+emoji 注入；`units=16`；截图 `artifacts/review/text-target-screen.png` |
| 控制服务端 | WSL 构建 + 内网 systemd + API 闭环 | health/setup/login/invite/register/device/heartbeat/pairing/connect-info/admin 200；ikev2 未受影响 |
| 平台 UI 改造 | Windows/Android 实机截图 + 响应式测试 | Fluent/AOSP 壳层、文件页、查看/缩放、Android 文件单栏；无 overflow |
| 最终 release E2E | Windows release 客户端 + Host | 连接成功；输入自检 (10,10)；文件能力启用；首页显示 Windows 11 · build 26300 |
| Codex 交叉验证 | gpt-5.6-sol ultra（账户不支持 6.1-sol） | 输出报告与 gpt-6.1-sol ultra 执行提示词并归档；源码审计由执行代理补齐 |

证据归档：`artifacts/m0/`、`artifacts/review/`（本机，未纳入版本库）；文字记录见 evidence 目录与 [Codex 报告](review/codex-cross-review.md)。

## 7. 明确未达到的验收项（摘要）

18 个 Windows/Linux/Android × 模式组合、Android Host、三模式切换中持续传输、文件专项（4 GiB/万文件/断网续传）、质量模式 p95 ≤100 ms、流畅模式 1 Mbps 弱网、2 小时稳定性、安全撤权/重放/路径逃逸、账号/服务端 GUI 均**未开始**；Flutter 产品界面仅完成当前直连功能的平台化子集。当前版本不能对外称“跨平台远控完成”。
