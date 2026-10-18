# 远联协议 v1（开发草案）

状态：与 `yl-proto` 0.1.0 / M0 实现一致。M0 只覆盖 Windows Host ↔ Windows 原生查看器的画面与输入通道；账号、配对、文件、中继和 Moonlight 协议尚未进入本协议。

## 1. 传输

| 项目 | M0 实现 | 正式目标 |
|---|---|---|
| 底层 | TCP | QUIC 可靠流/数据报，禁 UDP 时回退 TLS/TCP |
| 安全 | TLS 1.2/1.3（rustls/ring），自签名证书 | 设备身份证书 + 会话票据；控制面 TLS，数据面端到端加密 |
| 身份校验 | 查看器按 SHA-256 指纹固定 Host 证书 | 首次配对 + 设备白名单 + 短时会话票据 |
| ALPN | `yuanlian/1` | 按版本升级 |
| 帧格式 | `u32 BE 长度 + bincode 负载` | 保持或使用带版本头的帧 |
| 消息上限 | 32 MiB | 按通道分别限制 |

M0 的指纹校验是开发期 TOFU：Host 每次启动生成新证书并在控制台打印指纹，人工抄给查看器。它不提供账号级授权，不能暴露到公网。

TLS 只保护传输链路；正式产品中中继必须只转发密文，不能把“管理 API 使用 HTTPS”当作媒体已端到端加密。

## 2. 连接流程

```
Viewer                          Host
  |-- TCP connect ---------------->|
  |-- TLS handshake (pin) -------->|
  |-- ClientHello ----------------->|
  |<------------- Welcome ---------|
  |<------------- Frame -----------|
  |<------------- Cursor ----------|
  |-- Input / Ping / RequestKeyframe
  |<------------- Pong / Frame / Error
  |-- Bye ------------------------>|
```

1. Host 监听（默认 `127.0.0.1:24800`），完成 TLS 握手后等待 `ClientHello`，超时 10 秒。
2. Host 校验协议版本、读取显示器信息，发送 `Welcome`。
3. Host 只在启动参数 `--allow-input` 且客户端 `request_input=true` 时令 `input_allowed=true`。Host 在会话层拒绝未授权输入，不能只靠查看器置灰按钮。
4. 画面与光标分别推送；静态画面可以长时间没有 `Frame`，由查看器每 5 秒 `Ping`、Host `Pong` 维持。查看器 30 秒无任何消息判定心跳超时。
5. 任一端断开、`Bye` 或错误时，Host 释放本会话注入的所有按键与鼠标按钮。

## 3. 消息

### 3.1 Client → Host

| 消息 | 字段 | 说明 |
|---|---|---|
| `Hello` | `protocol_version:u16`, `client_name:String`, `client_id:String`, `request_input:bool` | 必须是第一条消息 |
| `Input(InputEvent)` | 见 §4 | Host 未授权时返回 `input_denied` |
| `RequestKeyframe` | 无 | 请求下一帧 `full=true` |
| `Ping` | `nonce:u64` | 心跳 |
| `Bye` | 无 | 正常结束 |
| `TextInput` | `text:String` | 已提交的 UTF-16 文本，最多 4096 个 UTF-16 单元；Host 用 SendInput Unicode 注入；不是远端 IME 组合 |

### 3.2 Host → Viewer

| 消息 | 字段 | 说明 |
|---|---|---|
| `Welcome` | `protocol_version`, `host_id`, `host_name`, `screen_width`, `screen_height`, `input_allowed`, `mode`, `tile_size` | `mode` 在 M0 固定 `"tiles"` |
| `Frame` | `seq:u64`, `screen_generation:u32`, `full:bool`, `width:u32`, `height:u32`, `tiles:[Tile]` | §5 |
| `Cursor` | `x:i32`, `y:i32`, `visible:bool` | 相对当前采集显示器左上角；`visible=false` 时仍可能给出界外坐标 |
| `Pong` | `nonce:u64` | 心跳应答 |
| `Error` | `code:ErrorCode`, `message:String` | 可恢复错误不必断开 |
| `Bye` | `reason:String` | 会话结束 |

`Tile`：`x:u32, y:u32, width:u32, height:u32, jpeg:bytes`。

### 3.3 错误码

`protocol_version`、`bad_message`、`input_denied`、`screen_unavailable`、`internal`、`busy`。

## 4. 输入语义

| 事件 | 字段 | 坐标/单位 |
|---|---|---|
| `MouseMove` | `x:i32`, `y:i32` | 采集显示器内像素，左上为 (0,0) |
| `MouseButton` | `button`（Left/Right/Middle/Back/Forward）, `down` | 按下/释放成对；Host 去重 |
| `Wheel` | `vertical:i32`, `horizontal:i32` | 120 的倍数，正方向与 Windows 滚轮一致 |
| `Key` | `vk:u16`, `down:bool`, `extended:bool` | Windows 虚拟键码；方向键、导航键、右 Ctrl/Alt 等 extended |
| `ReleaseAll` | 无 | 释放 Host 记录的所有按键/按钮；失焦、断开、退出必需 |

Host 将显示器内坐标加上显示器原点，再换算为虚拟桌面的 0–65535 绝对坐标后调用 `SendInput`。M0 使用虚拟键码，中文 IME 文本提交、物理扫码、手柄、触控尚未实现。

