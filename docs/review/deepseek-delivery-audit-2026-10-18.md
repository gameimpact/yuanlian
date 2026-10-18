# DeepSeek 交付现状核查

日期：2026-10-18。核查基线：`9d473aa`，开始检查时工作区干净。

## 结论与证据边界

当前交付是有真实实现的 Windows 远控原型、Flutter Windows/Android 直连客户端、单文件传输和独立控制服务端，不是完整跨平台产品。M0 有既有实机证据；M1 的 Flutter/Rust 桥、账号授权闭环和 Host 产品化尚未达到路线图退出条件。证据文件名中的 M2/M3/M4 不能解释为对应路线图阶段已完成。

仓库只有一次初始提交，作者为 GAMEIMPACT，无法从 Git 独立证明每项改动由 DeepSeek 完成。本报告把“DeepSeek 完成的部分”解释为当前目录的交付内容。

检查方式：阅读 AGENTS、原始完整提示词、追踪表、协议、路线图、基线审计及关键 Rust/Dart/服务端源码；本轮运行构建、静态检查和已有测试，另运行真实屏幕采集。既有文档所述 UI/输入/服务端部署实测只作为历史记录，本轮没有重做完整远控窗口、跨物理机、Android 手势或在线服务器验证。未修改生产代码、未部署、未操作内网服务器。

## 已有实现

| 部分 | 源码依据 | 当前判断 |
|---|---|---|
| Windows Host 与原生查看器 | `crates/yl-host`、`yl-viewer`、`yl-tiles` | 真实采集、JPEG 图块差分/精修、TLS 指纹固定、鼠标/键盘注入、光标消息；构建与单元测试本轮通过。完整会话实机依据既有 M0 记录 |
| Flutter 直连客户端 | `client/lib/src/net`、`ui/home_page.dart`、`connection_progress_page.dart`、`workspace_page.dart` | 地址+指纹连接、真实协议/图块解码、查看/控制、缩放平移、错误与重试；不是 Rust FFI/native texture 路径 |
| 基础文件传输 | `yl-host/src/files.rs`、`session.rs`、`ui/file_browser_page.dart` | Host 单根目录、列表/上传/下载、大小与 SHA-256 核对、上传临时文件提交；Windows 双栏与 Android 紧凑布局代码存在 |
| 文本提交 | `InputInjector::send_text`、`TextInput` | Unicode/emoji 已有实现与历史实测记录；本轮 Unicode 单元测试通过；不等于完整远端 IME |
| 平台 UI | `design_tokens.dart`、`platform_theme.dart`、`home_shell.dart`、Windows runner、Android MainActivity | Fluent 风格/AOSP 分支、快捷键、DWM 请求等有实现；响应式测试通过不等于全部平台/状态验收，页面仍有硬编码样式 |
| 控制服务端和开发版后台 | `server/src/main.rs`、`server/admin/index.html` | Argon2id、邀请注册、会话/刷新、停用/改密、设备目录/令牌心跳、配对码/授权、审计都有真实处理器；历史内网部署记录存在，当前在线状态未复核 |

## 发现的问题（源码确认，未进行故障注入）

1. **P1：输入内容进入 debug 日志。** `crates/yl-host/src/session.rs:189` 使用 `?event`，记录前 3 次及每 200 次输入事件，包含 `Key { vk, down, extended }`。启用 debug 后会记录按键，与 AGENTS 的日志约束冲突；默认 info 不会触发该行。应仅记录计数和结果，禁止序列化输入负载。
2. **P1：中心授权尚不能约束真实远控。** `ClientHello` 没有服务端票据；`session.rs:85` 的输入许可仅为 `config.allow_input && hello.request_input`。文件访问仅由 `--file-root` 决定。服务端 `connect_info` 返回地址/指纹/权限，没有 Host 可验证的会话凭证；Flutter 仍直接连接 Host。因此账号停用、授权过期/撤销不能终止已知地址的直连或活动会话，也没有读/写/删除分权。属于已知但阻断产品验收的缺口。
3. **P1：Flutter 解码积压没有上限。** `workspace_page.dart:339` 每帧追加到 `_decodeChain`，没有待处理帧数/字节上限或背压；解码慢于接收时，Future 闭包持续持有帧数据并累积延迟。需要针对增量图块设计有界合并或丢弃后请求全量帧，不能任意丢差分帧。
4. **P2：下载取消没有传到实际工作任务。** `files.rs:235-251` 将 DownloadReader 从 map 取出，`session.rs:317` 将它移交 `spawn_blocking`；`cancel_task` 只删除 map 条目，`DownloadReader::stream` 没有取消标志。`FileCancel` 因而无法停止已经开始的下载，后台仍读取/发送，直到 EOF 或连接关闭。需要真实任务注册及取消信号。
5. **P2：客户端下载提交存在目标丢失窗口。** `file_browser_page.dart:307-311` 在目标存在时先 `delete` 再 `rename`。虽然开始时 `_uniqueLocalPath` 避开已有文件，但下载期间其他进程可以创建该目标；此时它会被无确认删除，若 rename 随后失败则目标丢失。应使用提交时的无覆盖原子操作/重新选名，显式覆盖走安全替换。
6. **P2：Host 无覆盖上传存在竞态。** `files.rs:347-370` 即使 `overwrite=false`，Windows 最终仍无条件设置 `MOVEFILE_REPLACE_EXISTING`。检查目标不存在后、MoveFileExW 前若目标被创建，未授权覆盖仍发生。非 Windows 的 exists+rename 同样存在窗口。应按覆盖授权选择真正具有无覆盖语义的提交操作。
7. **P2：画面校验与缓存边界不完整。** `workspace_page.dart:396` 接受任意不同代际并清缓存，没有要求新代际必须 full；`:422-445` 未核对 JPEG 实际解码尺寸与声明尺寸，也未限制跨帧 `_tiles` 条目数/总解码内存。单条消息和画面总像素有限制，但不能替代解码/缓存限制。当前可信 Host 的常规路径未必触发，异常 Host/损坏负载仍缺专项保护。
8. **P2：响应式测试覆盖与名称不符。** `responsive_test.dart:95` 名称声称文件页覆盖 360dp 和 1280px，实际只 pump 360×800；测试也未显式切换 Windows/Android 平台，且没有完整 HomeShell 或已连接/传输中状态。不能据此宣布两平台全部页面已验收。
9. **P2：服务端交付缺少可复现构建条件。** `server/Cargo.lock` 不存在，`cargo ... --locked` 无法执行；WSL `cargo fmt -- --check` 在 `server/src/main.rs:847` 失败。根 workspace 排除了 server，根测试通过不能覆盖它。
10. **P2：UI token 约束未完全遵守。** `workspace_page.dart` 中有 63 行匹配 `Color(0x` 或 `Colors.`，仍存在页面内固定颜色和圆角等，不能把“已建 token 文件”视为完成全局平台主题迁移。

