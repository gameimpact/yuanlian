# 远联协议 v3（0.3.0 开发增量）

2026-10-19：新增票据绑定的 `tiles` / `flow` / `quality` 模式，质量路径接入 Host 授权。旧外部社区预览入口仍独立、不受中心撤权；账号与设备页的“质量 · 视频串流 · Host 票据授权”才使用下面的 broker。画面仍在外部 Moonlight 显示，未内嵌 Flutter。

`PROTOCOL_VERSION = 3`；`ALPN = yuanlian/1`。Host、原生查看器、Flutter 和服务端源码版本升为 0.3.0；现有 0.2.0 发布资产不变，不能混装。v1/v2 Hello 布局不兼容并拒绝连接，旧布局无法解码时直接断开；不静默降级。

HTTP `POST /api/v1/devices/{id}/session-ticket` 接受 `mode`（兼容 `engine` 别名，省略默认 `tiles`），未知模式返回 409。票据仍是 `yl1.<payload>.<signature>`，但 JSON `v=2` 并新增签名覆盖的 `mode` 字段；旧 v=1 票据不再接受。Host 在消耗防重放记录前校验 `claims.mode == hello.mode`。

质量请求的 `quality_certificate` 仅包含本次 Moonlight 的公开 X.509 PEM。客户端用独立便携目录让官方 Moonlight 生成 RSA 身份；私钥留在主控端。Host 验票、权限交集、本机确认、控制面开始确认之后，才启动新的专用 Sunshine。该实例仅信任本次证书，只有 Desktop 应用；鼠标/键盘按实际权限启用，手柄/原生触控关闭，`lan_encryption_mode` / `wan_encryption_mode` 均为 2，WebUI 为随机不可交付凭据且只允许本机来源，不改现有 Sunshine 配置。

实例启动期间也监测断开、撤权和过期；运行中每 100 ms 检查租约，每秒沿用控制面心跳。关闭本次实例的原生 kill-on-close Job 才是断开媒体和输入的执行手段，随后再报告结束。单会话、IPv4、仅 Windows；非 Windows、未配置 `--sunshine`、匿名质量或无查看权限均拒绝。

服务端能力 API 声明三模式及 `quality_streaming.requires=host_v3_dedicated_sunshine`；这不代表每台已登记 Host 都已配置/支持质量，也不宣称 Flutter 内嵌或跨 NAT 可用。

## 1. 传输与信任边界

| 项目 | 当前实现 | 边界 |
|---|---|---|
| 底层 | TCP + TLS 1.2/1.3（rustls/ring） | 画面/输入/文件共用一条连接，存在队头阻塞 |
| Host 身份 | 持久自签名证书，SHA-256 指纹固定 | 不是公共 CA；首次配对仍需核对指纹 |
| 查看者身份 | 控制服务端签发的 Ed25519 短时票据 | Host 离线验签，不逐连接请求服务端 |
| 票据绑定 | 设备 ID、用户、连接随机数、用途、权限、`jti`、签发/过期 | 单次使用；Host 保存 `jti` 防重放缓存 |
| 本机授权 | Windows MessageBox 确认；`--auto-approve` 仅显式测试 | 票据不能绕过本机用户拒绝 |
| 权限 | 票据权限 ∩ Host 本地策略 | 读、写、删除分别校验；删除能力当前未开放 |
| 撤权 | Host 每秒心跳拉取撤销列表 | 实测 0.86–1.17 秒停止会话（目标 ≤2 秒） |
| 控制面 | HTTP/HTTPS 到独立服务端；生产必须 TLS 反向代理 | 服务端不转发桌面数据；中继尚未实现 |

TLS 只保护查看者↔Host 链路；未来中继必须只转发密文，不能把“管理 API 使用 HTTPS”当作媒体端到端加密。

## 2. 连接与授权流程

```
Viewer                     Control plane                 Host
  |-- login (HTTPS) ----------->|                         |
  |-- POST session-ticket ----->|  sign Ed25519 claims    |
  |<-- ticket + nonce binding --|                         |
  |-- TCP + TLS (pin) ----------------------------------->|
  |-- ClientHello(ticket, nonce) ------------------------>|
  |                           offline verify + replay check + local dialog
  |<------------------------------ Welcome(auth, permissions)
  |<------------------------------ FileCapabilities(read/write/delete)
  |-- Input / frames / files ...                          |
  |    Host heartbeat every 1 s -> control plane          |
  |    owner/admin revoke -> next heartbeat -> Host ends session
```

