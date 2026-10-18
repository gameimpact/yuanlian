# Linux 控制服务 WebUI 与 P2P 扩展前审查

日期：2026-10-18。对象：当前未提交工作树；Git HEAD 为 `9d473aa`，不能用该提交单独复现当前 0.2.0 源码。此次交付为**源码审查和开发提示词**，没有实现 WebUI 扩展、打洞或中继，也没有操作生产服务器。

## 1. 结论与已有基础

应在现有控制服务和授权闭环上增量开发。Linux 服务端指 `server/` 中的账号、设备、授权与协调服务，不是 Linux 桌面被控 Host。

| 核查项 | 当前源码事实 | 证据 |
|---|---|---|
| 管理 WebUI | 已有 `/`、`/admin` 和开发版单页后台；账号安全、设备、配对、用户、邀请、审计均有 API | `server/src/main.rs:1848`；`server/admin/index.html` |
| 所有设备 | 管理员的 `GET /api/v1/devices` 已查询全部设备；普通账号限制为拥有/被分享设备 | `server/src/main.rs:1335-1382` |
| 设备状态 | API 返回注册状态 `active/revoked` 和 `last_seen`；后台仅显示注册状态，不能据此判断在线或正在被控 | `server/src/main.rs:1318-1331`；`server/admin/index.html:235-241` |
| 会话管理 | 已有单设备会话上报、查询、撤销、结束接口；后台未接入会话页，没有全局实时会话总览 | `server/src/main.rs:698-881`；`server/admin/index.html` |
| 授权基础 | Ed25519 票据、nonce、防重放、Host 本机确认、权限交集、心跳撤权代码均存在 | `crates/yl-proto/src/auth.rs`；`crates/yl-host/src/control.rs`、`session.rs` |
| 数据传输 | 当前为 Viewer → Host 的 TCP/TLS 直连；控制服务不转发媒体 | `crates/yl-host/src/main.rs:339-353`；`session.rs:66-68`；`client/lib/src/net/remote_client.dart:178` |
| P2P 穿透 | 未发现实际 ICE/STUN/TURN 协商、候选地址检查、穿透或媒体中继实现；添加服务端路由不能独立完成此功能 | 根/服务端 Cargo 依赖、Host/Viewer/Flutter 网络路径 |
| 跨平台边界 | Windows Host + Windows/Android 主控是当前基础；Linux 客户端只有构建/历史运行检查，Linux/Android Host 未完成 | 追踪表、现有采集/输入实现 |