以上风险的触发条件均来自源码路径；除构建/测试检查外，没有声称已动态复现崩溃、数据丢失或攻击。

## 未完成与待验证

| 类别 | 缺口 |
|---|---|
| M1 产品闭环 | Rust FFI/native texture、Flutter 服务器配置/登录/设备目录/配对 UI、Host 票据校验、本地授权弹窗/托盘/系统服务、按会话权限 |
| 三种模式 | Moonlight/Sunshine 未集成；当前只有 tiles，完整兼顾/流畅策略、1 Mbps 总预算、拥塞控制、模式切换/回滚均未完成 |
| 跨平台 | Linux 主控/Host、Android Host 未实现；Android SAF/完整 IME、实体设备手势与触控链路未验收 |
| 文件专项 | 独立 file_only、目录传输、拖放、暂停/断点续传、任务中心、完整冲突策略、读写删除分权/ACL/审计未完成 |
| 媒体与交互 | DXGI/WGC、高性能硬编硬解、音频/麦克风、剪贴板、手柄、相对鼠标、完整多显示器/混合 DPI 验收未完成 |
| 公网与安全 | NAT 穿透/中继、面向中继的 E2EE、长期设备身份、防重放票据、2 秒内撤权、MFA、无人值守策略未完成 |
| 运维与交付 | S01–S10 完整后台、配置下发/回滚、备份恢复、正式签名安装包；Android release 使用 debug 签名 |
| 性能可靠性 | 跨物理机/局域网/公网、弱网 1 Mbps、p95 延迟、2 小时稳定性、4 GiB/万文件、断网续传、故障注入及安全专项均无完整验收 |

## 本轮验证

环境：本机 Windows/MSVC + 安装的 Flutter/Dart；服务端检查在 WSL Ubuntu 执行。全程未操作部署服务器。

| 检查 | 结果 |
|---|---|
| `cargo fmt --all -- --check` | 根 workspace 通过 |
| `cargo clippy --workspace --all-targets --locked` | 通过 |
| `cargo test --workspace --locked` | 16 passed：Host 7、proto 3、tiles 5、viewer 1 |
| `cargo build --release --locked -p yl-host -p yl-viewer` | 通过 |
| `dart analyze lib test` | No issues found |
| `flutter test --no-pub` | 13 passed：协议 9、响应式 4；包含要求的 responsive_test.dart |
| `flutter analyze --no-pub` | 分析服务出现 LSP JSON 截断 FormatException 并退出 255；随后直接 Dart 分析成功。原因未确定，不能记为该命令通过 |
| `yl-host --capture-test artifacts/review/codex-audit-20261018-capture.jpg` | 3200×2000，400 块，0.84 MiB；采集 60.0ms，编码 92.6ms；已查看图片，是真实桌面、非黑屏。单次采集不代表会话 fps/延迟 |
| WSL 服务端格式检查 | 失败，main.rs:847 格式差异 |
| WSL 服务端锁定依赖检查 | 失败，缺 Cargo.lock |
| 服务端隔离副本测试 | WSL `/tmp/yuanlian-codex-audit-20261018-1951`，`cargo test --release --offline`：编译成功、3 passed。副本重新解析离线依赖，不是部署二进制复现验证 |

未重新构建 Flutter Windows/APK；未重新运行远控窗口/键盘 E2E/文件 UI；未查询服务器在线状态。既有截图及历史部署记录不能自动升级为本轮通过。

## 文档状态纠偏

- `AGENTS.md` 的“Flutter 工程尚未创建”和“服务端未实现”已过时。
- README 的“账号/设备/配对服务、管理后台未实现”未区分已存在服务端与未接入客户端。
- 追踪表把“双栏文件管理、拖放上传”合并写成未实现，掩盖已存在的 Windows 双栏；把“校验/冲突”和“续传/幂等”合并也不能反映实际完成度。
- 协议 v1 首段仍称文件未进入协议，后文已有文件消息；旧原生查看器对新增 FileCapabilities 的兼容需复核，协议未明确能力协商。
- 追踪表平台表中 Android/账号/后台行缺少列分隔，信息挤入状态列；文末“账号/服务端 GUI 均未开始”与现有后端冲突。
- 本轮在追踪表追加核查记录，明确新证据与上述问题，不覆盖历史实测记录。

## 建议接续顺序

先修复日志、文件提交/取消、队列与解码边界并补异常路径测试；然后打通 Flutter 登录/设备/配对→短时票据→Host 本地许可与二次校验→撤销生效。再推进 FFI/纹理、文件续传和跨物理机测试。完成这些以后再评估质量模式、公网和完整跨平台验收。