## 5. 图块画面通道

### 5.1 网格与编码

- 图块默认 128×128 px，最后一行/列裁切；网格原点为采集显示器左上角。
- 每块独立 JPEG（baseline，RGB），默认质量 85；静止 600 ms 后对该块以质量 95 再编码一次（精修）。M0 的精修仍是 JPEG，不是无损；正式版需要无损/近无损的文字区域策略。
- 只发送自上一帧以来像素变化的图块；静态画面发送零个 `Frame`（光标走独立 `Cursor`）。
- 首帧、`RequestKeyframe`、尺寸变化时发送 `full=true`，查看器先清空画面再叠加图块。

### 5.2 一致性与代际

- `screen_generation` 在采集源/尺寸变化时递增。查看器收到新代际必须清空缓存、等待全量图块；旧代际图块不得覆盖新画面。
- `seq` 在连接内单调递增；TCP 有序，查看器可据此丢弃重复帧。
- 图块不得超出 `width/height`；解码后尺寸必须等于 `width/height`，否则丢弃并记录。正式版需加入消息长度、像素总量、缓存上限与损坏负载测试。

### 5.3 已知限制

- JPEG 全色块在高 DPI 小字上仍有振铃；需要在兼顾模式加入文本/线条无损路径。
- 变化检测逐块哈希，滚动/移动区域未做块复用；大视频区域每帧多块 JPEG，带宽高于视频编码。
- 画面与输入共用一条 TCP，存在队头阻塞；正式版拆分控制/输入/画面/文件通道，并按优先级调度。

## 6. 版本与兼容

`PROTOCOL_VERSION = 1`。Major 不兼容变更递增主版本并在 `Welcome/Hello` 中校验；新增可选消息/字段通过版本协商或能力位提供。M0 对未知消息直接返回 `bad_message`，避免静默误解。

## 7. 文件与文本通道（M1 扩展，协议版本仍为 1）

`TextInput` 只提交用户在本地输入法完成的文本，Host 使用 `SendInput` 的 `KEYEVENTF_UNICODE` 注入 UTF-16 单元；它不驱动远端 IME 候选窗，也不绕过 Host 键鼠输入权限。已实测中文与 emoji 注入到 Windows 文本框。


文件消息追加在既有枚举末尾，旧客户端不会收到这些消息。文件能力由 Host 启动参数 `--file-root` 明确开启；未开启时 Host 对任何文件请求返回错误。

### 7.1 客户端 → Host

| 消息 | 字段 | 说明 |
|---|---|---|
| `FileList` | `request_id:u64`, `path:String` | 列出相对授权根目录的目录 |
| `FileDownload` | `task_id:u64`, `path:String` | 下载普通文件 |
| `FileUploadStart` | `task_id:u64`, `path:String`, `size:u64`, `overwrite:bool` | 开始上传；目标存在且未允许覆盖时拒绝 |
| `FileUploadChunk` | `task_id:u64`, `offset:u64`, `data:Vec<u8>` | 顺序块，最大 256 KiB；偏移必须等于已接收字节 |
| `FileUploadFinish` | `task_id:u64` | 校验大小、计算 SHA-256、提交 |
| `FileCancel` | `task_id:u64` | 清理临时文件/下载状态 |
| `TextInput` | `text:String` | 本地文本提交；Host 端按输入权限强制校验，不记录内容 |

### 7.2 Host → 客户端

| 消息 | 字段 | 说明 |
|---|---|---|
| `FileCapabilities` | `enabled:bool`, `root_label:String` | 连接建立后立即发送；只暴露根目录名，不暴露绝对路径 |
| `DirListing` | `request_id`, `path`, `entries:Vec<FileEntry>` | `FileEntry` 含名称、相对路径、是否目录、大小、修改时间 |
| `FileChunk` | `task_id`, `offset`, `data` | 下载数据块，顺序发送 |
| `FileUploadAck` | `task_id`, `received` | 每块确认；首块前发送 received=0 |
| `FileDone` | `task_id`, `path`, `size`, `sha256` | 下载结束或上传提交后的最终信息 |
| `FileError` | `request_id`, `task_id`, `message` | 请求错误对应 request_id，任务错误对应 task_id |

### 7.3 安全与一致性

- Host 只接受相对路径；拒绝 `..`、绝对路径、盘符/UNC、非法字符与 NUL。存在路径先 canonicalize，再校验仍位于授权根内；符号链接目标越界会被拒绝。目录列表跳过符号链接。
- 上传写入同目录临时文件，收到全部字节、flush/sync 并校验声明大小与 SHA-256 后提交；Windows 使用 MoveFileExW(REPLACE_EXISTING|WRITE_THROUGH) 替换，失败时保留旧文件并清理临时文件。
- 下载和上传都计算 SHA-256，客户端在完成后自行核对；大小或哈希不一致时显示失败，不把临时文件当完成文件。
- 当前限制：单根目录、无断点续传、无目录上传/下载、无 ACL/SAF、无服务端审计、无独立文件权限弹窗；文件数据与控制/画面共用同一 TLS 连接，可能受队头阻塞影响。不得把这些限制隐藏。
