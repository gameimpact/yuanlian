# 需求追踪表

## 2026-10-19 增量：Linux 控制服务端在线一键安装

| 需求 | 状态 | 实现文件与测试环境/结果 | 剩余问题 |
|---|---|---|---|
| `bash <(curl -fsSL …)` 在线安装、明确服务端角色 | 已发布并通过在线下载校验；待安装实测 | 根 `install.sh`；提交 `20298d4` 已推送 GitHub main；公开 raw 脚本与本地 SHA-256 一致；WSL 实际执行公开命令 `--check` 通过：GitHub v0.2.0 下载、SHA-256/目录结构/包内脚本语法校验；没有安装或修改系统服务 | systemd 完整安装/实机未执行；只支持 x86_64，新装入口拒绝覆盖已有部署；发布包仍为既有 v0.2.0 |
| 离线安装命令与包内路径 | 已修复并做解包运行检查 | 三处说明使用 `scripts/install.sh`；包内安装器增加角色提示及完整性校验；本地 tar.gz 重打包，WSL 临时目录解包、脚本语法、真实二进制随机 loopback `/health` 通过；本地 manifest/SHA256SUMS 更新 | 没有替换 GitHub 已发布资产；在线脚本使用原有 v0.2.0 包与对应发布校验和；未操作 192.168.9.66 |

## 2026-10-19 增量：未完成项源码复核与兼顾档新性能要求

- 用户追加 Android 测试要求：在根目录续开发提示词的“Android 开发测试强制要求”中指定本地 MuMu 为主要联调/安装/UI/E2E 环境，由执行开发 AI 自行从网易官网下载、安装和配置；按实际 Android/API/ABI 建立多版本矩阵。MuMu 不覆盖的版本需注明并用官方 AVD/真机补测，模拟器与真机证据分开。本轮仅文档补充与差异检查，未下载安装 MuMu、未执行多版本测试，不标为已适配。

- 用户新增要求：兼顾质量和流畅档实际动态呈现至少 30 fps，提供 60 fps 档与实测；具体门槛、条件和统计见根目录 [续开发提示词](../未实现功能_续开发提示词_2026-10-19.md)。旧规格 24/30 次更新目标不再作为兼顾档验收依据；当前代码没有因新增文档而达到该指标。
- 核查发现：Host 默认 15 fps、XCap/GDI 串行采集/JPEG、Dart 图块解码、固定 tiles、接收帧数统计；无 Rust 核心桥/native texture、完整模式协商、中继、Linux/Android Host。Linux 客户端历史包存在，但当前 Git 源码无 `client/linux/` runner；账号已接入，设置页相关说明过时。提示词列出 F01–F33 和 C01–C16/A01–A05/S01–S10 的增量任务及暂不能交付原因。
- 本轮实跑：Windows 根 `cargo fmt --all -- --check`、`cargo test --workspace --locked --offline`（28 passed）；Dart analyze（0 issue）；Flutter `test --no-pub`（40 passed，含响应式）；WSL Ubuntu 独立服务端 fmt、release locked offline test（10 passed）。服务端测试复用 `/home/ubuntu/yl-server-build/target`。
- 本轮未做：新客户端/Host 发布构建、性能重测、完整点击登录/远控 E2E、跨物理机/公网、真机触控、Linux 桌面、两小时/4 GiB/万文件、Docker/systemd 新装、正式签名或生产部署。平台限制已参考官方 Android/Microsoft/XDG/上游资料，链接在提示词中；不把缺环境说成永久无法实现。

状态图例：**已实现并实测** / **已实现待实测** / **部分实现** / **未实现** / **平台不支持**。