1. 查看者在登录后生成 32 字节随机 `session_nonce`（64 位小写十六进制），请求票据。服务端将 `sha256(nonce)` 写入票据。
2. 票据格式：`yl1.<base64url(json claims)>.<base64url(ed25519 signature)>`；签名覆盖 `yl1.<payload>`。字段：`v,kid,aud,sub,user,jti,purpose,mode,nonce_sha256,permissions,iat,exp`。
3. Host 用启动时从 `/api/v1/server/ticket-key` 获取的公钥离线验签，校验 `aud==本机设备 ID`、`purpose=="remote_session"`、nonce 绑定、权限位、`iat/exp`（±90 秒时钟容差）。`kid` 未知时刷新一次公钥。
4. Host 将 `jti` 放入有界防重放缓存；重复使用返回 `ticket_replay`。票据默认 1 小时有效。
5. Host 计算 `effective = ticket.permissions & local_permissions`；`local_permissions` 来自 `--allow-input`、`--file-root`、`--file-read-only`。缺少 `view` 直接拒绝。
6. Host 显示本机授权对话框（账号、来源、权限）；拒绝返回 `unauthorized`。`--auto-approve` 只在显式测试/专用主机使用并打印告警。
7. Host 发送 `Welcome` 与 `FileCapabilities`，并把会话 `jti`、用户、权限报告给控制面；心跳发现撤销后发送 `Error(revoked)` 与 `Bye`，释放按键并取消下载。
8. 未带票据的连接只有在 Host 显式 `--allow-anonymous` 时进入“匿名开发模式”，`Welcome.authenticated=false`；否则返回 `unauthorized`。配置了服务端但未允许匿名时，匿名连接不会静默通过。

## 3. 消息

### 3.1 Client → Host

| 消息 | 字段 | 说明 |
|---|---|---|
| `Hello` | `protocol_version:u16`, `client_name:String`, `client_id:String`, `request_input:bool`, `features:u32`, `session_ticket:Option<String>`, `session_nonce:String`, `mode:String`, `quality_certificate:String` | 必须是第一条；`features` 位见 §3.3 |
| `Input(InputEvent)` | §4 | 未授权时返回 `input_denied` |
| `RequestKeyframe` | 无 | 请求下一帧 `full=true` |
| `Ping` | `nonce:u64` | 5 秒心跳 |
| `Bye` | 无 | 正常结束 |
| `TextInput` | `text:String` | 已提交 UTF-16 文本，≤4096 单元；Host 按控制权限强制校验，不记录内容 |
| 文件消息 | §6 | 读写权限逐条校验 |

### 3.2 Host → Viewer

| 消息 | 字段 | 说明 |
|---|---|---|
| `Welcome` | `protocol_version`, `host_id`, `host_name`, `screen_width`, `screen_height`, `input_allowed`, `mode`, `tile_size`, `authenticated:bool`, `account:String`, `permissions:u32`, `auth_mode:String`, `session_id:String`, `ticket_expires_at:i64` | `mode` 当前固定 `"tiles"`；`auth_mode` 为 `ticket` 或 `anonymous-development` |
| `Frame` | `seq:u64`, `screen_generation:u32`, `full:bool`, `width:u32`, `height:u32`, `tiles:[Tile]` | §5 |
| `Cursor` | `x:i32`, `y:i32`, `visible:bool` | 相对采集显示器左上角 |
| `Pong` | `nonce:u64` | 心跳应答 |
| `Error` | `code:ErrorCode`, `message:String` | 可恢复错误不必断开 |
| `Bye` | `reason:String` | 会话结束；撤权/过期时带具体原因 |
| `FileCapabilities` | `enabled:bool`, `root_label:String`, `read:bool`, `write:bool`, `delete:bool` | 连接建立后立即发送；只暴露根目录名 |

`Tile`：`x:u32, y:u32, width:u32, height:u32, jpeg:Vec<u8>`。

### 3.3 能力与权限位

能力位（`Hello.features`）：

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | `FILE_TRANSFER` | 支持文件消息 |
| 1 | `TEXT_INPUT` | 支持 `TextInput` |
| 2 | `SESSION_TICKET` | 支持票据字段 |

权限位（票据与 `Welcome.permissions`）：

| 位 | 名称 | 说明 |
|---|---|---|
| 0 | `VIEW` | 查看画面 |
| 1 | `CONTROL` | 键鼠/文本注入；仍需 Host 本地 `--allow-input` |
| 2 | `FILE_READ` | 列目录、下载 |
| 3 | `FILE_WRITE` | 上传、覆盖（需显式 overwrite） |
| 4 | `FILE_DELETE` | 保留；当前没有删除消息，Host 不授予 |

