# Flutter 产品壳与 Rust 核心桥（M1 设计）

状态：设计草案，尚未实现。M0 的原生查看器只用于引擎验证，不是最终 UI。

## 目标

- Windows/Linux/Android 共享 Flutter 页面、状态模型与交互规范（C01–C16、A01–A05）。
- Rust 负责身份、会话、连接、权限、输入、文件、模式引擎、统计与日志；Flutter 不直接访问 Host 文件系统，不持有 Sunshine 管理密码。
- 画面不逐帧复制成 Dart 大对象；使用 native texture/GPU 路径，并测量实际拷贝与呈现开销。
- 每个异步页面具备加载/空/正常/失败/无权限/离线状态；四种状态（账号、服务器、设备、会话）独立显示。

## 进程与线程

```
Flutter UI (Dart isolates)
   │  flutter_rust_bridge / C ABI (commands + event stream)
Rust core facade (identity, session_manager, file_engine, diagnostics)
   ├── capture/encode thread  ──┐
   ├── transport/QUIC/TLS tasks ├── bounded queues, priority input > control > frames > file
   ├── decode/render thread ────┘
   └── platform_* (Win/Linux/Android) / moonlight_adapter / sunshine_adapter
```

Flutter 只持有会话 ID、状态快照和纹理 ID；不持有 JPEG/原始帧。输入事件走独立高优先级通道；文件任务有独立队列与预算。

## 纹理路径

1. Rust 解码线程把画面写入 GPU 纹理：
   - Windows：D3D11 纹理（优先 NV12/P010 硬解输出或 RGB），可选共享句柄；
   - Linux：GL/DMA-BUF（X11/Wayland 能力不同）；
   - Android：Surface/SurfaceTexture。
2. 平台插件把纹理注册给 Flutter 引擎，Flutter 侧使用 `Texture(textureId)` 或 `PlatformView` 承载。
3. 尺寸/旋转/显示器变化时递增画面代际，通知 UI 更新布局；旧纹理帧带代际戳，渲染层拒绝过期帧。
4. 每帧路径必须测量：解码 → GPU 拷贝 → 合成 → 呈现；禁止“先把整帧读回 CPU 再上传”。

M1 先做 Windows 的 spike：真实 Moonlight/图块帧进入 texture，测 1080p60 下的 CPU/GPU 占用与 p95 呈现延迟；不达标再调整（共享纹理、零拷贝、平台视图），**不得**退回逐帧 Dart 对象并宣称完成。

## Rust 对外接口（最小集）

命令：

- `server_profiles_list/save/test`、`auth_login/logout/refresh/mfa`
- `device_list/get/rename`、`device_pair_start/confirm/revoke`
- `session_request(target, mode, permissions, type=desktop|file_only)` → `session_id`
- `session_cancel/accept/deny/end`、`session_set_permissions`、`session_switch_mode`
- `input_send(session_id, event)`（含 ReleaseAll；失焦/断线必须调用）
- `file_list/stat/mkdir/rename/delete`、`transfer_create/pause/resume/cancel/retry`
- `config_expect/apply/rollback`、`diagnostics_export(redacted)`

事件（带作用域、对象 ID、序号、时间、代际）：

- `account.status`、`server.status`、`device.status`、`session.phase/permissions/mode/path`
- `frame.generation`（纹理 ID/尺寸，不携带像素数组）
- `transfer.progress`、`config.applied`、`security.revoked`、`server.health`

协议/API 语义与错误码见 `docs/protocol.md`；正式版 API 使用 `/api/v1` 并生成 OpenAPI。事件断线后必须能补快照并检测缺失，不能只靠一次推送。

## 权限与安全

- 安全权限 = 中心允许 ∩ Host 本机允许 ∩ 本次授权；拒绝优先。Flutter 隐藏按钮不构成授权，Rust/Host 必须再次校验。
- 设备身份私钥、账号令牌、服务器凭据存入系统凭证库/Keystore；Dart 侧只拿短期引用，不落普通 JSON。
- 配对与账号授权分层；配对成功必须完成完整握手，不能只提交 PIN 就显示成功。
- 撤销/断开要在 Host 侧真正停止输入与引擎，不能只改 UI。
- 日志/诊断默认排除密码、令牌、私钥、按键、剪贴板、文件内容与截图；导出前预览脱敏范围。

## 页面落地顺序（每个都必须接真实状态）

1. C02 服务器配置 + 测试连接（真实 DNS/TCP/TLS/身份/API 版本检查）。
2. C03 登录/MFA（服务端可用后）。
3. C04 首页 + “此设备” Host 状态 + 连接其他设备。
4. C07 连接进度（真实阶段、取消、错误码、仅文件分支）。
5. C08 入站授权（真实权限复选、拒绝/仅查看/允许本次、长期信任另确认）。
6. C09 远控工作区（纹理、输入、统计、断开、断线冻结遮罩）。
7. C10 模式设置（请求值/实际值/限制原因）。
8. C11/C12 双栏文件与传输中心。
9. C13/C14/C15/C16 设置、安全、诊断、本机 Host 管理。

M0 的原生查看器可以保留为开发诊断工具，但产品入口不得依赖用户另开一个外部窗口完成远控。

## 验收门槛（M1）

- Windows↔Windows 通过 Flutter UI 完成真实查看、控制、模式（图块）、授权、断开；画面来自 texture，不用假图。
- 每个按钮有真实行为；无权限/未安装/不支持显示具体原因。
- 1080p 参考链路测得 p50/p95 呈现延迟、CPU/GPU、内存；报告原始值。
- 撤销输入后 Host 端真实停止键鼠；断线/失焦不卡键。
- 文件基本任务（上传/下载/暂停/续传/校验）有真实结果。
- 未完成项在需求追踪表中如实标注，不以“代码存在”标通过。