最后更新：2026-10-18（0.2.0 / 协议 v2）。此表是唯一事实来源；“代码存在”“构建通过”“单元测试通过”“本机 E2E”分别记录，不能互相替代。当前完成 **M0 Windows 引擎、阶段 B 账号/设备/配对/票据/Host 授权闭环、Flutter Windows/Android 客户端、基础文件传输、控制服务端与 0.2.0 安装产物**；仍不是完整产品。证据索引见 [阶段 B](evidence/b-auth-ticket-2026-10-18.md)、[打包](evidence/packaging-0.2.0.md)、[M0](evidence/m0-results.md)、[M1 Flutter](evidence/m1-flutter-client.md)、[Android](evidence/m1-android-client.md)、[文件](evidence/m2-file-transfer.md)、[平台 UI](evidence/m3-platform-ui.md)、[服务端](evidence/m4-control-server.md)。

## 1. 平台与角色

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| Windows 主控（Flutter 产品壳） | 部分实现（本机已实测） | `client/`：连接/画面/指针/文件/平台 UI/地址簿；账号登录、设备目录、配对、票据连接 | Dart 协议与 JPEG 合成，未用 Rust FFI 纹理；账号 UI 未做真实点击登录 E2E；未跨物理机 |
| Windows 主控（原生测试查看器） | 部分实现（M0 已实测） | `crates/yl-viewer`：引擎诊断；支持 `--ticket/--nonce` | 不是产品 UI |
| Windows 被控 Host | 部分实现（本机已实测） | `crates/yl-host`：持久身份、票据离线验签/防重放、本机 MessageBox 授权、权限交集、心跳撤权、采集/输入/文件 | 无托盘/服务/无人值守；单会话；Session 0 不可用 |
| Linux 主控/Host | 部分实现（仅客户端构建） | WSL Flutter Linux 构建 deb/便携包；dpkg-deb/ldd/Xvfb 检查 | 未在真实 X11/Wayland 桌面安装/运行验收；Host 未实现 |
| Android 主控（Flutter） | 部分实现（模拟器画面历史证据；release 构建本轮通过） | AOSP M3、真实桌面、缩放/查看、文件页、账号/设备页 | 触摸/IME/SAF/捏合未验收；本轮未重跑模拟器连接 |
| Android 被控 Host | 未实现 | — | MediaProjection、输入授权、前台服务、SAF |
| 账号/设备/授权服务 | 已实现并实测（本机 API + E2E） | 邀请注册、Argon2id、Bearer、设备目录/令牌、配对、grant、审计、票据/撤权 | 无 MFA/恢复码；无策略下发；未在部署服务器更新本轮版本 |
| 发现/穿透/中继 | 未实现 | — | NAT、QUIC、中继 E2EE |
| Web 管理后台（服务端） | 部分实现（本机浏览器实测） | 概览、所有设备、在线设备、当前会话、设备详情、网络状态、用户/邀请、审计；受控轮询 | 无 SSE/事件、MFA、策略编辑器、备份恢复；非管理员/移动断点未全验 |
| Host 本地管理 UI | 部分实现 | 本机 MessageBox 授权 | 无托盘/设置窗口/服务安装 |

## 2. 三种模式

| 需求 | 状态 | 说明 |
|---|---|---|
| 质量模式（Moonlight + Sunshine） | 未实现 | 未集成；不得宣称可用 |
| 兼顾模式（非视频图块、清晰文字、静止精修） | 部分实现 | 图块差分 + JPEG 85 + 600ms 后 JPEG 95 精修；无无损文字/滚动复用/块版本 TTL |
| 流畅模式（1 Mbps 会话预算、低更新率） | 部分实现 | 静态不发图块；无总预算/拥塞控制/音频文件分账 |
| 三模式切换、代际、回滚 | 未实现 | 仅单一 `tiles` |
| 模式内部自动调节 | 未实现 | 固定 CLI 参数 |