**收益边界**：与中继路径相比，成功直连可以减少中继服务器转发的媒体流量，并可能减少绕行延迟。当前版本本就直连，没有可供“节省”的现有中继媒体流量。打洞不能直接降低 JPEG 码率，也不能消除当前采集/编码开销；必须分别测量传输 RTT、首帧、呈现延迟和中继字节数。标准背景见 [ICE RFC 8445](https://www.rfc-editor.org/rfc/rfc8445.html) 与 [TURN RFC 8656](https://www.rfc-editor.org/rfc/rfc8656.html)。

## 2. 必须先修复的发现

### R1 · P1：停用主控账号未覆盖尚未上报的已签发票据

- `issue_session_ticket` 在 `server/src/main.rs:662-695` 签发票据，但没有建立包含签发状态、主体和撤权状态的票据记录。
- `set_user_status` 在 `server/src/main.rs:1247-1260` 只撤销登录会话及**已经存在**的活动会话。
- `report_session_start` 在 `server/src/main.rs:708-738` 检查的是 Host/设备所有者是否有效，没有验证被上报的主控用户状态，也没有核对该票据的签发记录。
- Host 的 `authorize` 在 `crates/yl-host/src/session.rs:433-465` 检查设备所有者和票据签名；不能由此推导票据主体仍然有效。

**隔离 API 已复现**：先给共享设备的主控用户签票据，再停用主控账号，然后使用有效 Host 设备令牌上报该 `jti`，API 仍返回 200，后续心跳没有撤销此会话。此次没有启动 Viewer/采集/输入，不把它描述为实机远控绕过已复现。

修复要求：持久化签发/撤权状态或采用有明确生命周期的授权版本机制；停用、撤销、授权到期应同时覆盖待用和活动票据；开始上报必须检查主体与设备授权。Host 在本机确认后、开放业务前再次检查撤权状态，不得吞掉开始确认失败。

### R2 · P1：会话 UPSERT 缺少设备归属条件

`server/src/main.rs:725-731` 对全局 `session_id` 冲突直接更新 `permissions/last_seen`，没有要求已有行的 `device_id` 与认证设备一致。

**隔离 API 已复现**：设备 A 用自己的令牌创建权限为 1 的会话；设备 B 使用自己的有效令牌，上报相同会话 ID、权限为 3；B 请求返回 200，A 的记录权限变成 3。前提是调用者知道相应 ID。复现的是会话元数据越权修改，未证明 Host 实际权限被提升。

修复要求：设备、票据 ID、主控主体和连接尝试绑定；跨设备冲突拒绝；重复同主体上报幂等；终态不复活。使用事务和条件更新，补跨设备访问回归测试。

### R3 · P2：会话缺少持续存活证据和异常终结

- 会话 `last_seen` 只在开始/重复上报中更新，`heartbeat` 在 `server/src/main.rs:1611-1617` 仅更新设备时间。
- `list_sessions` 在 `server/src/main.rs:810-825` 只按 `ended_at IS NULL` 选取，不按租约、Host 实例或存活证据过滤。
- Host 崩溃或结束报告丢失后，记录可以一直留在“活动”结果中。

**隔离 API 已复现的部分**：设备心跳后，设备所属会话的 `last_seen` 不变。长期幽灵会话风险由上述查询与缺少清理路径静态确认，未等待长时间或执行真实 Host 崩溃 E2E。

修复要求：Host 启动代际、活动会话心跳、可区分的 `unknown/stale/ended` 状态、过期清理与重连对账；状态不能只依赖浏览器时钟或 socket 存活。

### R4 · P2：设备撤销后，合法 Host 反而不能确认会话结束

`authenticate_device_token` 能区分设备令牌有效与设备被撤销，但 `report_session_end` 在 `server/src/main.rs:760-762` 对非 active 设备直接拒绝。

**隔离 API 已复现**：撤销设备后，同一有效设备令牌上报自己已存在会话的结束，返回 403。这与结束确认、墓碑和后台“断开完成”的目标冲突。

修复要求：凭有效令牌允许对自身会话做范围受限、幂等的结束确认；被撤销设备不能创建新会话或修改其他字段。后台区分“已请求撤销”“Host 已确认”“租约推定结束”。

### R5 · P2：开始上报错误被忽略，且上报权限不是实际有效权限

- `crates/yl-host/src/session.rs:200-205` 丢弃线程等待结果和 `report_start` 的业务错误。
- `crates/yl-host/src/control.rs:146-150` 上报 `claims.permissions`；实际权限在 `session.rs:490-494` 与本地策略取交集，`request_input` 还会限制本次控制能力。

因此真实运行的会话可能没有中心记录，后台也可能把票据允许的权限当成已生效权限。此项为源码确认，未做网络故障 E2E。

修复要求：在开始确认成功前不开放正式业务；明确控制面不可用时新连接的失败策略；分别记录票据权限、本地策略和最终权限，不能只改展示文字。

### R6 · P2：控制面阻塞工作与 WebUI 扩展存在争用风险

`AppState` 在 `server/src/main.rs:52-56` 共享 `std::sync::Mutex<rusqlite::Connection>`；`login` 在 `server/src/main.rs:954-987` 持有数据库锁执行 Argon2 校验。全量设备查询又逐个读取设备/授权，缺少分页。

这是源码确认的阻塞和串行路径，**未压测证明具体吞吐下降**。在 1 核服务器新增实时页面/信令前，应把 Argon2 放到有并发上限的阻塞工作池，避免持锁计算；列表分页/批量查询；统计采样，不能逐帧入 SQLite。

## 3. 新功能实现路线

1. 修复 R1–R5，补隔离 API 回归和生命周期测试；处理 R6 的必要争用点。
2. 扩展现有 WebUI：概览、所有设备、在线设备、会话、设备详情、网络诊断。复用已有账号/用户/邀请/审计。
3. 建立可信状态模型、采样统计、权限受控的实时事件与全局会话查询。
4. 先做 Windows Host ↔ Windows/Android 主控的 WebRTC DataChannel 技术验证：复用图块协议，标准 ICE/STUN/TURN，认证绑定 DTLS 指纹，验证真实数据通路。
5. 集成到实际产品与原生诊断查看器，保留现有 TCP/TLS 直连；中继仅转发端点间密文，穿透失败有明确回退和原因。
6. 进行真实跨 NAT、UDP 被阻断、中继强制、撤权与性能对照验收；缺环境的项目保留待实测。

WebRTC 数据通道的 SCTP/DTLS/ICE 标准结构见 [RFC 8831](https://www.rfc-editor.org/rfc/rfc8831.html)。这是本项目的建议选型，依赖版本、平台构建、身份绑定和互通性仍需实现者做技术验证，不能以第三方支持列表替代本产品实测。

逐页、接口、状态机、安全、部署、验证和交付要求见根目录 [Linux 服务端 WebUI 与 P2P 开发提示词](../../Linux服务端_WebUI与P2P_开发提示词.md)。

## 4. 本轮验证记录

全部针对当前工作树。未连接 `192.168.9.66`，未修改 nginx、Docker、防火墙、IKEv2 或生产数据。

| 环境/检查 | 命令/方式 | 本轮结果 |
|---|---|---|
| Windows Rust 格式 | `cargo fmt --all -- --check` | 通过 |
| Windows Rust 静态检查 | `cargo clippy --workspace --all-targets --locked --offline` | 通过，0 warning |
| Windows Rust 测试 | `cargo test --workspace --locked --offline` | 28 passed：Host 15、proto 7、tiles 5、viewer 1 |
| WSL Ubuntu 服务端格式 | `cargo fmt -- --check`（`server/`） | 通过 |
| WSL Ubuntu 服务端静态检查 | `cargo clippy --release --locked --offline -- -D warnings` | 通过 |
| WSL Ubuntu 服务端测试 | `cargo test --release --locked --offline` | 6 passed |
| WSL Ubuntu 服务端构建 | `cargo build --release --locked --offline` | 通过；复用 `/home/ubuntu/yl-server-build/target` 缓存，源码取当前仓库 |
| Dart 静态分析 | `dart analyze lib test` | No issues found |
| Flutter 测试 | `flutter test --no-pub` | 40 passed，含 responsive；不是浏览器/实体触控 E2E |
| 隔离控制面 API 核查 | 当前服务端二进制；随机 loopback 端口、临时 SQLite、临时测试账号/设备 | R1/R2/R4 行为复现，R3 时间字段行为复现；服务进程和临时库已清理 |

隔离核查脚本在本地忽略目录 `artifacts/review/webui-p2p-20261018/api_audit.py`，只输出布尔结果和 HTTP 状态，不打印密码、令牌、票据、私钥或响应正文。测试设备是明确标识的 API fixture，不是实际设备在线或真实远控证据。

未进行：WebUI 真实浏览器点击、Windows/APK 新构建、真实远控窗口检查、跨物理机/公网 P2P、TURN、媒体 E2EE 与带宽/延迟实测。现有测试通过不关闭以上发现。

## 5. 后续修复状态（2026-10-18 同日）

审查后已在工作树完成增量修复，原报告中的“未修复”结论仅代表审查时基线：

- R1：新增 `session_tickets` 签发记录；停用用户、撤销设备/分享会标记待用票据；Host 连接时调用 `/session-tickets/{jti}`，本机确认后再强制 `/sessions` 开始上报。
- R2：开始上报先校验设备/用户/Host 实例归属，跨设备冲突拒绝，同主体幂等，终态不复活。
- R3：agent 心跳刷新会话 `last_seen`；active/unknown/stale/revoking/ended 状态、30 秒租约、服务端定期清理和 Host 实例对账。
- R4：有效设备令牌可确认自己的会话结束，即使设备已撤销；仍不能新建/修改他人会话。
- R5：Host 上报票据权限/最终权限/输入/路径/Host 实例；开始确认失败即关闭，不发送 Welcome、不开采集。
- R6：登录 Argon2 验证移出数据库互斥锁并放到 blocking pool；新增管理分页接口。
- WebUI：概览、所有设备、在线设备、当前会话、设备详情、网络状态、用户/邀请、审计；本机 Chrome/CDP 登录与撤权状态切换实测。
- P2P/ICE/STUN/TURN/中继：**仍未实现**；网络页只显示真实未实现状态，未用假按钮/echo 冒充。

证据：`docs/evidence/webui-r1-r6-2026-10-18.md`。R1–R6 行为回归通过；跨 NAT、TURN、媒体 E2EE、长期稳定性仍待独立环境实测。
