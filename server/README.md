# 远联控制服务（yl-server）

状态：0.3.0 开发版（协议 v3）。仓库版本已提供账号、邀请码注册、登录会话、设备目录、设备令牌、配对码/授权、Ed25519 短时会话票据、活动会话撤销、审计和 Web 管理后台。**不是中继，不转发屏幕/输入/文件内容。** 已部署的 `192.168.9.66` 仍是旧版本，本轮未升级。

## 当前部署

- 服务器：Ubuntu 24.04，1 核 / 1.9 GB 内存；根分区剩余空间很小，因此不安装 Rust、不新增 Docker 镜像。
- 二进制：`/opt/yuanlian/yl-server`（约 4.2 MB，静态依赖 SQLite）。
- 数据：`/opt/yuanlian/data/yuanlian.db`（SQLite WAL）。
- systemd：`yuanlian-server.service`，仅绑定 loopback。
- 管理后台：`http://127.0.0.1:18080/admin`。通过 SSH 隧道访问：
  ```bash
  ssh -L 18080:127.0.0.1:18080 root@192.168.9.66
  # 浏览器打开 http://127.0.0.1:18080/admin
  ```
- 初始管理员用户名：`admin`。密码只通过当面/私密渠道交付，不在仓库或日志中保存；登录后可在“账号安全”中修改，修改会撤销全部会话。

**尚未修改** nginx、防火墙、Docker 容器或 ikev2（charon UDP 500/4500）。在没有 TLS 反向代理前不要把 18080 暴露到外网；当前服务只提供 HTTP。

## 功能与 API

| 方法/路径 | 权限 | 说明 |
|---|---|---|
| `GET /health` | 公开 | 数据库健康、版本 |
| `GET /api/v1/server/info` | 公开 | 名称、版本、是否初始化、能力 |
| `POST /api/v1/setup` | 仅 loopback，未初始化 | 创建首个管理员 |
| `POST /api/v1/auth/login` | 公开 | 用户名密码 → Bearer 会话 |
| `POST /api/v1/auth/logout` | 登录 | 撤销当前会话 |
| `POST /api/v1/auth/refresh` | 登录 | 轮换会话令牌 |
| `POST /api/v1/auth/password` | 登录 | 修改密码并撤销全部会话 |
| `POST /api/v1/auth/register` | 邀请码 | 邀请码注册 |
| `GET /api/v1/me` | 登录 | 当前用户 |
| `POST /api/v1/invites` | 管理员 | 创建邀请码 |
| `GET /api/v1/users` | 管理员 | 用户列表（无密码） |
| `POST /api/v1/users/{id}/status` | 管理员 | 停用/恢复用户并撤销会话 |
| `GET /api/v1/devices` | 登录 | 自己拥有或被分享的设备 |
| `POST /api/v1/devices` | 登录 | 登记/更新设备，返回一次性设备令牌 |
| `GET /api/v1/server/ticket-key` | 公开 | Host 拉取 Ed25519 票据公钥（含 kid/active） |
| `POST /api/v1/devices/{id}/session-ticket` | Owner/被授权者 | 签发 1 小时票据；绑定 nonce |
| `POST /api/v1/devices/{id}/heartbeat` | Owner/管理员或设备令牌 | 在线时间、`owner_active`、`revoked_sessions` |
| `POST /api/v1/devices/{id}/sessions` | 设备令牌 | Host 上报活动会话 |
| `GET /api/v1/devices/{id}/sessions` | Owner/管理员 | 活动会话列表（含状态/路径/最终权限/租约） |
| `GET /api/v1/devices/{id}` | Owner/被授权者/管理员 | 设备详情（含在线证据、备注） |
| `PATCH /api/v1/devices/{id}` | Owner/管理员 | 仅名称/备注元数据 |
| `GET /api/v1/devices/{id}/session-tickets/{jti}` | 设备令牌 | Host 连接时检查待用票据是否仍有效/被撤销 |
| `POST /api/v1/devices/{id}/grants/{user_id}/revoke` | Owner/管理员 | 撤销分享授权并标记待用票据/活动会话 |
| `GET /api/v1/admin/overview` | 管理员 | 设备/在线/会话/路径聚合与阈值 |
| `GET /api/v1/admin/devices` | 管理员 | 全局设备分页/过滤（含 presence/session_count） |
| `GET /api/v1/admin/sessions` | 管理员 | 全局会话分页/状态过滤（含 ended/revoking/stale） |
| `GET /api/v1/admin/network/status` | 管理员 | 真实网络能力状态；当前 P2P/TURN 未实现 |
| `GET /api/v1/network/capabilities` | 登录 | 当前可用传输；不返回密钥 |
| `POST /api/v1/devices/{id}/sessions/revoke` | Owner/管理员 | 撤销单个/全部活动会话 |
| `POST /api/v1/devices/{id}/sessions/{session_id}/end` | 设备令牌 | Host 上报会话结束 |
| `POST /api/v1/devices/{id}/revoke` | Owner/管理员 | 撤销设备并标记活动会话 |
| `GET /api/v1/devices/{id}/connect-info` | Owner/被授权者 | 返回地址与 TLS 指纹 |
| `POST /api/v1/devices/{id}/pairing-code` | Owner/管理员 | 生成 10 分钟一次性配对码 |
| `POST /api/v1/pairing/claim` | 登录 | 使用配对码获得 7 天 view/control 授权 |
| `GET /api/v1/devices/{id}/grants` | Owner/管理员 | 查看分享授权 |
| `GET /api/v1/audit` | 管理员 | 最近 200 条审计 |
| `GET /admin` | 浏览器 | 管理后台 |