## 3. 画面、输入与性能

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| 真实屏幕采集（非模拟） | 已实现并实测 | XCap/GDI；3200×2000 真实桌面 | 高 CPU；高安全窗口可能黑屏；未做 DXGI/WGC |
| 硬件编码/解码 | 未实现 | — | 当前 JPEG |
| 多显示器 | 部分实现 | 可选单显示器，坐标带原点 | 同屏多显/热插拔/负坐标未测 |
| 混合 DPI/缩放 | 部分实现 | Host/Viewer Per-Monitor-V2；本机坐标 0 px 误差 | 混合 DPI 未测 |
| 光标独立传输 | 已实现并实测 | 60 Hz Cursor 通道 | 未传形状/热点/可见性细节 |
| 鼠标绝对定位/按键/滚轮 | 部分实现 | 绝对坐标、五键、滚轮代码；绝对定位实测 | 按键/滚轮/拖拽未做真实 E2E |
| 键盘注入 | 部分实现 | VK 映射单测；Host SendInput 路径验证 | 同机回环；完整远端 IME 未实现 |
| Unicode/中文文本提交 | 已实现并实测 | `TextInput` + SendInput Unicode；中文+emoji | 不是远端 IME |
| 手柄/音频/麦克风/剪贴板 | 未实现 | — | 后续 |
| 输入权限 Host 侧强制 | 已实现并实测 | 未授权时拒绝并回 `input_denied`；票据 `CONTROL` 与 `--allow-input` 取交集 | 无按会话勾选（本机只允许/拒绝） |
| 断线/失焦/撤权释放输入 | 已实现并实测 | Host `release_all`；撤权 E2E 后释放 | 完整按键故障注入未做 |
| Flutter 画面端到端 | 已实现并实测 | 本机票据连接、首帧、图块显示 | Dart 合成；未跨物理机 |
| Flutter 指针映射 | 已实现并实测 | 历史 0 误差；本轮未重测 | 真实按键/拖拽 E2E 未测 |
| 画面边界/解码背压 | 已实现并测试 | 有界队列/像素/缓存上限；新代际必须全量；解码尺寸核对；损坏首帧不成功出画 | 慢解码长时间压力未实测 |
| 界面页面 | 部分实现 | 连接/进度/工作区/文件/设置/账号与设备 | C01–C16 完整校验/空/失败/离线状态未全做 |
| 采集/编码性能 | 已实测（本机） | 3200×2000 约 7–9 fps、采集 51–55 ms、编码 24–33 ms | 非 1080p/跨机/2 小时验收 |

## 4. 安全与身份

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| TLS 传输加密 | 已实现并实测 | rustls/ring，ALPN `yuanlian/1` | 数据面 E2EE（中继）未实现 |
| Host 证书指纹固定 | 已实现并实测 | 错误指纹明确拒绝 | 首次核对仍是人工 |
| 持久设备身份 | 已实现并测试 | 证书/私钥存身份目录，重启指纹一致；半缺失报错 | Windows 文件 ACL 未专门加固；无私钥硬件保护 |
| 账号登录/设备目录/配对 | 已实现并实测（API/本机 E2E） | 服务端 API + Flutter 页面；票据连接 | 真实 UI 点击 E2E 未做；MFA/恢复码未实现 |
| 短时会话票据 | 已实现并实测 | Ed25519 `yl1` claims；设备/用户/nonce/用途/权限/exp/jti 绑定 | 1 小时固定 TTL；无刷新令牌 |
| 防重放/过期/跨设备 | 已实现并测试 | Host `jti` 缓存；`ticket_replay`、`ticket_expired`、`aud` 校验 | 多 Host 共享缓存未做（每 Host 独立） |
| 权限模型（读/写/删除分离） | 部分实现 | 票据/本地交集；文件读写逐条校验；删除未开放 | 删除、剪贴板、音频权限未做 |
| 本机授权窗口 | 已实现并实测 | MessageBox；`--auto-approve` 仅显式测试 | 一次性/长期信任分层、托盘未做 |
| 撤权 2 秒内生效 | 已实现并实测 | 心跳 1 s + 会话 tick 500 ms；实测 0.86–1.17 s | 跨公网/高延迟未验证 |
| 控制面断联租约 | 已实现并测试 | 30 s 无心跳置 owner inactive，会话结束 | 未做端到端断网停顿测试 |
| 日志脱敏 | 已实现（本轮修复） | 输入事件/键码/按钮不再序列化；只记录计数/结果 | 完整诊断导出未实现 |
| 无人值守/白名单/时段 | 未实现 | — | 后续 |
| 匿名直连 | 已实现（显式开发模式） | `--allow-anonymous` + 启动告警 + Welcome 标记；默认拒绝 | 不是产品入口，需继续限制 |