`input_allowed` 只是 `CONTROL ∩ 本地策略 ∩ request_input` 的结果；文件消息仍逐条检查读/写位。

### 3.4 错误码

| 值 | 名称 | 场景 |
|---|---|---|
| 0 | `protocol_version` | 版本不兼容 |
| 1 | `bad_message` | 协议/字段错误 |
| 2 | `input_denied` | 输入未被授权 |
| 3 | `screen_unavailable` | 采集失败 |
| 4 | `internal` | Host 内部错误 |
| 5 | `busy` | Host 忙 |
| 6 | `unauthorized` | 票据缺失/验签失败/本机拒绝 |
| 7 | `ticket_expired` | 票据过期 |
| 8 | `ticket_replay` | 票据重放 |
| 9 | `permission_denied` | 有效权限不足 |
| 10 | `revoked` | 中心撤权/账号停用/租约失效 |

## 4. 输入语义

| 事件 | 字段 | 坐标/单位 |
|---|---|---|
| `MouseMove` | `x:i32`, `y:i32` | 采集显示器内像素 |
| `MouseButton` | `button`（Left/Right/Middle/Back/Forward）, `down` | Host 记录按下状态并去重 |
| `Wheel` | `vertical:i32`, `horizontal:i32` | 120 的倍数 |
| `Key` | `vk:u16`, `down:bool`, `extended:bool` | Windows 虚拟键码 |
| `ReleaseAll` | 无 | 失焦/断开/退出/撤权释放所有按键与按钮 |

Host 将显示器内坐标加原点后换算为虚拟桌面绝对坐标。当前不支持相对鼠标/拖拽捕获、完整远端 IME、手柄；中文/emoji 通过 `TextInput` 提交，不是远端候选窗。

## 5. 图块画面通道与边界

- 128×128 网格（参数 64–256），最后一行/列裁切；每块独立 baseline JPEG，质量 85，静止 600 ms 后质量 95 精修。
- 只发送变化图块；静态画面零 `Frame`，光标独立。
- `screen_generation` 在采集源/尺寸变化时递增。**新代际的第一个可接受帧必须是 `full=true`**；查看器拒绝新代际的增量帧并请求全量。
- 查看器对不可信帧实施硬限制（`client/lib/src/net/frame_queue.dart`）：
  - 画面 ≤16384 边、≤36 M 像素；单帧 ≤8192 图块；单图块 ≤1 M 像素、JPEG ≤4 MiB。
  - 图块必须完全在画面内、坐标不重复、全量帧图块面积等于画面面积。
  - 待解码队列 ≤2 帧 / 48 MiB / 36 M 像素；溢出时丢弃积压并请求全量帧，不任意丢弃增量帧导致永久破损。
  - 解码前用 `ImageDescriptor` 核对 JPEG 实际宽高与声明一致；不一致、解码失败、越界、旧 `seq`、旧代际均拒绝。
  - 解码缓存 ≤36 M 像素 /8192 图块；超限清空并请求全量。
  - 首帧未通过校验时保持“等待首帧”界面，不能显示为“连接成功并正常出画”。
- 消息总长上限 32 MiB；单条 `Frame` 的图块 JPEG 总和受上述限制约束。

## 6. 文件通道

### 6.1 客户端 → Host

| 消息 | 字段 | 权限/说明 |
|---|---|---|
| `FileList` | `request_id:u64`, `path:String` | `FILE_READ` |
| `FileDownload` | `task_id:u64`, `path:String` | `FILE_READ` |
| `FileUploadStart` | `task_id:u64`, `path:String`, `size:u64`, `overwrite:bool` | `FILE_WRITE`；未允许覆盖时目标存在即拒绝 |
| `FileUploadChunk` | `task_id`, `offset:u64`, `data` | 顺序块 ≤256 KiB；偏移必须等于已接收字节 |
| `FileUploadFinish` | `task_id` | 校验大小/哈希后提交 |
| `FileCancel` | `task_id` | 设置真实取消标志，停止读/发并清理 |
| `TextInput` | `text` | 需 `CONTROL` |

### 6.2 Host → 客户端

| 消息 | 字段 | 说明 |
|---|---|---|
| `FileCapabilities` | 见 §3.2 | 连接后立即发送 |
| `DirListing` | `request_id`, `path`, `entries` | `FileEntry{name,path,is_dir,size,modified_ms}` |
| `FileChunk` | `task_id`, `offset`, `data` | 顺序下载 |
| `FileUploadAck` | `task_id`, `received` | 每块确认；首块前 received=0 |
| `FileDone` | `task_id`, `path`, `size`, `sha256` | 任务成功终态 |
| `FileError` | `request_id`, `task_id`, `message` | 请求/任务错误；取消也返回终态错误 |