- 密码使用 Argon2id；会话令牌只保存 SHA-256 摘要；登录失败有简单限速（5 次/60 秒窗口）。
- 设备令牌只返回一次，服务端只存摘要；Host 代理后续用 `X-Device-Token` 心跳。
- 设备在线只由带设备令牌的 agent 心跳更新 `last_agent_seen`；管理员/所有者浏览器的普通心跳不会制造在线状态。
- 票据签发写入 `session_tickets`；停用用户、撤销设备/分享会撤销待用票据；Host 在连接和开始上报时二次检查。
- `active_sessions` 记录票据权限、最终权限、Host 实例、请求/实际输入和路径；心跳刷新租约，30 秒无证据由服务端/心跳标记 `lease_expired`。
- 审计不保存密码、令牌、按键、剪贴板或文件内容。

## 构建与部署

在 WSL/Ubuntu 构建（服务器无 Rust 工具链）：

```bash
cd server
cargo fmt -- --check
cargo clippy --release --locked -- -D warnings
cargo test --release --locked
cargo build --release --locked
```

上传 `target/release/yl-server` 到 `/opt/yuanlian/yl-server`，使用
`server/deploy/yuanlian-server.service` 安装 systemd 单元。默认绑定 loopback；
不要在没有 TLS 的情况下改成 `0.0.0.0`。

## 未完成

- 已部署服务器仍是旧版本；0.2.0 只在 WSL 隔离库验证。
- 没有 MFA/TOTP、恢复码、策略下发/回滚、中继/穿透、自动化备份恢复验证。
- 票据私钥存 SQLite，未做 HSM/磁盘加密；立即吊销已签发票据需用中心撤权。
- 配对授权是目录级授权；文件权限仍由票据位与 Host 本地策略交集决定。
- 管理后台是单页开发版；无 CSRF 表单（Bearer token 在 sessionStorage，不使用 Cookie）。
- 尚未配置 HTTPS/域名；暴露前必须加反向代理与证书。
- Docker Compose/镜像定义已提供，但开发机无 Docker，未构建验证。
- P2P/ICE/STUN/TURN/中继未实现；WebUI 网络页明确显示未实现，不提供假测试按钮。