## 5. 文件、服务端与运维

| 需求 | 状态 | 实现/证据 | 剩余问题 |
|---|---|---|---|
| Windows 双栏文件管理 | 部分实现 | Flutter 双栏 + 可拖 splitter；Android 单栏分段 | 本轮未重做文件 UI 实测；拖放未实现 |
| 上传/下载/SHA-256 | 已实现并实测 | 单文件双向校验；Host 提交前哈希 | 仅单文件 |
| 下载取消 | 已实现并测试 | Host 取消标志 + 终态错误；客户端页面退出/失败均取消 | 跨网络高延迟下的取消时延未测 |
| 无覆盖原子提交 | 已实现并测试 | Host 平台原子无覆盖；客户端 `commitNoReplace` | 跨文件系统（temp 与目标不同盘）不支持，会报错 |
| 上传异常清理 | 已实现并测试 | Drop/所有错误出口关闭句柄、删临时文件；失败保留旧文件 | 故障注入仅单测 |
| 冲突策略 | 部分实现 | Host 需显式 overwrite；客户端同名自动编号 | 无“全部覆盖/跳过”批量策略 |
| 断点续传/目录/块校验/幂等 | 未实现 | — | 4 GiB/万文件/断网续传未验收 |
| 读/写/删除分权 | 部分实现 | 票据读写位 + Host 逐条校验；删除未开放 | ACL/审计未做 |
| 服务端票据/撤权 | 已实现并实测 | 本轮 API E2E：签发→上报→撤销→心跳返回 | 未部署到 192.168.9.66 本轮版本 |
| 策略/配置下发/回滚 | 未实现 | — | S01–S10 |
| 中继与容量管理 | 未实现 | — | — |
| 服务端 GUI | 部分实现（本机浏览器实测） | 设备/在线/会话/网络/用户/审计页面；数据来自真实 API | 无 SSE、策略/配置下发、备份恢复；TLS 依赖反向代理 |
| 安装包/服务/Docker/备份 | 部分实现 | Windows 便携/安装器、Android 预览 APK、服务端 tar.gz | Linux 客户端 .deb 未生成；无 Docker 验证；无备份恢复脚本验证 |
| Windows Fluent 壳层 | 已实现并实测（历史） | NavigationView/CommandBar/Segoe/Mica 请求/快捷键 | 高对比/混合 DPI 截图未全测 |
| Android AOSP 壳层 | 已实现并实测（历史） | edge-to-edge/TopAppBar/NavigationBar/48dp | predictive back/IME 未全验 |
| Android 工作区 overflow | 已修复并测试 | 360dp/1.3 字体组件测试通过 | 2.0 字体未测 |
| Android 缩放/平移 | 部分实现 | 查看/控制、缩放菜单、拖动、捏合代码 | 捏合未实机手势验证 |

## 6. 本轮验证记录