### 6.3 安全与原子性

- 路径：拒绝 `..`、绝对路径、盘符/UNC、NUL、非法字符；已存在路径先 canonicalize 再校验根目录；目录列表跳过符号链接；canonicalize 与打开之间的本地 TOCTOU 窗口仍存在，不能宣称完全消除。
- Host 上传：同目录临时文件、`flush`+`sync_all`、长度与 SHA-256 校验；`overwrite=false` 使用**平台原子无覆盖提交**（Windows `MoveFileExW` 不带 `REPLACE_EXISTING`；POSIX `link(2)`），检查后出现的同名目标不会被覆盖；`overwrite=true` 使用原子替换，失败保留旧文件。
- 所有上传失败/取消/会话结束路径关闭句柄并删除临时文件；Drop 保证清理。最终哈希在提交前计算。
- 下载：`FileCancel`、会话结束、撤权都会设置取消标志；已启动的阻塞任务在下一块前停止读取并发送终态错误；不会继续后台读取。
- 客户端下载：临时文件校验大小与 SHA-256 后用 `commitNoReplace` 原子提交（Windows `MoveFileExW` 无替换；Linux/Android `renameat2(RENAME_NOREPLACE)` 或 `link(2)`）；同名冲突自动选择新文件名，从不先删除目标。
- 当前限制：单根目录、无目录传输/拖放/续传/块级校验/ACL/SAF/服务端审计；删除权限未开放；文件与画面共用连接。

## 7. 版本与兼容

- v3 与旧 v1/v2 布局不兼容并拒绝；旧布局解码失败时直接断开，不保证旧客户端获得错误码，不降级。
- 原生查看器、Flutter 客户端和 Host 共用 `yl-proto` 0.3.0；任何字段布局变化必须提升 `PROTOCOL_VERSION` 并同步三端与本文档。
- 票据 claims 使用独立 `v=1` 版本；`kid` 支持服务端轮换，Host 遇到未知 `kid` 刷新公钥。旧票据在 `exp` 前可验签，服务端轮换不会立即吊销已签发票据；需要立即失效时使用中心撤权。
- 未知消息当前在查看器侧忽略（文件/能力扩展），Host 侧对未处理消息忽略；新增必选语义必须通过能力位确认，不能假设对端支持。

## v3 新消息与流畅模式

- `ServerMessage::QualityReady`（tag 12）：`port:u16, server_certificate:String, server_uuid:String, permissions:u32, input_allowed:bool`。仅在 quality 授权后发送。证书通过已固定指纹的 Host TLS 提供，客户端将其写入本次 Moonlight 的独立 host 条目；不能从此回执推断首帧或 FPS。质量控制连接仅接收 Ping/Bye，不能承载文件或绕过输入权限。
- `ServerMessage::FlowFrame(FrameMessage)`（tag 13）：布局与 Frame 相同；在该独立消息中 `full=true` 表示清空画布开始渐进刷新，**不保证一条消息覆盖全屏**。只允许协商 flow 后接收。旧 `Frame` 的全量覆盖校验保持严格，不能用普通截断全量帧冒充渐进帧。
- flow 使用 64px 图块、JPEG 40→60 静止精修，最多 5 次/秒采样；待发图块按坐标合并为最新内容并轮转发送，缓存受图块网格上限限制，输出帧队列 1 条。
- 双向应用数据共用最高 100,000 B/s 的 pacing 预算，另留约 200 kbit/s 给 TLS/TCP/IP/ACK 开销，目标约 1 Mbps；这不是网卡计费硬上限，网络重传和控制面 API 流量需另算。文件份额最高 16,000 B/s 且不超过当前应用预算的 20%，flow 上传/下载使用 2 KiB 块。无音频通道，未假称音频已分账。
- 控制消息优先；文件到期前继续发送画面，文件终态不会越过同任务数据。写阻塞超过 150 ms 时预算减半（最低 8,000 B/s），快速写入逐步恢复，上限不变；Host TCP send buffer 限为 16 KiB，单次写超时 5 秒后清理。TCP 仍存在队头阻塞，没有假称独立 QUIC 通道已完成。
- 超过有界消息上限的目录结果明确返回错误，需重新以兼顾模式连接浏览；未静默截断目录。当前模式在连接时选择，尚无会话内热切换。

最新实际证据见 [Host 适配与流畅模式](evidence/quality-host-flow-2026-10-19.md)。