| 测试 | 命令/方式 | 结果 |
|---|---|---|
| 根 Rust 格式/静态检查 | `cargo fmt --all -- --check`；`cargo clippy --workspace --all-targets --locked` | 通过，0 warning |
| 根 Rust 测试 | `cargo test --workspace --locked` | 28 passed：Host 15、proto 7、tiles 5、viewer 1 |
| 根 release 构建 | `cargo build --release --locked -p yl-host -p yl-viewer` | 通过；Host/Viewer 0.2.0 |
| Flutter 静态分析 | `dart analyze lib test` | No issues found |
| Flutter 测试 | `flutter test --no-pub` | 40 passed（协议 9、帧边界/队列 7、原子提交 4、服务端客户端 3、响应式/状态 17） |
| 服务端格式/静态检查 | WSL `cargo fmt -- --check`、`cargo clippy --release --locked -- -D warnings` | 通过 |
| 服务端测试 | WSL `cargo test --release --locked` | 10 passed（含票据状态/租约/迁移） |
| 服务端 release | WSL `cargo build --release --locked` | 通过；0.2.0 |
| 真实采集 | `yl-host --capture-test` | 3200×2000 真实桌面；单次采集不代表会话 fps |
| 持久身份 | `yl-host --print-identity` 两次 | 设备 ID/指纹一致 |
| 票据 API E2E | 本机服务端 + Node/curl | setup/login/register/key/ticket/heartbeat/session/revoke 全部 200；撤销列表回传 |
| 票据画面 E2E | 服务端 + 本机 Host + 原生查看器/Flutter | 账号 admin、权限 31 与 Host 本地交集后读/写/控制；真实出画 |
| 撤权时延 | API 撤销 → Host 日志 | 0.86–1.17 s；Host 释放输入、发 `revoked` |
| 防重放 | 已用票据再次连接 | 拒绝：`ticket_replay` |
| 匿名拒绝 | 票据模式 Host + 无票据查看器 | 拒绝：`unauthorized` |
| Windows 便携/安装器 | NSIS + zip；包内启动 | 见第 11 节 |
| Android release APK | `flutter build apk --release --target-platform android-arm64` | 17.7 MB；arm64-v8a、minSdk 24、target 36；预览签名校验通过 |
| Android 安装/启动 | 模拟器 | 见第 11 节 |

**未做**：跨物理机/公网、键盘/拖拽真实 E2E、Android 捏合/IME/SAF、2 小时稳定性、4 GiB/万文件、弱网 1 Mbps、完整故障注入、Linux 实机。

## 7. 明确未达到的验收项

18 个 Windows/Linux/Android × 模式组合、Android Host、三模式切换、文件专项（4 GiB/万文件/断网续传）、质量模式 p95 ≤100 ms、流畅模式 1 Mbps 弱网、2 小时稳定性、完整安全撤权/重放/路径逃逸专项、MFA、策略下发、中继 E2EE、完整 S01–S10、Linux 客户端/Host 均**未完成验收**。当前版本不能对外称“跨平台远控完成”。

## 8. 阶段 A 审计关闭情况（对照 `docs/review/deepseek-delivery-audit-2026-10-18.md`）

| # | 审计问题 | 状态 | 证据 |
|---|---|---|---|
| 1 | 输入事件 debug 日志泄露 | 已关闭 | 移除 `?event` 与键码/按钮码；扫描 Host 日志路径；只记录计数 |
| 2 | `_decodeChain` 无界 | 已关闭 | `frame_queue.dart` 有界队列；溢出请求全量；单测覆盖 |
| 3 | 下载取消不停止任务 | 已关闭 | `DownloadReader.cancel`；FileCancel/会话结束/撤权触发；终态错误测试 |
| 4 | 客户端先删后 rename | 已关闭 | `commitNoReplace` FFI（Windows MoveFileExW 无替换；POSIX renameat2/link）；冲突自动选名；4 项测试 |
| 5 | Host 无覆盖竞态 | 已关闭 | `commit_temp` 依据 overwrite 选择无覆盖/替换；目标后出现测试保留旧文件 |
| 6 | 上传异常清理 | 已关闭 | `UploadState Drop` 关闭句柄后删临时文件；失败保留旧文件测试 |
| 7 | 画面边界/损坏/代际 | 已关闭 | 解码前后尺寸核对、像素/图块/缓存上限、全量覆盖校验、旧 seq/代际拒绝；组件测试 |
| 8 | 响应式测试名不副实 | 已关闭 | 显式 Windows/Android、1280×800/360dp/1.3、HomeShell、已连接工作区、传输中/失败状态 |
| 9 | 服务端 fmt/Cargo.lock/独立构建 | 已关闭 | `server/Cargo.lock`；WSL fmt/clippy/test/build 全通过；查看器支持 v2 票据参数 |
| 10 | UI token/文档/追踪表 | 已关闭 | 工作区/文件页/进度页改用 design tokens；协议/README/AGENTS/追踪表重写；列结构修正 |

回归测试用于验证新行为（无覆盖冲突、取消终态、帧边界、票据重放/过期），不是断言源码文本。仍需设备/故障注入的项已在各表标注。

## 9. 续开发与打包指令归档

2026-10-18：根目录 `DeepSeek_续开发与全平台安装包提示词.md` 为本轮执行指令，要求按审计修复→授权闭环→Rust 纹理/文件/UI→三模式/跨平台/公网后台，并交付 Windows/Linux/Android/服务端产物。本轮已完成阶段 A、B 与部分打包；C/D 未完成，不以文件名宣称阶段完成。

## 10. 阶段 B 授权闭环（0.2.0）

| 项目 | 状态 | 证据/说明 |
|---|---|---|
| 持久 Host 身份 | 已实现并测试 | `host-cert.der`/`host-key.der`；两次启动指纹一致；半缺失报错 |
| 短时票据签发 | 已实现并实测 | 服务端 `session-ticket`；Ed25519；60 分钟 |
| Host 离线验签 | 已实现并实测 | 设备/用户/nonce/用途/权限/时间/jti；未知 kid 刷新一次 |
| 防重放/过期 | 已实现并实测/单测 | `ticket_replay`；过期/未生效/跨设备/nonce 不匹配 |
| 本机授权 | 已实现并实测（自动确认模式） | MessageBox 代码；E2E 用 `--auto-approve`；人工对话框未自动点击验证 |
| 权限交集 | 已实现并实测 | 票据 31 ∩ 本地 allow-input/file-root；Host 日志显示读/写/控制 |
| 文件逐条权限 | 已实现并测试 | FileList/Download 需读，Upload 需写；删除未开放 |
| 中心撤权 ≤2s | 已实现并实测 | API 撤销→Host 0.86–1.17 s 结束；发送 `revoked` |
| 账号/设备/配对 UI | 已实现待真实点击 E2E | 登录/邀请注册/设备/配对/登记/撤销/会话；HTTP mock + 响应式测试 |
| 安全凭据存储 | 已实现待实测 | Windows DPAPI；Android Keystore MethodChannel；未落普通 JSON |
| Flutter 票据连接 | 已实现并实测 | 自动票据参数连接 Host；Welcome 显示账号/权限；真实出画 |
| 服务端断联租约 | 已实现 | 30 s 无心跳结束票据会话；未做网络分区测试 |
| Host 产品化（托盘/服务） | 未实现 | 仅 CLI + MessageBox |

**阶段 B 缺口**：MFA/恢复码、长期信任确认、托盘/服务、按会话权限勾选、真实 UI 登录 E2E、跨公网/高延迟撤权、已部署服务器升级。

## 11. 安装包与安装/升级/卸载验证（0.2.0）

| 产物 | 路径 | 签名/测试状态 |
|---|---|---|
| Windows 便携 zip | `dist/0.2.0/windows-x64/` | 未签名；解压到中文/空格路径启动成功；连接 E2E 使用同源 Release，非包内单独连接 |
| Windows 安装器 exe | `dist/0.2.0/windows-x64/` | 未签名；静默安装/覆盖升级/安装目录启动/静默卸载通过；GUI 逐页未点 |
| Android arm64 APK | `dist/0.2.0/android/` | 独立预览签名；构建/验签通过；x86_64 模拟器 ABI 不匹配，未在 arm64 真机安装 |
| Android universal APK | `dist/0.2.0/android/` | 同预览签名；x86_64 模拟器安装/启动成功；账号页打开 |
| Linux 客户端 deb/便携包 | `dist/0.2.0/linux-x86_64/` | WSL 构建、dpkg-deb/ldd/Xvfb 检查；未真实桌面安装/运行 |
| Linux 服务端 tar.gz | `dist/0.2.0/server-linux-x86_64/` | 解压运行 `/health`/`ticket-key` 成功；未安装到生产机；Docker 未验证 |
| 哈希/清单 | `dist/0.2.0/SHA256SUMS.txt`、`build-manifest.json` | 最终文件计算；含 revision/dirty/签名/测试状态 |

## 12. WebUI/P2P 扩展前审查与开发提示词（2026-10-18）

审查提出的 R1–R6 已在本轮修复并做隔离 API/真实 Host 回归；WebUI 管理与真实状态页已实现并做浏览器检查。**P2P/ICE/STUN/TURN/中继 E2EE 仍未实现**，未修改生产部署。

| 项目 | 状态 | 文件/环境/结果 | 剩余问题 |
|---|---|---|---|
| R1–R6 授权/状态修复 | 已实现并回归 | `session_tickets`、票据状态检查、Host 强制开始确认、心跳租约、撤销后结束确认、登录 Argon2 移出 DB 锁；`docs/evidence/webui-r1-r6-2026-10-18.md` | 未做长期租约/高并发压测；详情见证据 |
| Linux 控制服务 WebUI/P2P 开发指令 | 已编写并核对文档 | 根目录 `Linux服务端_WebUI与P2P_开发提示词.md`；逐页 UI、状态/权限、API、ICE/STUN/TURN、端点身份、分片/背压、部署边界、测试与交付 | 仅为待执行规格，不作为实现或性能证据 |
| 本轮回归 | 测试通过 | Windows 根 Rust fmt/clippy/28 tests；WSL 服务端 fmt/clippy/10 tests/release build；Dart analyze、Flutter 40 tests；隔离 API `ALL_R_API_TESTS_PASSED`；浏览器登录/设备/详情/会话/网络检查 | 未新构建 Windows/APK；未跨设备/跨公网远控验收 |
| 本轮隔离 API 核查 | 修复后回归通过 | 临时 SQLite/loopback；停用后待用票据失效、跨设备上报拒绝且不改行、心跳刷新会话、撤销设备后结束 200、管理员概览/设备/会话/网络 | 不是屏幕/输入绕过 E2E；见证据文件 |

后续仍需实现 P2P/ICE/TURN/中继；必须先锁定 WebRTC 依赖并完成双端数据通道、DTLS 身份绑定、强制 TURN 与跨 NAT 实测，不能以路由、STUN 查询或 echo demo 宣称 P2P 完成。当前 TCP 直连没有中继流量，不能宣称已节省中继带宽。

## 13. WebUI 与 P2P 扩展（2026-10-18 续）

| 项目 | 状态 | 证据 | 剩余问题 |
|---|---|---|---|
| WebUI 概览/设备/在线/会话/详情/网络 | 已实现并浏览器实测 | `server/admin/index.html`；`admin/overview`、`admin/devices`、`admin/sessions`、`devices/{id}`；`docs/evidence/webui-r1-r6-2026-10-18.md` | 受控轮询，无 SSE；非管理员/全断点/200% 未全验 |
| 在线状态来源 | 已实现并 API 实测 | 仅设备令牌 agent 心跳更新 `last_agent_seen`；管理员浏览器心跳不制造在线 | 阈值固定 5 秒；未做时钟/网络抖动统计 |
| 会话生命周期/租约 | 已实现并 API/真实 Host 实测 | active/unknown/stale/revoking/ended；30 秒租约；Host 实例；开始确认先行；`docs/evidence/webui-r1-r6-2026-10-18.md` | 未做 2 小时/断网故障注入；服务端每 5 秒清理未压测 |
| 待用票据撤权/R2/R4 | 已实现并隔离 API 实测 | `session_tickets`、`ticket_status`、按设备/用户绑定、撤销后幂等结束 | 未做高并发/时钟偏差专项 |
| P2P / ICE / STUN / TURN / 中继 | 未实现 | WebUI 网络页与 API 明确 `p2p=false`、`turn=false`；无候选/数据通道/中继代码 | 依赖锁定、Flutter/Rust WebRTC 构建、DTLS 身份绑定、真实跨 NAT/TURN 环境；不能把路由或 STUN 查询当 P2P |
